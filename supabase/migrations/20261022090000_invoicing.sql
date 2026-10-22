-- ===== Invoicing =====
-- Staff raise invoices against customer accounts from the POS. Each invoice has an unguessable public link
-- (/i/<token>) that shows that one invoice without signing in. Signed-in customers see all their invoices.

-- Billing details on accounts
alter table public.profiles
  add column if not exists business_name text,
  add column if not exists address text,
  add column if not exists tpin text,
  add column if not exists whatsapp text;

-- Feature flags for the "later" items
alter table public.settings
  add column if not exists invoice_pay_from_balance boolean not null default false,
  add column if not exists momo_auto_match boolean not null default false;

-- One counter per year. Unlike a plain sequence it never skips on a rolled-back insert, and it never goes back,
-- so numbers are never reused (voided invoices keep theirs).
create table public.invoice_counters (
  year int primary key,
  last int not null default 0
);

create table public.invoices (
  id bigint generated always as identity primary key,
  number text not null unique,
  public_token text not null unique,
  account_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'draft' check (status in ('draft','sent','opened','paid','void')),
  invoice_date date not null,                 -- = delivery date
  due_date date not null,                     -- due on delivery
  delivered_at timestamptz,
  delivered_to text,
  signed_by text,
  delivery_note_url text,
  bill_to jsonb not null,                     -- the account's billing details as they were when the invoice was issued
  total_kg numeric(10,2) not null default 0,
  total_k numeric(12,2) not null default 0,
  discount_k numeric(12,2) not null default 0, -- balance discount, when settled from the account balance
  sent_at timestamptz,
  opened_at timestamptz,
  paid_at timestamptz,
  paid_method text check (paid_method in ('balance','momo','cash','bank')),
  paid_ref text,
  void_reason text,
  voided_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint paid_has_method check (status <> 'paid' or (paid_at is not null and paid_method is not null)),
  constraint void_has_reason check (status <> 'void' or coalesce(trim(void_reason), '') <> '')
);
create index on public.invoices (account_id, invoice_date desc);
create index on public.invoices (status, invoice_date desc);

create table public.invoice_lines (
  id bigint generated always as identity primary key,
  invoice_id bigint not null references public.invoices(id) on delete cascade,
  sort int not null default 0,
  cut text not null,
  kg numeric(10,2) not null check (kg > 0),
  price_per_kg_k numeric(12,2) not null check (price_per_kg_k >= 0),
  amount_k numeric(12,2) not null
);
create index on public.invoice_lines (invoice_id, sort);

alter table public.wallet_transactions add column if not exists invoice_id bigint references public.invoices(id);

