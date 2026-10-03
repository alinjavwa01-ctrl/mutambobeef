-- ===== Settings (rewards rules live here, editable by admin) =====
create table public.settings (
  id int primary key default 1 check (id = 1),
  wallet_discount_pct numeric not null default 5,          -- % off when paying with wallet
  topup_bonus jsonb not null default '[{"min":500,"pct":3},{"min":1000,"pct":5},{"min":2500,"pct":8}]',
  delivery_fee numeric not null default 0,
  min_order numeric not null default 0,
  delivery_days jsonb not null default '[{"id":"wed","label":"Wednesday","time":"14:00 to 18:00"},{"id":"sat","label":"Saturday","time":"09:00 to 13:00"}]',
  areas jsonb not null default '["Ibex Hill","Kabulonga","Woodlands","Leopards Hill","Chalala","Roma","Olympia","Rhodes Park"]',
  momo_instructions text not null default 'Send mobile money to the Mutambo Beef number shown in the shop and give the reference to staff.',
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1);

-- ===== Profiles =====
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  area text,
  member_code text unique not null default lpad((floor(random()*1000000))::int::text, 6, '0'),
  role text not null default 'customer' check (role in ('customer','staff','admin')),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare code text;
begin
  loop
    code := lpad((floor(random()*1000000))::int::text, 6, '0');
    exit when not exists (select 1 from public.profiles where member_code = code);
  end loop;
  insert into public.profiles (id, full_name, phone, area, member_code)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone', new.raw_user_meta_data->>'area', code);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('staff','admin'));
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ===== Products =====
create table public.products (
  id text primary key,
  name text not null,
  category text not null,
  unit text not null check (unit in ('kg','pack')),
  price numeric check (price is null or price >= 0),   -- ZMW per kg or per pack; null = not on sale yet
  img text,
  description text,
  contains jsonb,
  active boolean not null default true,
  sort int not null default 0
);

-- ===== Wallet ledger =====
create table public.wallet_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete restrict,
  type text not null check (type in ('topup','bonus','purchase','refund','adjust')),
  amount numeric not null,                 -- + credit, - debit
  method text,                             -- cash | mobile_money | card | gateway | wallet
  reference text,
  order_id bigint,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.wallet_transactions (user_id, created_at desc);

-- ===== Orders =====
create table public.orders (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id),
  channel text not null check (channel in ('online','pos')),
  status text not null default 'pending' check (status in ('pending','paid','packed','out_for_delivery','delivered','collected','completed','cancelled')),
  fulfilment text not null check (fulfilment in ('delivery','collect','in_store')),
  delivery_day text,
  area text,
  note text,
  subtotal numeric not null,
  discount numeric not null default 0,
  delivery_fee numeric not null default 0,
  total numeric not null,
  payment_method text not null check (payment_method in ('wallet','cash','mobile_money','card','pay_on_delivery')),
  paid boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index on public.orders (created_at desc);
create table public.order_items (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  product_id text not null references public.products(id),
  name text not null,
  unit text not null,
  qty numeric not null check (qty > 0),
  unit_price numeric not null,
  line_total numeric not null
);
create index on public.order_items (order_id);

-- ===== RLS =====
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

create policy "settings readable" on public.settings for select using (true);
create policy "settings admin write" on public.settings for update using (public.is_admin()) with check (public.is_admin());

create policy "own profile or staff" on public.profiles for select using (id = auth.uid() or public.is_staff());
create policy "update own profile" on public.profiles for update using (id = auth.uid())
  with check (id = auth.uid() and role = (select p.role from public.profiles p where p.id = auth.uid()));
create policy "admin manages profiles" on public.profiles for update using (public.is_admin()) with check (public.is_admin());

create policy "products readable" on public.products for select using (active or public.is_staff());
create policy "admin products insert" on public.products for insert with check (public.is_admin());
create policy "admin products update" on public.products for update using (public.is_admin()) with check (public.is_admin());

create policy "own wallet or staff" on public.wallet_transactions for select using (user_id = auth.uid() or public.is_staff());
create policy "own orders or staff" on public.orders for select using (user_id = auth.uid() or public.is_staff());
create policy "own items or staff" on public.order_items for select using (
  public.is_staff() or exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));
-- No direct insert/update on money tables: only the functions below write them.

-- ===== Helpers =====
create or replace function public.wallet_balance(uid uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0) from public.wallet_transactions where user_id = uid;
$$;
revoke execute on function public.wallet_balance(uuid) from public, anon;

