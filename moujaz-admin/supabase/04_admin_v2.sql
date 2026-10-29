-- MOUJAZ Admin V2. Run AFTER 01_secure_orders.sql and 02_admin_setup.sql.
-- Back up your database first. Run once in Supabase SQL Editor.
create table if not exists public.moujaz_services (
 id text primary key, title text not null, enabled boolean not null default true,
 base_price integer not null default 0 check(base_price>=0), extra_pair_price integer not null default 0 check(extra_pair_price>=0),
 fast_price integer not null default 0 check(fast_price>=0), per_slide_price integer not null default 0 check(per_slide_price>=0),
 updated_at timestamptz not null default now()
);
insert into public.moujaz_services(id,title,enabled,base_price,extra_pair_price,fast_price,per_slide_price) values
 ('report','تقرير جامعي',true,5000,1000,2000,0),('cover','واجهة تقرير',true,2000,0,0,0),
 ('slides2d','عرض تقديمي 2D',true,0,0,0,1000),('excel','جداول Excel',true,0,0,0,0),
 ('thesis','تنسيق بحث التخرج',false,0,0,0,0),('slides3d','عرض تقديمي 3D',false,0,0,0,0)
on conflict(id) do nothing;
create table if not exists public.moujaz_coupons (
 code text primary key check(code ~ '^[A-Z0-9_-]{3,32}$'),
 discount_type text not null check(discount_type in ('percent','fixed')),
 amount integer not null check(amount>0), active boolean not null default true,
 expires_at timestamptz, max_uses integer check(max_uses is null or max_uses>0),
 used_count integer not null default 0 check(used_count>=0),
 service_id text references public.moujaz_services(id), created_at timestamptz not null default now(),
 check(discount_type<>'percent' or amount<=100)
);
create table if not exists public.moujaz_settings (
 key text primary key, value text not null default '', updated_at timestamptz not null default now()
);
insert into public.moujaz_settings(key,value) values ('support_telegram','https://t.me/MoujazSupport'),('announcement','') on conflict do nothing;
create table if not exists public.moujaz_audit (
 id bigint generated always as identity primary key, actor uuid not null, action text not null,
 target text not null, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
alter table public.orders add column if not exists coupon_code text;
alter table public.orders add column if not exists discount_amount integer not null default 0;
alter table public.moujaz_services enable row level security;
alter table public.moujaz_coupons enable row level security;
alter table public.moujaz_settings enable row level security;
alter table public.moujaz_audit enable row level security;
revoke all on public.moujaz_services,public.moujaz_coupons,public.moujaz_settings,public.moujaz_audit from anon,authenticated;
grant select on public.moujaz_services to authenticated;
drop policy if exists "authenticated services" on public.moujaz_services;
create policy "authenticated services" on public.moujaz_services for select to authenticated using (true);
-- Restrict management to SECURITY DEFINER functions; do not grant table writes.
create or replace function public.moujaz_admin_data(p_section text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_role text := public.my_moujaz_admin_role(); v_result jsonb;
begin
 if v_role is null or v_role not in ('OWNER','ADMIN','EMPLOYEE') then raise exception 'Not authorized'; end if;
 if p_section='coupons' and v_role in ('OWNER','ADMIN') then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]'::jsonb) into v_result from public.moujaz_coupons t;
 elsif p_section='services' then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]'::jsonb) into v_result from public.moujaz_services t;
 elsif p_section='settings' and v_role in ('OWNER','ADMIN') then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.key),'[]'::jsonb) into v_result from public.moujaz_settings t;
 elsif p_section='team' and v_role='OWNER' then
  select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',m.role,'email',u.email,'created_at',m.created_at)),'[]'::jsonb)
  into v_result from public.admin_members m join auth.users u on u.id=m.user_id;
 elsif p_section='students' and v_role in ('OWNER','ADMIN') then
  select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'email',u.email,'name',u.raw_user_meta_data->>'full_name','orders',coalesce(o.total,0),'spent',coalesce(o.spent,0)) order by u.created_at desc),'[]'::jsonb)
  into v_result from auth.users u left join lateral (select count(*) total,sum(case when payment_confirmed then price else 0 end) spent from public.orders where user_id=u.id) o on true
  where exists(select 1 from public.orders x where x.user_id=u.id);
 elsif p_section='audit' and v_role in ('OWNER','ADMIN') then
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc),'[]'::jsonb) into v_result from (select * from public.moujaz_audit order by created_at desc limit 100) t;
 else raise exception 'Not authorized for section'; end if;
 return v_result;
end $$;
revoke all on function public.moujaz_admin_data(text) from public;
grant execute on function public.moujaz_admin_data(text) to authenticated;

