create or replace function public.set_order_status(order_id bigint, new_status text, mark_paid boolean default false, paid_method text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  if not public.is_staff() then raise exception 'Staff only'; end if;
  if new_status not in ('pending','paid','packed','out_for_delivery','delivered','collected','completed','cancelled') then raise exception 'Unknown status'; end if;
  select * into o from public.orders where id = order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if o.status = 'cancelled' then raise exception 'This order is already cancelled'; end if;
  if new_status = 'cancelled' and o.payment_method = 'wallet' and o.paid then
    insert into public.wallet_transactions (user_id, type, amount, method, order_id, reference, created_by)
    values (o.user_id, 'refund', o.total, 'wallet', o.id, 'Order cancelled', auth.uid());
  end if;
  update public.orders set status = new_status,
    paid = paid or mark_paid,
    payment_method = case when mark_paid and paid_method in ('cash','mobile_money','card') then paid_method else payment_method end
  where id = order_id;
end $$;
revoke execute on function public.set_order_status(bigint,text,boolean,text) from public, anon;
grant execute on function public.set_order_status(bigint,text,boolean,text) to authenticated;
