# Mutambo Beef

Storefront with rewards wallet (`/`) and in-store POS (`/pos`). Static HTML/JS on Supabase.

- `index.html`: customer site: menu, rewards, wallet, checkout, account (balance, orders, invoices)
- `pos/index.html`: staff POS: sell, top up, online orders, invoices, today's cash, products, settings
- `invoice.html`: public invoice page, served at `/i/<token>` (no sign-in; the token is the key)
- `assets/invoice.js`: the invoice template, shared by the page, the POS preview and the PDF
- `api/invoice-pdf.js`: `/api/invoice-pdf?t=<token>` renders the same template to an A4 PDF in headless Chromium
- `assets/`: shared styles and the Supabase client (publishable key; data is protected by RLS)
- `supabase/`: database migrations and product seed

Deploy on Vercel: framework "Other", no build command, root directory `/`. Vercel installs `package.json` for the PDF function.

## Invoices

- POS → Invoices → New invoice: pick (or create) the customer account, add lines (cut, kg, K/kg; price fills from Products), create, then "Send on WhatsApp".
- Numbers are `MB-INV-YYYY-NNN` from `invoice_counters`; never reused. Sent invoices can't be edited, only voided with a reason.
- Status: Draft → Sent → Opened (first customer open of the link) → Paid, or Void.
- Customers sign in with phone + one-time code (Supabase Auth → Providers → Phone must have an SMS provider) to see every invoice under Account → Invoices.
- Flags in POS → Settings: pay invoices from balance (with the balance discount), and MoMo matching by reference.