-- MoMo payments recorded for auto-matching (behind settings.momo_auto_match)
create table public.momo_payments (
  id bigint generated always as identity primary key,
  txn_id text not null unique,
  amount numeric(12,2) not null check (amount > 0),
  reference text,
  sender text,
  invoice_id bigint references public.invoices(id),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- ===== RLS =====
alter table public.invoice_counters enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;
alter table public.momo_payments enable row level security;
-- No anon policies: the public link goes through invoice_by_token(), which returns one invoice by exact token.
create policy "own invoices or staff" on public.invoices for select to authenticated
  using (public.is_staff() or (account_id = (select auth.uid()) and status <> 'draft'));
create policy "own invoice lines or staff" on public.invoice_lines for select to authenticated
  using (public.is_staff() or exists (select 1 from public.invoices i where i.id = invoice_lines.invoice_id and i.account_id = (select auth.uid()) and i.status <> 'draft'));
create policy "staff momo" on public.momo_payments for select to authenticated using (public.is_staff());
-- No direct writes: only the functions below write invoices.

-- ===== Helpers =====
create or replace function public._phone_digits(p text) returns text
language sql immutable set search_path = public as $$
  -- Zambian numbers to 260XXXXXXXXX; anything else keeps its digits.
  select case
    when d ~ '^0[0-9]{9}$' then '260' || substr(d, 2)
    when d ~ '^[0-9]{9}$' then '260' || d
    else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') d) x;
$$;

create or replace function public._bill_to(acct uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'name', coalesce(nullif(trim(p.business_name), ''), p.full_name),
    'attn', case when nullif(trim(p.business_name), '') is not null then p.full_name end,
    'phone', coalesce(nullif(trim(p.whatsapp), ''), p.phone),
    'address', coalesce(nullif(trim(p.address), ''), p.area),
    'tpin', nullif(trim(p.tpin), ''),
    'account', p.member_code)
  from public.profiles p where p.id = acct;
$$;

create or replace function public._next_invoice_number(d date) returns text
language plpgsql security definer set search_path = public as $$
declare y int := extract(year from d); n int;
begin
  insert into public.invoice_counters (year, last) values (y, 1)
  on conflict (year) do update set last = public.invoice_counters.last + 1
  returning last into n;
  return format('MB-INV-%s-%s', y, case when n < 1000 then lpad(n::text, 3, '0') else n::text end);
end $$;

create or replace function public._invoice_token(num text) returns text
language plpgsql volatile set search_path = public, extensions as $$
declare alphabet text := 'abcdefghjkmnpqrstuvwxyz23456789'; b bytea := extensions.gen_random_bytes(10); s text := ''; i int;
begin
  for i in 0..9 loop s := s || substr(alphabet, (get_byte(b, i) % 31) + 1, 1); end loop; -- ~49 bits
  return num || '-' || s;
end $$;

-- Validate and price invoice lines. lines: [{"cut":"Rump","kg":17,"price_per_kg_k":200}, ...]
create or replace function public._invoice_lines(lines jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare it jsonb; out jsonb := '[]'; c text; kg numeric; pr numeric; i int := 0;
begin
  if lines is null or jsonb_typeof(lines) <> 'array' or jsonb_array_length(lines) = 0 then raise exception 'Add at least one line'; end if;
  if jsonb_array_length(lines) > 60 then raise exception 'Too many lines'; end if;
  for it in select * from jsonb_array_elements(lines) loop
    i := i + 1;
    c := left(trim(coalesce(it->>'cut', '')), 80);
    kg := nullif(it->>'kg', '')::numeric;
    pr := nullif(it->>'price_per_kg_k', '')::numeric;
    if c = '' then raise exception 'Line %: choose a cut', i; end if;
    if kg is null or kg <= 0 or kg > 10000 then raise exception 'Line % (%): enter the weight in kg', i, c; end if;
    if pr is null or pr < 0 or pr > 100000 then raise exception 'Line % (%): enter the price per kg', i, c; end if;
    kg := round(kg, 2); pr := round(pr, 2);
    out := out || jsonb_build_object('sort', i, 'cut', c, 'kg', kg, 'price_per_kg_k', pr, 'amount_k', round(kg * pr, 2));
  end loop;
  return out;
end $$;

create or replace function public._invoice_json(inv public.invoices) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'number', inv.number, 'token', inv.public_token, 'status', inv.status,
    'invoice_date', inv.invoice_date, 'due_date', inv.due_date,
    'delivered_at', inv.delivered_at, 'delivered_to', inv.delivered_to, 'signed_by', inv.signed_by, 'delivery_note_url', inv.delivery_note_url,
    'bill_to', inv.bill_to, 'total_kg', inv.total_kg, 'total_k', inv.total_k, 'discount_k', inv.discount_k,
    'sent_at', inv.sent_at, 'opened_at', inv.opened_at, 'paid_at', inv.paid_at, 'paid_method', inv.paid_method, 'paid_ref', inv.paid_ref,
    'void_reason', inv.void_reason, 'voided_at', inv.voided_at,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('cut', l.cut, 'kg', l.kg, 'price_per_kg_k', l.price_per_kg_k, 'amount_k', l.amount_k) order by l.sort, l.id)
                       from public.invoice_lines l where l.invoice_id = inv.id), '[]'::jsonb));
$$;

