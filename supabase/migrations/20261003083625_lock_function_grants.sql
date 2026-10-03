do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' loop
    execute format('revoke execute on function %s from anon, public', f.sig);
  end loop;
end $$;
revoke execute on function public.wallet_balance(uuid) from authenticated;
revoke execute on function public._price_items(jsonb) from authenticated;
revoke execute on function public.handle_new_user() from authenticated;
alter default privileges in schema public revoke execute on functions from anon, public;
