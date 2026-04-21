# frontend-next

Next.js chat frontend for the thesis RAG backend.

Features:
- Fast/Complex mode selection
- Streaming SSE client for `sources`, `thinking`, `token`, `done`, `error`
- Grayscale thinking stream for complex mode
- Normal answer rendering
- Collapsible per-message source citations

## Run locally

1. Install dependencies

```bash
cd frontend-next
npm install
```

2. Configure backend URL

```bash
cp .env.local.example .env.local
```

If needed, edit `.env.local`:

```env
NEXT_PUBLIC_RAG_BACKEND_URL=http://127.0.0.1:8000
```

3. Start dev server

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Notes

- This frontend uses the existing backend contract as-is.
- Existing Streamlit frontend under `frontend/` is unchanged.
This is a [Next.js](https://nextjs.org) project bootstrapped with [`create-next-app`](https://nextjs.org/docs/app/api-reference/cli/create-next-app).

## Getting Started

First, run the development server:

```bash
npm run dev
# or
yarn dev
# or
pnpm dev
# or
bun dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

You can start editing the page by modifying `app/page.tsx`. The page auto-updates as you edit the file.

This project uses [`next/font`](https://nextjs.org/docs/app/building-your-application/optimizing/fonts) to automatically optimize and load [Geist](https://vercel.com/font), a new font family for Vercel.

## Learn More

To learn more about Next.js, take a look at the following resources:

- [Next.js Documentation](https://nextjs.org/docs) - learn about Next.js features and API.
- [Learn Next.js](https://nextjs.org/learn) - an interactive Next.js tutorial.

You can check out [the Next.js GitHub repository](https://github.com/vercel/next.js) - your feedback and contributions are welcome!

## Deploy on Vercel

The easiest way to deploy your Next.js app is to use the [Vercel Platform](https://vercel.com/new?utm_medium=default-template&filter=next.js&utm_source=create-next-app&utm_campaign=create-next-app-readme) from the creators of Next.js.

Check out our [Next.js deployment documentation](https://nextjs.org/docs/app/building-your-application/deploying) for more details.