-- Settle an invoice from the account balance, less the balance discount. Caller checks permission.
create or replace function public._settle_from_balance(inv_id bigint, actor uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv public.invoices; pct numeric; disc numeric; due numeric; bal numeric;
begin
  select * into inv from public.invoices where id = inv_id for update;
  if inv.status not in ('draft','sent','opened') then raise exception 'Invoice % is %', inv.number, inv.status; end if;
  perform pg_advisory_xact_lock(hashtext(inv.account_id::text));
  select wallet_discount_pct into pct from public.settings where id = 1;
  disc := round(inv.total_k * coalesce(pct, 0) / 100, 2);
  due := inv.total_k - disc;
  bal := public.wallet_balance(inv.account_id);
  if bal < due then raise exception 'Balance K % is below K % (invoice less % percent)', bal, due, pct; end if;
  insert into public.wallet_transactions (user_id, type, amount, method, reference, invoice_id, created_by)
  values (inv.account_id, 'purchase', -due, 'wallet', inv.number, inv.id, actor);
  update public.invoices set status = 'paid', paid_at = now(), paid_method = 'balance', discount_k = disc,
    paid_ref = format('Balance, %s%% off', pct), sent_at = coalesce(sent_at, now())
  where id = inv.id;
  return jsonb_build_object('number', inv.number, 'paid_k', due, 'discount_k', disc, 'balance', public.wallet_balance(inv.account_id));
end $$;

-- ===== Public: one invoice by its link token =====
create or replace function public.invoice_by_token(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare inv public.invoices; s public.settings; r jsonb; mine boolean;
begin
  if p_token is null or length(p_token) < 20 or length(p_token) > 80 then return null; end if;
  select * into inv from public.invoices where public_token = p_token;
  if not found then return null; end if;
  select * into s from public.settings where id = 1;
  mine := auth.uid() is not null and auth.uid() = inv.account_id;
  r := public._invoice_json(inv) || jsonb_build_object(
    'mine', mine,
    'pay_from_balance', s.invoice_pay_from_balance and inv.status in ('sent','opened'),
    'balance_discount_pct', s.wallet_discount_pct);
  if mine then r := r || jsonb_build_object('balance', public.wallet_balance(inv.account_id)); end if;
  return r;
end $$;

-- Same, and records the first time the customer opens the link (staff views don't count).
create or replace function public.open_invoice(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_token is not null and not public.is_staff() then
    update public.invoices set opened_at = now(),
      status = case when status in ('draft','sent') then 'opened' else status end,
      sent_at = coalesce(sent_at, now())
    where public_token = p_token and opened_at is null and status <> 'void';
  end if;
  return public.invoice_by_token(p_token);
end $$;

-- ===== Customer: all my invoices =====
create or replace function public.my_invoices() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'owed', coalesce((select sum(total_k) from public.invoices where account_id = auth.uid() and status in ('sent','opened')), 0),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object(
        'number', i.number, 'token', i.public_token, 'status', i.status, 'invoice_date', i.invoice_date,
        'total_kg', i.total_kg, 'total_k', i.total_k, 'discount_k', i.discount_k, 'paid_at', i.paid_at, 'paid_method', i.paid_method)
        order by (i.status in ('sent','opened')) desc, i.invoice_date desc, i.id desc)
      from public.invoices i where i.account_id = auth.uid() and i.status <> 'draft'), '[]'::jsonb));
$$;

