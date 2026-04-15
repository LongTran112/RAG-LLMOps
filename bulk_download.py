import os
import time
from edgar import set_identity, get_filings

# 1. Identify yourself to the SEC (Required)
# Replace with your actual name and email for your thesis
set_identity("Your Name your.email@example.com")

# 2. Create a local folder for your Phase 1 dataset
save_directory = "sec_rag_dataset_50"
os.makedirs(save_directory, exist_ok=True)

# 3. Query the SEC EDGAR Database
# Pulling 10-K (Annual Reports) from the 4th quarter of 2023
print("Querying SEC EDGAR...")
filings = get_filings(2023, 4, form="10-K") 

print(f"Found {len(filings)} total filings. Starting download for the first 50...")

# 4. Download and Save the Text
# We slice [:50] to grab exactly 50 files
for index, filing in enumerate(filings[:50]):
    try:
        # .text() automatically strips HTML/XBRL
        clean_text = filing.text()
        
        # Create a unique filename
        filename = f"{filing.cik}_{filing.accession_no}.txt"
        filepath = os.path.join(save_directory, filename)
        
        # Save the text file locally
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(clean_text)
            
        print(f"[{index + 1}/50] Successfully saved: {filename}")
        
        # Add a small delay to respect SEC rate limits (max 10 requests/sec)
        time.sleep(0.5)
        
    except Exception as e:
        print(f"[{index + 1}/50] Could not download filing {filing.accession_no}: {e}")

print("\nPhase 1 Dataset generation complete! You now have 50 legal corporate documents.")