create or replace function public.topup_bonus_for(amount numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(round(amount * max((t->>'pct')::numeric) / 100, 2), 0)
  from public.settings s, jsonb_array_elements(s.topup_bonus) t
  where amount >= (t->>'min')::numeric;
$$;

-- Price a cart server-side. items: [{"id":"rump","qty":1.5}, ...]
create or replace function public._price_items(items jsonb)
returns table (product_id text, name text, unit text, qty numeric, unit_price numeric, line_total numeric)
language plpgsql stable security definer set search_path = public as $$
declare it jsonb; p public.products;
begin
  if items is null or jsonb_array_length(items) = 0 then raise exception 'Your order is empty'; end if;
  for it in select * from jsonb_array_elements(items) loop
    select * into p from public.products where id = it->>'id' and active;
    if not found then raise exception 'Item % is not available', it->>'id'; end if;
    if p.price is null then raise exception '% has no price yet', p.name; end if;
    if (it->>'qty')::numeric <= 0 then raise exception 'Quantity must be above zero'; end if;
    if p.unit = 'kg' and ((it->>'qty')::numeric * 2) <> floor((it->>'qty')::numeric * 2) then raise exception 'Order % in half-kilo steps', p.name; end if;
    if p.unit = 'pack' and (it->>'qty')::numeric <> floor((it->>'qty')::numeric) then raise exception 'Order whole packs of %', p.name; end if;
    product_id := p.id; name := p.name; unit := p.unit; qty := (it->>'qty')::numeric;
    unit_price := p.price; line_total := round(p.price * qty, 2);
    return next;
  end loop;
end $$;

-- ===== Customer: my summary =====
create or replace function public.my_summary() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'full_name', p.full_name, 'phone', p.phone, 'area', p.area, 'member_code', p.member_code, 'role', p.role,
    'balance', public.wallet_balance(p.id),
    'lifetime_spend', coalesce((select sum(total) from public.orders o where o.user_id = p.id and o.status <> 'cancelled' and o.paid), 0))
  from public.profiles p where p.id = auth.uid();
$$;

-- ===== Customer: place an online order =====
create or replace function public.place_online_order(items jsonb, fulfilment text, delivery_day text, area text, note text, payment text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s public.settings; sub numeric; disc numeric := 0; fee numeric := 0; tot numeric; oid bigint; bal numeric;
begin
  if uid is null then raise exception 'Please sign in to order'; end if;
  if fulfilment not in ('delivery','collect') then raise exception 'Choose delivery or collection'; end if;
  if payment not in ('wallet','pay_on_delivery') then raise exception 'Choose wallet or pay on delivery'; end if;
  select * into s from public.settings where id = 1;
  create temp table _lines on commit drop as select * from public._price_items(items);
  select sum(line_total) into sub from _lines;
  if sub < s.min_order then raise exception 'The minimum order is K %', s.min_order; end if;
  if payment = 'wallet' then disc := round(sub * s.wallet_discount_pct / 100, 2); end if;
  if fulfilment = 'delivery' then fee := s.delivery_fee; end if;
  tot := sub - disc + fee;
  if payment = 'wallet' then
    perform pg_advisory_xact_lock(hashtext(uid::text));
    bal := public.wallet_balance(uid);
    if bal < tot then raise exception 'Your wallet balance (K %) is below the order total (K %). Top up first.', bal, tot; end if;
  end if;
  insert into public.orders (user_id, channel, status, fulfilment, delivery_day, area, note, subtotal, discount, delivery_fee, total, payment_method, paid, created_by)
  values (uid, 'online', case when payment = 'wallet' then 'paid' else 'pending' end, fulfilment, delivery_day, area, note, sub, disc, fee, tot, payment, payment = 'wallet', uid)
  returning id into oid;
  insert into public.order_items (order_id, product_id, name, unit, qty, unit_price, line_total)
    select oid, product_id, name, unit, qty, unit_price, line_total from _lines;
  if payment = 'wallet' then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, created_by)
    values (uid, 'purchase', -tot, 'wallet', oid, uid);
  end if;
  return jsonb_build_object('order_id', oid, 'subtotal', sub, 'discount', disc, 'delivery_fee', fee, 'total', tot, 'balance', public.wallet_balance(uid));
end $$;

-- ===== Staff: find a member =====
create or replace function public.find_member(q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'member_code', p.member_code, 'balance', public.wallet_balance(p.id))), '[]'::jsonb)
  into r from (select * from public.profiles
     where member_code = trim(q) or regexp_replace(coalesce(phone,''), '\D', '', 'g') like '%' || regexp_replace(q, '\D', '', 'g') || '%' and length(regexp_replace(q, '\D', '', 'g')) >= 6
        or full_name ilike '%' || trim(q) || '%' limit 8) p;
  return r;
end $$;