-- Behind settings.invoice_pay_from_balance: the signed-in customer settles their own invoice from their balance.
create or replace function public.pay_invoice_from_balance(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv public.invoices;
begin
  if auth.uid() is null then raise exception 'Sign in to pay from your balance'; end if;
  if not (select invoice_pay_from_balance from public.settings where id = 1) then raise exception 'Paying invoices from your balance is not available yet'; end if;
  select * into inv from public.invoices where public_token = p_token;
  if not found or inv.account_id <> auth.uid() then raise exception 'Invoice not found'; end if;
  return public._settle_from_balance(inv.id, auth.uid());
end $$;

-- ===== Staff: accounts =====
-- Customers don't sign up for invoicing accounts; staff create them. The account is an auth user keyed by phone
-- (the same rows Supabase's admin createUser writes), so the customer can later sign in with phone + one-time code
-- and land on the same account. handle_new_user() creates the profile and account number.
create or replace function public._create_phone_user(d text, full_name text, address text) returns uuid
language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := gen_random_uuid(); now_ts timestamptz := now();
begin
  insert into auth.users (instance_id, id, aud, role, phone, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', d, now_ts,
    '{"provider":"phone","providers":["phone"]}', jsonb_build_object('full_name', trim(full_name), 'phone', '+' || d, 'area', trim(address)),
    now_ts, now_ts, '', '', '', '', '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (uid::text, uid, jsonb_build_object('sub', uid::text, 'phone', d, 'email_verified', false, 'phone_verified', false), 'phone', now_ts, now_ts);
  return uid;
end $$;

create or replace function public.staff_create_account(p_full_name text, p_phone text, p_business_name text, p_address text, p_tpin text, p_whatsapp text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d text := public._phone_digits(p_phone); uid uuid; existing text;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if coalesce(trim(p_full_name), '') = '' and coalesce(trim(p_business_name), '') = '' then raise exception 'Add a name or business name'; end if;
  if length(d) < 11 or length(d) > 15 then raise exception 'Add the phone number with country code, e.g. +260 97 123 4567'; end if;
  select p.member_code into existing from auth.users u join public.profiles p on p.id = u.id where u.phone = d;
  if existing is null then
    select p.member_code into existing from public.profiles p where public._phone_digits(p.phone) = d or public._phone_digits(p.whatsapp) = d limit 1;
  end if;
  if existing is not null then raise exception 'Account % already has this phone number', existing; end if;
  uid := public._create_phone_user(d, p_full_name, p_address);
  update public.profiles set
    full_name = nullif(trim(p_full_name), ''), phone = '+' || d,
    business_name = nullif(trim(p_business_name), ''), address = nullif(trim(p_address), ''), area = coalesce(nullif(trim(p_address), ''), area),
    tpin = nullif(trim(p_tpin), ''),
    whatsapp = '+' || coalesce(nullif(public._phone_digits(p_whatsapp), ''), d)
  where id = uid;
  return (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'member_code', p.member_code, 'balance', 0,
    'business_name', p.business_name, 'address', p.address, 'tpin', p.tpin, 'whatsapp', p.whatsapp) from public.profiles p where p.id = uid);
end $$;

create or replace function public.staff_update_account(p_id uuid, p_full_name text, p_business_name text, p_address text, p_tpin text, p_whatsapp text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  update public.profiles set
    full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
    business_name = nullif(trim(p_business_name), ''),
    address = nullif(trim(p_address), ''),
    tpin = nullif(trim(p_tpin), ''),
    whatsapp = case when nullif(public._phone_digits(p_whatsapp), '') is null then null else '+' || public._phone_digits(p_whatsapp) end
  where id = p_id;
  if not found then raise exception 'Account not found'; end if;
end $$;

-- find_member also searches business names and returns billing details
create or replace function public.find_member(q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; d text := regexp_replace(coalesce(q, ''), '\D', '', 'g');
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'member_code', p.member_code, 'balance', public.wallet_balance(p.id),
      'business_name', p.business_name, 'address', coalesce(p.address, p.area), 'tpin', p.tpin, 'whatsapp', p.whatsapp)), '[]'::jsonb)
  into r from (select * from public.profiles
     where member_code = trim(q)
        or (length(d) >= 6 and (regexp_replace(coalesce(phone, ''), '\D', '', 'g') like '%' || d || '%' or regexp_replace(coalesce(whatsapp, ''), '\D', '', 'g') like '%' || d || '%'))
        or full_name ilike '%' || trim(q) || '%'
        or business_name ilike '%' || trim(q) || '%'
     limit 8) p;
  return r;
end $$;

-- ===== Staff: invoices =====
create or replace function public.create_invoice(p_account uuid, p_invoice_date date, p_lines jsonb, p_delivered_to text, p_signed_by text, p_delivery_note_url text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ls jsonb := public._invoice_lines(p_lines); num text; inv_id bigint; tok text; bt jsonb;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if p_invoice_date is null then raise exception 'Add the delivery date'; end if;
  bt := public._bill_to(p_account);
  if bt is null then raise exception 'Choose a customer account'; end if;
  num := public._next_invoice_number(p_invoice_date);
  tok := public._invoice_token(num);
  insert into public.invoices (number, public_token, account_id, status, invoice_date, due_date, delivered_at, delivered_to, signed_by, delivery_note_url, bill_to, total_kg, total_k, created_by)
  values (num, tok, p_account, 'draft', p_invoice_date, p_invoice_date,
    case when nullif(trim(p_signed_by), '') is not null or nullif(trim(p_delivery_note_url), '') is not null then p_invoice_date::timestamp at time zone 'Africa/Lusaka' end,
    nullif(left(trim(p_delivered_to), 200), ''), nullif(left(trim(p_signed_by), 80), ''), nullif(trim(p_delivery_note_url), ''), bt,
    (select sum((l->>'kg')::numeric) from jsonb_array_elements(ls) l), (select sum((l->>'amount_k')::numeric) from jsonb_array_elements(ls) l), auth.uid())
  returning id into inv_id;
  insert into public.invoice_lines (invoice_id, sort, cut, kg, price_per_kg_k, amount_k)
    select inv_id, l.sort, l.cut, l.kg, l.price_per_kg_k, l.amount_k from jsonb_to_recordset(ls) l(sort int, cut text, kg numeric, price_per_kg_k numeric, amount_k numeric);
  return jsonb_build_object('id', inv_id, 'number', num, 'token', tok);
end $$;

-- Drafts can still be changed. The number stays.
create or replace function public.update_invoice_draft(p_id bigint, p_invoice_date date, p_lines jsonb, p_delivered_to text, p_signed_by text, p_delivery_note_url text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ls jsonb := public._invoice_lines(p_lines); inv public.invoices;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  select * into inv from public.invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if inv.status <> 'draft' then raise exception '% has been sent and can no longer be changed. Void it and raise a new one.', inv.number; end if;
  if p_invoice_date is null then raise exception 'Add the delivery date'; end if;
  delete from public.invoice_lines where invoice_id = p_id;
  insert into public.invoice_lines (invoice_id, sort, cut, kg, price_per_kg_k, amount_k)
    select p_id, l.sort, l.cut, l.kg, l.price_per_kg_k, l.amount_k from jsonb_to_recordset(ls) l(sort int, cut text, kg numeric, price_per_kg_k numeric, amount_k numeric);
  update public.invoices set invoice_date = p_invoice_date, due_date = p_invoice_date,
    delivered_at = case when nullif(trim(p_signed_by), '') is not null or nullif(trim(p_delivery_note_url), '') is not null then p_invoice_date::timestamp at time zone 'Africa/Lusaka' end,
    delivered_to = nullif(left(trim(p_delivered_to), 200), ''), signed_by = nullif(left(trim(p_signed_by), 80), ''), delivery_note_url = nullif(trim(p_delivery_note_url), ''),
    bill_to = public._bill_to(account_id),
    total_kg = (select sum((l->>'kg')::numeric) from jsonb_array_elements(ls) l),
    total_k = (select sum((l->>'amount_k')::numeric) from jsonb_array_elements(ls) l)
  where id = p_id;
  return jsonb_build_object('id', p_id, 'number', inv.number, 'token', inv.public_token);
end $$;

create or replace function public.mark_invoice_sent(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  update public.invoices set status = case when status = 'draft' then 'sent' else status end, sent_at = coalesce(sent_at, now())
  where id = p_id and status <> 'void';
  if not found then raise exception 'Invoice not found or void'; end if;
end $$;

create or replace function public.mark_invoice_paid(p_id bigint, p_method text, p_ref text, p_paid_on date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv public.invoices;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if p_method not in ('balance','momo','cash','bank') then raise exception 'Choose how it was paid'; end if;
  select * into inv from public.invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if inv.status not in ('draft','sent','opened') then raise exception '% is already %', inv.number, inv.status; end if;
  if p_method = 'balance' then return public._settle_from_balance(p_id, auth.uid()); end if;
  if p_method in ('momo','bank') and coalesce(trim(p_ref), '') = '' then raise exception 'Add the % reference', case when p_method = 'momo' then 'MoMo transaction' else 'bank' end; end if;
  update public.invoices set status = 'paid', paid_method = p_method, paid_ref = nullif(left(trim(p_ref), 120), ''),
    paid_at = case when p_paid_on is null or p_paid_on = (now() at time zone 'Africa/Lusaka')::date then now() else p_paid_on::timestamp at time zone 'Africa/Lusaka' + interval '12 hours' end,
    sent_at = coalesce(sent_at, now())
  where id = p_id;
  return jsonb_build_object('number', inv.number, 'paid_k', inv.total_k);
end $$;

create or replace function public.void_invoice(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare inv public.invoices;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why the invoice is being voided'; end if;
  select * into inv from public.invoices where id = p_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if inv.status = 'paid' then raise exception '% is paid. Refund it first, then void.', inv.number; end if;
  if inv.status = 'void' then raise exception '% is already void', inv.number; end if;
  update public.invoices set status = 'void', void_reason = left(trim(p_reason), 300), voided_at = now() where id = p_id;
end $$;

-- Behind settings.momo_auto_match: record a MoMo payment; if its reference is an open invoice number and it covers
-- the total, the invoice is marked paid. Ready for a MoMo callback or SMS forwarder to call later.
create or replace function public.record_momo_payment(p_txn_id text, p_amount numeric, p_reference text, p_sender text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare inv public.invoices; pid bigint; ref text := upper(regexp_replace(coalesce(p_reference, ''), '\s', '', 'g'));
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if not (select momo_auto_match from public.settings where id = 1) then raise exception 'MoMo matching is turned off'; end if;
  if coalesce(trim(p_txn_id), '') = '' then raise exception 'Add the MoMo transaction ID'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Add the amount'; end if;
  insert into public.momo_payments (txn_id, amount, reference, sender, created_by) values (trim(p_txn_id), p_amount, nullif(trim(p_reference), ''), nullif(trim(p_sender), ''), auth.uid())
  returning id into pid;
  select * into inv from public.invoices where upper(number) = ref and status in ('draft','sent','opened') for update;
  if found and p_amount >= inv.total_k then
    update public.invoices set status = 'paid', paid_method = 'momo', paid_ref = trim(p_txn_id), paid_at = now(), sent_at = coalesce(sent_at, now()) where id = inv.id;
    update public.momo_payments set invoice_id = inv.id where id = pid;
    return jsonb_build_object('matched', true, 'number', inv.number);
  end if;
  return jsonb_build_object('matched', false, 'reason', case when inv.id is null then 'No open invoice with that reference' else format('Amount is below the invoice total K %s', inv.total_k) end);
end $$;

-- ===== Delivery-note photos =====
-- Public bucket so the invoice page can show the photo; files sit under the invoice's unguessable token and the
-- bucket can't be listed (no select policy). Only staff upload.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('delivery-notes', 'delivery-notes', true, 8388608, array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do nothing;
create policy "staff upload delivery notes" on storage.objects for insert to authenticated
  with check (bucket_id = 'delivery-notes' and public.is_staff());

-- ===== Grants =====
revoke execute on function public._phone_digits(text) from public, anon, authenticated;
revoke execute on function public._bill_to(uuid) from public, anon, authenticated;
revoke execute on function public._next_invoice_number(date) from public, anon, authenticated;
revoke execute on function public._invoice_token(text) from public, anon, authenticated;
revoke execute on function public._invoice_lines(jsonb) from public, anon, authenticated;
revoke execute on function public._invoice_json(public.invoices) from public, anon, authenticated;
revoke execute on function public._settle_from_balance(bigint, uuid) from public, anon, authenticated;
revoke execute on function public._create_phone_user(text, text, text) from public, anon, authenticated;
revoke execute on function public.invoice_by_token(text) from public;
revoke execute on function public.open_invoice(text) from public;
grant execute on function public.invoice_by_token(text) to anon, authenticated;
grant execute on function public.open_invoice(text) to anon, authenticated;
revoke execute on function public.my_invoices() from public, anon;
revoke execute on function public.pay_invoice_from_balance(text) from public, anon;
revoke execute on function public.staff_create_account(text, text, text, text, text, text) from public, anon;
revoke execute on function public.staff_update_account(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.find_member(text) from public, anon;
revoke execute on function public.create_invoice(uuid, date, jsonb, text, text, text) from public, anon;
revoke execute on function public.update_invoice_draft(bigint, date, jsonb, text, text, text) from public, anon;
revoke execute on function public.mark_invoice_sent(bigint) from public, anon;
revoke execute on function public.mark_invoice_paid(bigint, text, text, date) from public, anon;
revoke execute on function public.void_invoice(bigint, text) from public, anon;
revoke execute on function public.record_momo_payment(text, numeric, text, text) from public, anon;
grant execute on function public.my_invoices() to authenticated;
grant execute on function public.pay_invoice_from_balance(text) to authenticated;
grant execute on function public.staff_create_account(text, text, text, text, text, text) to authenticated;
grant execute on function public.staff_update_account(uuid, text, text, text, text, text) to authenticated;
grant execute on function public.find_member(text) to authenticated;
grant execute on function public.create_invoice(uuid, date, jsonb, text, text, text) to authenticated;
grant execute on function public.update_invoice_draft(bigint, date, jsonb, text, text, text) to authenticated;
grant execute on function public.mark_invoice_sent(bigint) to authenticated;
grant execute on function public.mark_invoice_paid(bigint, text, text, date) to authenticated;
grant execute on function public.void_invoice(bigint, text) to authenticated;
grant execute on function public.record_momo_payment(text, numeric, text, text) to authenticated;
