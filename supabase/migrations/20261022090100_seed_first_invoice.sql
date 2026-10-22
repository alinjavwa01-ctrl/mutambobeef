-- First invoice: MB-INV-2026-001 to Grandaddy's Shoka Nyama (delivered 15 Oct 2026, signed for by Sylvia), unpaid.
do $$
declare uid uuid; d text := '260765661234'; inv_id bigint;
begin
  select id into uid from auth.users where phone = d;
  if uid is null then uid := public._create_phone_user(d, 'Olly', 'Plot 206 Salama Park Road, Lusaka'); end if;
  update public.profiles set full_name = 'Olly', phone = '+260765661234', whatsapp = '+260765661234',
    business_name = 'Grandaddy''s Shoka Nyama', address = 'Plot 206 Salama Park Road, Lusaka', area = 'Plot 206 Salama Park Road, Lusaka'
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