-- ===== Staff: top up a wallet (applies bonus) =====
create or replace function public.topup_wallet(customer uuid, amount numeric, method text, reference text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b numeric;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if amount is null or amount <= 0 then raise exception 'Enter an amount above zero'; end if;
  if method not in ('cash','mobile_money','card','gateway') then raise exception 'Unknown payment method'; end if;
  if method = 'mobile_money' and coalesce(trim(reference),'') = '' then raise exception 'Add the mobile money reference'; end if;
  insert into public.wallet_transactions (user_id, type, amount, method, reference, created_by) values (customer, 'topup', amount, method, reference, auth.uid());
  b := public.topup_bonus_for(amount);
  if b > 0 then
    insert into public.wallet_transactions (user_id, type, amount, method, reference, created_by) values (customer, 'bonus', b, 'wallet', 'Top-up bonus', auth.uid());
  end if;
  return jsonb_build_object('bonus', b, 'balance', public.wallet_balance(customer));
end $$;

-- ===== Staff: in-store sale =====
create or replace function public.pos_sale(customer uuid, items jsonb, payment text, reference text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.settings; sub numeric; disc numeric := 0; tot numeric; oid bigint; bal numeric;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if payment not in ('wallet','cash','mobile_money','card') then raise exception 'Unknown payment method'; end if;
  if payment = 'wallet' and customer is null then raise exception 'Find the member first to pay by wallet'; end if;
  select * into s from public.settings where id = 1;
  create temp table _lines on commit drop as select * from public._price_items(items);
  select sum(line_total) into sub from _lines;
  if payment = 'wallet' then disc := round(sub * s.wallet_discount_pct / 100, 2); end if;
  tot := sub - disc;
  if payment = 'wallet' then
    perform pg_advisory_xact_lock(hashtext(customer::text));
    bal := public.wallet_balance(customer);
    if bal < tot then raise exception 'Wallet balance K % is below K %', bal, tot; end if;
  end if;
  insert into public.orders (user_id, channel, status, fulfilment, subtotal, discount, total, payment_method, paid, note, created_by)
  values (customer, 'pos', 'completed', 'in_store', sub, disc, tot, payment, true, nullif(reference,''), auth.uid())
  returning id into oid;
  insert into public.order_items (order_id, product_id, name, unit, qty, unit_price, line_total)
    select oid, product_id, name, unit, qty, unit_price, line_total from _lines;
  if payment = 'wallet' then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, created_by) values (customer, 'purchase', -tot, 'wallet', oid, auth.uid());
  end if;
  return jsonb_build_object('order_id', oid, 'subtotal', sub, 'discount', disc, 'total', tot,
    'balance', case when customer is null then null else public.wallet_balance(customer) end);
end $$;

-- ===== Staff: move an online order along =====
create or replace function public.set_order_status(order_id bigint, new_status text, mark_paid boolean default false, paid_method text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into o from public.orders where id = order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if new_status = 'cancelled' and o.payment_method = 'wallet' and o.paid then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, reference, created_by)
    values (o.user_id, 'refund', o.total, 'wallet', o.id, 'Order cancelled', auth.uid());
  end if;
  update public.orders set status = new_status,
    paid = paid or mark_paid,
    payment_method = case when mark_paid and paid_method in ('cash','mobile_money','card') then paid_method else payment_method end
  where id = order_id;
end $$;

-- ===== Staff: today's cash report =====
create or replace function public.day_report(day date default (now() at time zone 'Africa/Lusaka')::date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select jsonb_build_object(
    'sales_total', coalesce((select sum(total) from public.orders where paid and status <> 'cancelled' and (created_at at time zone 'Africa/Lusaka')::date = day), 0),
    'orders', (select count(*) from public.orders where status <> 'cancelled' and (created_at at time zone 'Africa/Lusaka')::date = day),
    'by_method', coalesce((select jsonb_object_agg(payment_method, t) from (select payment_method, sum(total) t from public.orders where paid and status <> 'cancelled' and (created_at at time zone 'Africa/Lusaka')::date = day group by 1) x), '{}'::jsonb),
    'topups', coalesce((select jsonb_object_agg(method, t) from (select method, sum(amount) t from public.wallet_transactions where type = 'topup' and (created_at at time zone 'Africa/Lusaka')::date = day group by 1) y), '{}'::jsonb),
    'cash_in', coalesce((select sum(total) from public.orders where paid and status <> 'cancelled' and payment_method in ('cash','mobile_money','card') and (created_at at time zone 'Africa/Lusaka')::date = day), 0)
             + coalesce((select sum(amount) from public.wallet_transactions where type = 'topup' and (created_at at time zone 'Africa/Lusaka')::date = day), 0),
    'open_online', (select count(*) from public.orders where channel = 'online' and status in ('pending','paid','packed','out_for_delivery'))
  ) into r;
  return r;
end $$;

-- Lock down function execution
revoke execute on function public._price_items(jsonb) from public, anon, authenticated;
revoke execute on function public.topup_bonus_for(numeric) from public, anon;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.my_summary() to authenticated;
grant execute on function public.place_online_order(jsonb, text, text, text, text, text) to authenticated;
grant execute on function public.find_member(text) to authenticated;
grant execute on function public.topup_wallet(uuid, numeric, text, text) to authenticated;
grant execute on function public.pos_sale(uuid, jsonb, text, text) to authenticated;
grant execute on function public.set_order_status(bigint, text, boolean, text) to authenticated;
grant execute on function public.day_report(date) to authenticated;
grant execute on function public.topup_bonus_for(numeric) to authenticated;
revoke execute on function public.my_summary() from anon;
revoke execute on function public.place_online_order(jsonb, text, text, text, text, text) from anon;
revoke execute on function public.find_member(text) from anon;
revoke execute on function public.topup_wallet(uuid, numeric, text, text) from anon;
revoke execute on function public.pos_sale(uuid, jsonb, text, text) from anon;
revoke execute on function public.set_order_status(bigint, text, boolean, text) from anon;
revoke execute on function public.day_report(date) from anon;
