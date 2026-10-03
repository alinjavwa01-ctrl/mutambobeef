create or replace function public.place_online_order(items jsonb, fulfilment text, delivery_day text, area text, note text, payment text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s public.settings; lines jsonb; sub numeric; disc numeric := 0; fee numeric := 0; tot numeric; oid bigint; bal numeric; bad text;
begin
  if uid is null then raise exception 'Please sign in to order'; end if;
  if fulfilment not in ('delivery','collect') then raise exception 'Choose delivery or collection'; end if;
  if payment not in ('wallet','pay_on_delivery') then raise exception 'Choose wallet or pay on delivery'; end if;
  select * into s from public.settings where id = 1;
  select jsonb_agg(to_jsonb(l)) into lines from public._price_items(items) l;
  select l.name into bad from jsonb_to_recordset(lines) l(name text, unit text, qty numeric) where l.unit = 'kg' and l.qty * 2 <> floor(l.qty * 2) limit 1;
  if bad is not null then raise exception 'Order % in half-kilo steps', bad; end if;
  select sum(l.line_total) into sub from jsonb_to_recordset(lines) l(line_total numeric);
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
  values (uid, 'online', case when payment = 'wallet' then 'paid' else 'pending' end, fulfilment, delivery_day, area, left(note, 500), sub, disc, fee, tot, payment, payment = 'wallet', uid)
  returning id into oid;
  insert into public.order_items (order_id, product_id, name, unit, qty, unit_price, line_total)
    select oid, l.product_id, l.name, l.unit, l.qty, l.unit_price, l.line_total
    from jsonb_to_recordset(lines) l(product_id text, name text, unit text, qty numeric, unit_price numeric, line_total numeric);
  if payment = 'wallet' then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, created_by)
    values (uid, 'purchase', -tot, 'wallet', oid, uid);
  end if;
  return jsonb_build_object('order_id', oid, 'subtotal', sub, 'discount', disc, 'delivery_fee', fee, 'total', tot, 'balance', public.wallet_balance(uid));
end $$;

create or replace function public.pos_sale(customer uuid, items jsonb, payment text, reference text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.settings; lines jsonb; sub numeric; disc numeric := 0; tot numeric; oid bigint; bal numeric;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if payment not in ('wallet','cash','mobile_money','card') then raise exception 'Unknown payment method'; end if;
  if payment = 'wallet' and customer is null then raise exception 'Find the member first to pay by wallet'; end if;
  if payment = 'mobile_money' and coalesce(trim(reference),'') = '' then raise exception 'Add the mobile money reference'; end if;
  select * into s from public.settings where id = 1;
  select jsonb_agg(to_jsonb(l)) into lines from public._price_items(items) l;
  select sum(l.line_total) into sub from jsonb_to_recordset(lines) l(line_total numeric);
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
    select oid, l.product_id, l.name, l.unit, l.qty, l.unit_price, l.line_total
    from jsonb_to_recordset(lines) l(product_id text, name text, unit text, qty numeric, unit_price numeric, line_total numeric);
  if payment = 'wallet' then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, created_by) values (customer, 'purchase', -tot, 'wallet', oid, auth.uid());
  end if;
  return jsonb_build_object('order_id', oid, 'subtotal', sub, 'discount', disc, 'total', tot,
    'balance', case when customer is null then null else public.wallet_balance(customer) end);
end $$;
revoke execute on function public.place_online_order(jsonb,text,text,text,text,text) from public, anon;
revoke execute on function public.pos_sale(uuid,jsonb,text,text) from public, anon;
grant execute on function public.place_online_order(jsonb,text,text,text,text,text) to authenticated;
grant execute on function public.pos_sale(uuid,jsonb,text,text) to authenticated;
