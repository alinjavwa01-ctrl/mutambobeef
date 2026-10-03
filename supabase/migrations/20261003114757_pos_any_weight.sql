create or replace function public._price_items(items jsonb)
returns table(product_id text, name text, unit text, qty numeric, unit_price numeric, line_total numeric)
language plpgsql security definer set search_path = public as $$
declare it jsonb; p public.products; q numeric;
begin
  if items is null or jsonb_typeof(items) <> 'array' or jsonb_array_length(items) = 0 then raise exception 'Your order is empty'; end if;
  for it in select * from jsonb_array_elements(items) loop
    select * into p from public.products where id = it->>'id' and active;
    if not found then raise exception 'Item % is not available', it->>'id'; end if;
    if p.price is null then raise exception '% has no price yet', p.name; end if;
    q := (it->>'qty')::numeric;
    if q is null or q <= 0 then raise exception 'Quantity must be above zero'; end if;
    if q > 500 then raise exception 'Quantity for % is too large', p.name; end if;
    if p.unit = 'kg' and round(q, 3) <> q then raise exception 'Weigh % to the gram (3 decimals at most)', p.name; end if;
    if p.unit = 'pack' and q <> floor(q) then raise exception 'Order whole packs of %', p.name; end if;
    product_id := p.id; name := p.name; unit := p.unit; qty := q;
    unit_price := p.price; line_total := round(p.price * q, 2);
    return next;
  end loop;
end $$;

create or replace function public.place_online_order(items jsonb, fulfilment text, delivery_day text, area text, note text, payment text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s public.settings; sub numeric; disc numeric := 0; fee numeric := 0; tot numeric; oid bigint; bal numeric; bad text;
begin
  if uid is null then raise exception 'Please sign in to order'; end if;
  if fulfilment not in ('delivery','collect') then raise exception 'Choose delivery or collection'; end if;
  if payment not in ('wallet','pay_on_delivery') then raise exception 'Choose wallet or pay on delivery'; end if;
  select * into s from public.settings where id = 1;
  create temp table _lines on commit drop as select * from public._price_items(items);
  select l.name into bad from _lines l where l.unit = 'kg' and l.qty * 2 <> floor(l.qty * 2) limit 1;
  if bad is not null then raise exception 'Order % in half-kilo steps', bad; end if;
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
  values (uid, 'online', case when payment = 'wallet' then 'paid' else 'pending' end, fulfilment, delivery_day, area, left(note, 500), sub, disc, fee, tot, payment, payment = 'wallet', uid)
  returning id into oid;
  insert into public.order_items (order_id, product_id, name, unit, qty, unit_price, line_total)
    select oid, l.product_id, l.name, l.unit, l.qty, l.unit_price, l.line_total from _lines l;
  if payment = 'wallet' then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, created_by)
    values (uid, 'purchase', -tot, 'wallet', oid, uid);
  end if;
  return jsonb_build_object('order_id', oid, 'subtotal', sub, 'discount', disc, 'delivery_fee', fee, 'total', tot, 'balance', public.wallet_balance(uid));
end $$;
revoke execute on function public._price_items(jsonb) from public, anon, authenticated;
revoke execute on function public.place_online_order(jsonb,text,text,text,text,text) from public, anon;
grant execute on function public.place_online_order(jsonb,text,text,text,text,text) to authenticated;