create or replace function public.moujaz_admin_mutate(p_section text,p_action text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_role text := public.my_moujaz_admin_role(); v_code text; v_email text; v_uid uuid; v_target text; v_record jsonb;
begin
 if v_role is null or v_role not in ('OWNER','ADMIN') then raise exception 'Not authorized'; end if;
 if jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Invalid payload'; end if;
 if p_section='coupons' and p_action='save' then
  v_code:=upper(trim(p_payload->>'code'));
  if v_code !~ '^[A-Z0-9_-]{3,32}$' then raise exception 'Invalid coupon code'; end if;
  insert into public.moujaz_coupons(code,discount_type,amount,active,expires_at,max_uses,service_id)
  values(v_code,p_payload->>'discount_type',(p_payload->>'amount')::integer,coalesce((p_payload->>'active')::boolean,true),nullif(p_payload->>'expires_at','')::timestamptz,nullif(p_payload->>'max_uses','')::integer,nullif(p_payload->>'service_id',''))
  on conflict(code) do update set discount_type=excluded.discount_type,amount=excluded.amount,active=excluded.active,expires_at=excluded.expires_at,max_uses=excluded.max_uses,service_id=excluded.service_id;
  v_target:=v_code;
 elsif p_section='services' and p_action='save' then
  v_target:=p_payload->>'id';
  update public.moujaz_services set enabled=(p_payload->>'enabled')::boolean,
   base_price=(p_payload->>'base_price')::integer,extra_pair_price=(p_payload->>'extra_pair_price')::integer,
   fast_price=(p_payload->>'fast_price')::integer,per_slide_price=(p_payload->>'per_slide_price')::integer,updated_at=now()
  where id=v_target;
  if not found then raise exception 'Service not found'; end if;
 elsif p_section='settings' and p_action='save' then
  v_target:=p_payload->>'key';
  if v_target not in ('support_telegram','announcement') then raise exception 'Setting not allowed'; end if;
  if length(coalesce(p_payload->>'value',''))>500 then raise exception 'Value too long'; end if;
  insert into public.moujaz_settings(key,value,updated_at) values(v_target,p_payload->>'value',now())
  on conflict(key) do update set value=excluded.value,updated_at=now();
 elsif p_section='team' and v_role='OWNER' then
  v_email:=lower(trim(p_payload->>'email'));
  select id into v_uid from auth.users where lower(email)=v_email limit 1;
  if v_uid is null then raise exception 'User must sign in with Google first'; end if;
  if v_uid=auth.uid() then raise exception 'Cannot change your own OWNER membership'; end if;
  if p_action='remove' then
   delete from public.admin_members where user_id=v_uid and role<>'OWNER';
   if not found then raise exception 'Member not found or OWNER protected'; end if;
  elsif p_action='save' then
   if p_payload->>'role' not in ('ADMIN','EMPLOYEE') then raise exception 'Invalid role'; end if;
   insert into public.admin_members(user_id,role) values(v_uid,p_payload->>'role')
   on conflict(user_id) do update set role=excluded.role where public.admin_members.role<>'OWNER';
   if not found then raise exception 'Cannot modify OWNER'; end if;
  else raise exception 'Invalid action'; end if;
  v_target:=v_email;
 else raise exception 'Invalid or unauthorized operation'; end if;
 insert into public.moujaz_audit(actor,action,target,details) values(auth.uid(),p_section||'.'||p_action,v_target,p_payload - 'value');
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.moujaz_admin_mutate(text,text,jsonb) from public;
grant execute on function public.moujaz_admin_mutate(text,text,jsonb) to authenticated;

-- Shared server-side pricing. Never trust the browser's price or discount.
create or replace function public.moujaz_quote(p_service text,p_pages integer,p_slides integer,p_delivery text,p_code text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_s public.moujaz_services; v_c public.moujaz_coupons; v_base integer; v_discount integer:=0; v_code text:=upper(trim(coalesce(p_code,'')));
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into v_s from public.moujaz_services where id=p_service and enabled=true;
 if not found then raise exception 'Service unavailable'; end if;
 if p_pages not between 10 and 30 or p_slides not between 1 and 100 or p_delivery not in ('normal','fast') then raise exception 'Invalid quantity'; end if;
 v_base:=case p_service when 'report' then v_s.base_price+ceil(greatest(0,p_pages-10)/2.0)::integer*v_s.extra_pair_price+(case when p_delivery='fast' then v_s.fast_price else 0 end)
 when 'slides2d' then p_slides*v_s.per_slide_price else v_s.base_price end;
 if v_code<>'' then
  select * into v_c from public.moujaz_coupons where code=v_code;
  if not found or not v_c.active or (v_c.expires_at is not null and v_c.expires_at<=now()) or (v_c.max_uses is not null and v_c.used_count>=v_c.max_uses) or (v_c.service_id is not null and v_c.service_id<>p_service) then raise exception 'Coupon invalid, expired, or unavailable'; end if;
  v_discount:=least(v_base,case when v_c.discount_type='percent' then floor(v_base*v_c.amount/100.0)::integer else v_c.amount end);
 end if;
 return jsonb_build_object('base',v_base,'discount',v_discount,'total',v_base-v_discount,'code',nullif(v_code,''));
end $$;
revoke all on function public.moujaz_quote(text,integer,integer,text,text) from public;
grant execute on function public.moujaz_quote(text,integer,integer,text,text) to authenticated;

-- Replace V1 order RPC, retaining the same signature. Coupon consumption is atomic.
create or replace function public.create_moujaz_order(p_order jsonb)
returns public.orders language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_service text:=p_order->>'service'; v_pages int; v_slides int; v_delivery text:=p_order->>'delivery';
 v_price int; v_base int; v_discount int:=0; v_code text:=upper(trim(coalesce(p_order->>'coupon',''))); v_s public.moujaz_services; v_c public.moujaz_coupons; v_result public.orders;
begin
 if v_user is null then raise exception 'Sign in required'; end if;
 if jsonb_typeof(p_order) is distinct from 'object' then raise exception 'Invalid payload'; end if;
 select * into v_s from public.moujaz_services where id=v_service and enabled=true;
 if not found then raise exception 'Service unavailable'; end if;
 if coalesce(length(trim(p_order->>'title')),0) not between 1 and 250 or coalesce(length(trim(p_order->>'student')),0) not between 1 and 150
 or coalesce(length(trim(p_order->>'university')),0) not between 1 and 150 or coalesce(length(trim(p_order->>'department')),0) not between 1 and 150
 or coalesce(length(trim(p_order->>'subject')),0) not between 1 and 150 then raise exception 'Missing or invalid required fields'; end if;
 if coalesce(length(p_order->>'notes'),0)>3000 or coalesce(length(p_order->>'doctor'),0)>150 then raise exception 'Text too long'; end if;
 if coalesce(p_order->>'telegram','') !~ '^@?[A-Za-z][A-Za-z0-9_]{4,31}$' then raise exception 'Invalid Telegram username'; end if;
 if p_order->>'language' not in ('ar','en') or p_order->>'payment' not in ('zain','asia','master') then raise exception 'Invalid language/payment'; end if;
 if coalesce(p_order->>'pages','') !~ '^[0-9]{1,3}$' or coalesce(p_order->>'slides','') !~ '^[0-9]{1,3}$' then raise exception 'Invalid quantity'; end if;
 v_pages:=(p_order->>'pages')::int;v_slides:=(p_order->>'slides')::int;
 if v_pages not between 10 and 30 or v_slides not between 1 and 100 or v_delivery not in ('normal','fast') then raise exception 'Quantity out of range'; end if;
 v_base:=case v_service when 'report' then v_s.base_price+ceil(greatest(0,v_pages-10)/2.0)::integer*v_s.extra_pair_price+(case when v_delivery='fast' then v_s.fast_price else 0 end)
 when 'slides2d' then v_slides*v_s.per_slide_price else v_s.base_price end;
 if v_code<>'' then
  select * into v_c from public.moujaz_coupons where code=v_code for update;
  if not found or not v_c.active or (v_c.expires_at is not null and v_c.expires_at<=now()) or (v_c.max_uses is not null and v_c.used_count>=v_c.max_uses) or (v_c.service_id is not null and v_c.service_id<>v_service) then raise exception 'Coupon invalid, expired, or unavailable'; end if;
  v_discount:=least(v_base,case when v_c.discount_type='percent' then floor(v_base*v_c.amount/100.0)::integer else v_c.amount end);
  update public.moujaz_coupons set used_count=used_count+1 where code=v_code;
 end if;
 v_price:=v_base-v_discount;
 insert into public.orders(user_id,order_number,service,title,student_name,university,department,subject,doctor,language,pages,slides,delivery,telegram,notes,price,payment_method,status,coupon_code,discount_amount)
 values(v_user,'MZ-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),v_service,trim(p_order->>'title'),trim(p_order->>'student'),trim(p_order->>'university'),trim(p_order->>'department'),trim(p_order->>'subject'),nullif(trim(p_order->>'doctor'),''),p_order->>'language',v_pages,v_slides,v_delivery,p_order->>'telegram',p_order->>'notes',v_price,p_order->>'payment','pending',nullif(v_code,''),v_discount)
 returning * into v_result;
 return v_result;
end $$;
revoke all on function public.create_moujaz_order(jsonb) from public;
grant execute on function public.create_moujaz_order(jsonb) to authenticated;

-- Log all successful administrative payment/status updates (V1 signature preserved).
create or replace function public.admin_update_moujaz_order(p_order_id uuid,p_status text,p_payment_confirmed boolean)
returns public.orders language plpgsql security definer set search_path='' as $$
declare v_role text:=public.my_moujaz_admin_role(); v_order public.orders;
begin
 if v_role is null or v_role not in ('OWNER','ADMIN') then raise exception 'Not authorized'; end if;
 if p_status not in ('pending','working','delivered') or p_payment_confirmed is null then raise exception 'Invalid status/payment'; end if;
 if p_status in ('working','delivered') and not p_payment_confirmed then raise exception 'Payment confirmation required'; end if;
 update public.orders set status=p_status,payment_confirmed=p_payment_confirmed where id=p_order_id returning * into v_order;
 if not found then raise exception 'Order not found'; end if;
 insert into public.moujaz_audit(actor,action,target,details) values(auth.uid(),'order.update',p_order_id::text,jsonb_build_object('status',p_status,'paid',p_payment_confirmed));
 return v_order;
end $$;
revoke all on function public.admin_update_moujaz_order(uuid,text,boolean) from public;
grant execute on function public.admin_update_moujaz_order(uuid,text,boolean) to authenticated;
