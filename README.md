# Mutambo Beef

Storefront with rewards wallet (`/`) and in-store POS (`/pos`). Static HTML/JS on Supabase.

- `index.html`: customer site: menu, rewards, wallet, checkout
- `pos/index.html`: staff POS: sell, top up, online orders, today's cash, products, settings
- `assets/`: shared styles and the Supabase client (publishable key; data is protected by RLS)
- `supabase/`: database migrations and product seed

Deploy on Vercel as a static site: framework "Other", no build command, root directory `/`.
