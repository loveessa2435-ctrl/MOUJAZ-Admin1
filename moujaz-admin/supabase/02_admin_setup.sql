-- Run after creating public.orders and public.create_moujaz_order.
-- SECURITY: Never add a browser-facing service role key.
create table if not exists public.admin_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('OWNER','ADMIN','EMPLOYEE')),
  created_at timestamptz not null default now()
);
alter table public.admin_members enable row level security;
revoke all on public.admin_members from anon, authenticated;

-- Only authenticated caller can learn whether THEY are an admin.
create or replace function public.my_moujaz_admin_role()
returns text language sql stable security definer set search_path = ''
as $$
  select role from public.admin_members where user_id=(select auth.uid()) limit 1;
$$;
revoke all on function public.my_moujaz_admin_role() from public;
grant execute on function public.my_moujaz_admin_role() to authenticated;

-- RLS on orders: admins can read all orders; students retain their own read policy.
drop policy if exists "Moujaz admins can view orders" on public.orders;
create policy "Moujaz admins can view orders" on public.orders
for select to authenticated
using ((select public.my_moujaz_admin_role()) in ('OWNER','ADMIN','EMPLOYEE'));

-- Admin-only controlled status/payment updates. No direct UPDATE grant to browser clients.
create or replace function public.admin_update_moujaz_order(
  p_order_id uuid, p_status text, p_payment_confirmed boolean
) returns public.orders
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text;
  v_order public.orders;
begin
  v_role := public.my_moujaz_admin_role();
  if v_role not in ('OWNER','ADMIN') or v_role is null then
    raise exception 'Not authorized';
  end if;
  if p_status not in ('pending','working','delivered') or p_status is null then
    raise exception 'Invalid status';
  end if;
  if p_payment_confirmed is null then raise exception 'Invalid payment state'; end if;
  if p_status in ('working','delivered') and not p_payment_confirmed then
    raise exception 'Payment confirmation required';
  end if;
  update public.orders
  set status=p_status, payment_confirmed=p_payment_confirmed
  where id=p_order_id returning * into v_order;
  if not found then raise exception 'Order not found'; end if;
  return v_order;
end;
$$;
revoke all on function public.admin_update_moujaz_order(uuid,text,boolean) from public;
grant execute on function public.admin_update_moujaz_order(uuid,text,boolean) to authenticated;

-- Payment is a separate state from workflow status.
alter table public.orders add column if not exists payment_confirmed boolean not null default false;

-- IMPORTANT: Replace UUID with your own user ID from Authentication > Users.
-- Run this INSERT separately AFTER confirming your account ID:
-- insert into public.admin_members (user_id,role)
-- values ('YOUR_AUTH_USER_UUID','OWNER')
-- on conflict (user_id) do update set role='OWNER';
