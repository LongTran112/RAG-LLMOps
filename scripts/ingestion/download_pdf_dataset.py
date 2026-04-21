"""Build a ~100 PDF SEC 10-K dataset for the thesis RAG stress tests.

The thesis explicitly states the AI answer quality is irrelevant; the dataset
only needs to be realistic in size (~100 PDFs, ~300-500 pages each, totalling
~50k pages) so the retrieval + ingestion + memory characteristics of the stack
are exercised.

Strategy:
  1. Pull 10-K filings from SEC EDGAR via the `edgar` library (same approach as
     bulk_download.py at the repo root).
  2. For each filing, render its text into a multi-page PDF using reportlab.
     This avoids the license/flakiness of weasyprint/wkhtmltopdf and is
     deterministic.
  3. Pad each filing's text by repeating/appending so the resulting PDF has
     at least MIN_PAGES pages. This keeps the per-doc page count in the
     ~300-500 range the thesis targets, even when the raw 10-K text would
     produce fewer pages at our font size.

Usage:
    python scripts/ingestion/download_pdf_dataset.py                # defaults: 100 docs
    TARGET_DOCS=25 MIN_PAGES=50 python scripts/ingestion/download_pdf_dataset.py
    OUTPUT_DIR=sec_rag_dataset_100_pdf python scripts/ingestion/download_pdf_dataset.py

Upload to GCS for in-cluster ingestion:
    gsutil -m rsync -r sec_rag_dataset_100_pdf \\
        gs://<your-bucket>/sec_rag_dataset_100_pdf
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

TARGET_DOCS = int(os.getenv("TARGET_DOCS", "100"))
MIN_PAGES = int(os.getenv("MIN_PAGES", "300"))
MAX_PAGES = int(os.getenv("MAX_PAGES", "500"))
OUTPUT_DIR = Path(os.getenv("OUTPUT_DIR", "sec_rag_dataset_100_pdf"))
FILING_YEAR = int(os.getenv("FILING_YEAR", "2023"))
FILING_QUARTER = int(os.getenv("FILING_QUARTER", "4"))
SEC_IDENTITY = os.getenv(
    "SEC_IDENTITY", "Master Thesis Research thesis.research@example.com"
)


def build_pdf(
    text: str,
    out_path: Path,
    *,
    min_pages: int,
    max_pages: int,
    title: str,
) -> int:
    """Render `text` into a PDF with at least min_pages pages. Returns page count."""
    from reportlab.lib.pagesizes import LETTER
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer

    styles = getSampleStyleSheet()
    body = styles["BodyText"]
    body.fontSize = 10
    body.leading = 12

    # Split into paragraphs on blank lines; clamp paragraph length so reportlab
    # doesn't choke on SEC filings that occasionally have 50k-char blobs.
    raw_paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    paragraphs: list[str] = []
    for para in raw_paragraphs:
        if len(para) <= 1500:
            paragraphs.append(para)
        else:
            for offset in range(0, len(para), 1500):
                paragraphs.append(para[offset : offset + 1500])

    if not paragraphs:
        paragraphs = ["(empty filing)"]

    story: list = []
    story.append(Paragraph(title.replace("<", "&lt;").replace(">", "&gt;"), styles["Title"]))
    story.append(Spacer(1, 12))

    # Repeat the corpus until we have enough content for min_pages. reportlab
    # will paginate automatically; we stop adding extra copies once we exceed
    # max_pages worth of estimated content (rough: 18 paragraphs ~= 1 page).
    approx_paras_per_page = 18
    target_paragraphs = min_pages * approx_paras_per_page
    cap_paragraphs = max_pages * approx_paras_per_page

    idx = 0
    added = 0
    while added < target_paragraphs:
        para = paragraphs[idx % len(paragraphs)]
        safe = para.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        story.append(Paragraph(safe, body))
        story.append(Spacer(1, 4))
        idx += 1
        added += 1
        # Page break every page-ish to keep PyMuPDF's per-page extraction
        # representative of real filings.
        if added % approx_paras_per_page == 0:
            story.append(PageBreak())
        if added >= cap_paragraphs:
            break

    doc = SimpleDocTemplate(
        str(out_path),
        pagesize=LETTER,
        leftMargin=54,
        rightMargin=54,
        topMargin=54,
        bottomMargin=54,
        title=title,
    )
    doc.build(story)

    # Ask PyMuPDF how many pages actually landed (reportlab's paragraphing is
    # approximate; this is the honest number we report in ingestion metrics).
    try:
        import fitz  # PyMuPDF

        with fitz.open(str(out_path)) as pdf:
            return pdf.page_count
    except Exception:
        return -1


def main() -> int:
    try:
        from edgar import get_filings, set_identity
    except ImportError:
        print(
            "ERROR: `edgar` (edgartools) package missing. Install with:\n"
            "    pip install edgartools reportlab pymupdf",
            file=sys.stderr,
        )
        return 2
    try:
        import reportlab  # noqa: F401
    except ImportError:
        print(
            "ERROR: `reportlab` missing. Install with: pip install reportlab",
            file=sys.stderr,
        )
        return 2

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    set_identity(SEC_IDENTITY)

    print(
        f"Pulling 10-K filings for {FILING_YEAR} Q{FILING_QUARTER} "
        f"(target={TARGET_DOCS}, min_pages={MIN_PAGES}, max_pages={MAX_PAGES})"
    )
    filings = get_filings(FILING_YEAR, FILING_QUARTER, form="10-K")
    print(f"Found {len(filings)} total filings; iterating until {TARGET_DOCS} PDFs are built")

    saved = 0
    seen = 0
    total_pages = 0
    for filing in filings:
        if saved >= TARGET_DOCS:
            break
        seen += 1
        try:
            text = filing.text()
            if not text or len(text) < 2000:
                print(f"[{seen}] skipping {filing.accession_no}: text too short")
                continue
            filename = f"{filing.cik}_{filing.accession_no}.pdf"
            out_path = OUTPUT_DIR / filename
            if out_path.exists():
                saved += 1
                print(f"[{seen}] already exists, keeping: {filename}")
                continue
            title = f"SEC 10-K - CIK {filing.cik} - {filing.accession_no}"
            pages = build_pdf(
                text,
                out_path,
                min_pages=MIN_PAGES,
                max_pages=MAX_PAGES,
                title=title,
            )
            total_pages += max(pages, 0)
            saved += 1
            print(f"[{seen}] saved {filename} ({pages} pages)")
            time.sleep(0.4)
        except Exception as exc:
            print(f"[{seen}] error on {filing.accession_no}: {exc}", file=sys.stderr)

    print(
        f"Done: {saved} PDFs saved to {OUTPUT_DIR} "
        f"(approx total pages: {total_pages})"
    )
    return 0 if saved > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
