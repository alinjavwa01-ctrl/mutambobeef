alter policy "products readable" on public.products to anon, authenticated using (active);
create policy "products staff" on public.products for select to authenticated using (public.is_staff());
alter policy "admin products insert" on public.products to authenticated;
alter policy "admin products update" on public.products to authenticated;
alter policy "settings readable" on public.settings to anon, authenticated;
alter policy "settings admin write" on public.settings to authenticated;
alter policy "own items or staff" on public.order_items to authenticated using (public.is_staff() or exists (select 1 from public.orders o where o.id = order_items.order_id and o.user_id = (select auth.uid())));
alter policy "own orders or staff" on public.orders to authenticated using (user_id = (select auth.uid()) or public.is_staff());
alter policy "own wallet or staff" on public.wallet_transactions to authenticated using (user_id = (select auth.uid()) or public.is_staff());
alter policy "own profile or staff" on public.profiles to authenticated using (id = (select auth.uid()) or public.is_staff());
alter policy "admin manages profiles" on public.profiles to authenticated;
alter policy "update own profile" on public.profiles to authenticated using (id = (select auth.uid())) with check (public.is_admin());

create or replace function public.update_my_profile(p_full_name text, p_phone text, p_area text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update profiles set full_name = coalesce(nullif(trim(p_full_name),''), full_name),
    phone = coalesce(nullif(trim(p_phone),''), phone),
    area = coalesce(nullif(trim(p_area),''), area)
  where id = auth.uid();
end $$;
revoke execute on function public.update_my_profile(text,text,text) from public, anon;
grant execute on function public.update_my_profile(text,text,text) to authenticated;
