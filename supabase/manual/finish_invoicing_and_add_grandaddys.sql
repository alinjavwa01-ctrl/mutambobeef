-- Run once in Supabase > SQL Editor (project mutambo-beef). Finishes the invoicing database setup and
-- adds Grandaddy's details + invoice MB-INV-2026-001 to the NEWEST customer account.
-- Check the result row says Grandaddy's Shoka Nyama before moving on.
-- Mutambo Beef invoicing: last step. Paste into Supabase > SQL Editor and click Run.
-- Safe to run once; tables and the first functions are already in place.

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
drop policy if exists "staff upload delivery notes" on storage.objects;
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

-- Add Grandaddy's details to the account you just created (the newest customer account), then add MB-INV-2026-001.
do $$
declare uid uuid; inv_id bigint;
begin
  select id into uid from public.profiles where role = 'customer' order by created_at desc limit 1;
  if uid is null then raise exception 'No customer account found. Create the Grandaddys account first.'; end if;
  update public.profiles set
    full_name = 'Olly',
    business_name = 'Grandaddy''s Shoka Nyama',
    phone = coalesce(nullif(phone, ''), '+260765661234'),
    whatsapp = '+260765661234',
    address = 'Plot 206 Salama Park Road, Lusaka',
    area = 'Plot 206 Salama Park Road, Lusaka'
  where id = uid;
  if not exists (select 1 from public.invoices where number = 'MB-INV-2026-001') then
    insert into public.invoice_counters (year, last) values (2026, 1) on conflict (year) do update set last = greatest(public.invoice_counters.last, 1);
    insert into public.invoices (number, public_token, account_id, status, invoice_date, due_date, delivered_at, delivered_to, signed_by, bill_to, total_kg, total_k, sent_at, created_by)
    values ('MB-INV-2026-001', public._invoice_token('MB-INV-2026-001'), uid, 'sent', '2026-10-15', '2026-10-15',
      timestamp '2026-10-15 12:00' at time zone 'Africa/Lusaka', 'Plot 206 Salama Park Road, Lusaka', 'Sylvia', public._bill_to(uid), 46.80, 9281,
      timestamp '2026-10-15 12:00' at time zone 'Africa/Lusaka', (select id from public.profiles where role = 'admin' order by created_at limit 1))
    returning id into inv_id;
    insert into public.invoice_lines (invoice_id, sort, cut, kg, price_per_kg_k, amount_k) values
      (inv_id, 1, 'Rump', 17.00, 200, 3400), (inv_id, 2, 'Topside', 14.00, 200, 2800), (inv_id, 3, 'Silverside', 15.80, 195, 3081);
  end if;
end $$;

select p.business_name, p.full_name, p.member_code, p.whatsapp, i.number, i.status, i.total_k,
  'https://mutambobeef.vercel.app/i/' || i.public_token as link
from public.invoices i join public.profiles p on p.id = i.account_id where i.number = 'MB-INV-2026-001';
