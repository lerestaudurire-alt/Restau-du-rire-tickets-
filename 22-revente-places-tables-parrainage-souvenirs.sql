-- 22 - Offrir/revendre un billet, choix de place, tables de groupe, parrainage, photos souvenirs, commission vendeurs.
-- Relancable sans risque. Aucun code promo.

alter table public.orders add column if not exists transferred_to uuid, add column if not exists transferred_from uuid;

-- Verification commune : le billet appartient a (nom + numero), est confirme et pas encore utilise
create or replace function public.own_order(p_order uuid, p_phone text, p_name text)
returns orders language plpgsql security definer set search_path=public,extensions as $$
declare o orders;
begin
  select * into o from orders where id=p_order and status='confirmed' and coalesce(used,false)=false
    and phone_idx=blind(p_phone) and name ilike '%'||trim(p_name)||'%';
  if not found then raise exception 'no_ticket'; end if;
  return o;
end $$;
revoke execute on function public.own_order(uuid,text,text) from public,anon,authenticated;

-- Transfert : l'ancien billet est annule, un NOUVEAU billet (nouveau QR) est cree pour la nouvelle personne
create or replace function public.do_transfer(p_order uuid, p_new_name text, p_new_phone text)
returns uuid language plpgsql security definer set search_path=public,extensions as $$
declare nid uuid:=gen_random_uuid();
begin
  if length(trim(coalesce(p_new_name,''))) < 3 or length(coalesce(p_new_phone,'')) < 6 then raise exception 'invalid'; end if;
  update orders set status='cancelled', transferred_to=nid where id=p_order;
  insert into orders select (jsonb_populate_record(null::orders, to_jsonb(o) || jsonb_build_object(
      'id',nid,'name',trim(p_new_name),'phone',p_new_phone,'phone_enc',null,'phone_idx',null,'email',null,'email_enc',null,'payer',null,'payer_enc',null,
      'status','confirmed','used',false,'created_at',now(),'transferred_from',p_order,'transferred_to',null))).* from orders o where o.id=p_order;
  update resale_listings set status='cancelled' where order_id=p_order and status='open';
  return nid;
end $$;
revoke execute on function public.do_transfer(uuid,text,text) from public,anon,authenticated;

create or replace function public.transfer_ticket(p_order uuid, p_phone text, p_name text, p_new_name text, p_new_phone text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare o orders; nid uuid;
begin o := own_order(p_order,p_phone,p_name); nid := do_transfer(o.id,p_new_name,p_new_phone); return jsonb_build_object('ok',true,'id',nid); end $$;

-- Revente officielle : au prix d'origine uniquement (le prix ne peut pas etre modifie)
create table if not exists public.resale_listings(
  id uuid primary key default gen_random_uuid(), order_id uuid not null, event_id uuid not null,
  seller_name text not null, seller_phone_enc bytea, descr text, price jsonb,
  status text not null default 'open' check (status in ('open','sold','cancelled')), created_at timestamptz not null default now());
create unique index if not exists resale_one_open on public.resale_listings(order_id) where status='open';
alter table public.resale_listings enable row level security;
revoke all on public.resale_listings from anon, authenticated;

create or replace function public.list_resale(p_order uuid, p_phone text, p_name text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare o orders; v_start timestamptz;
begin
  o := own_order(p_order,p_phone,p_name);
  select starts_at into v_start from events where id=o.event_id;
  if v_start is not null and v_start < now() then raise exception 'over'; end if;
  insert into resale_listings(order_id,event_id,seller_name,seller_phone_enc,descr,price)
   values(o.id,o.event_id,initcap(split_part(trim(o.name),' ',1)),enc(p_phone),
     (select string_agg(i->>'name'||' × '||(i->>'qty'),', ') from jsonb_array_elements(to_jsonb(o.items)) i), to_jsonb(o.amounts));
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.resale_public(p_event uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'seller',seller_name,'descr',descr,'price',price) order by created_at),'[]')
  from resale_listings where event_id=p_event and status='open' $$;

create or replace function public.resale_contact(p_listing uuid)
returns text language sql security definer stable set search_path=public,extensions as $$
  select public.dec(seller_phone_enc) from resale_listings where id=p_listing and status='open' $$;

create or replace function public.cancel_resale(p_listing uuid, p_phone text, p_name text)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  update resale_listings l set status='cancelled' where l.id=p_listing and l.status='open'
    and exists(select 1 from orders o where o.id=l.order_id and o.phone_idx=blind(p_phone) and o.name ilike '%'||trim(p_name)||'%');
end $$;

create or replace function public.my_listings(p_phone text, p_name text)
returns jsonb language sql security definer stable set search_path=public,extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',l.id,'descr',l.descr,'event_id',l.event_id) ),'[]')
  from resale_listings l join orders o on o.id=l.order_id
  where l.status='open' and o.phone_idx=blind(p_phone) and o.name ilike '%'||trim(p_name)||'%' $$;

-- Le vendeur confirme qu'il a ete paye : le billet passe a l'acheteur (nouveau QR)
create or replace function public.complete_resale(p_listing uuid, p_phone text, p_name text, p_buyer_name text, p_buyer_phone text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare l resale_listings; o orders; nid uuid;
begin
  select * into l from resale_listings where id=p_listing and status='open'; if not found then raise exception 'closed'; end if;
  o := own_order(l.order_id,p_phone,p_name);
  nid := do_transfer(o.id,p_buyer_name,p_buyer_phone);
  update resale_listings set status='sold' where id=p_listing;
  return jsonb_build_object('ok',true);
end $$;

-- Options organisateur (plan de salle, commission) : proprietaire ou admin
create or replace function public.set_event_option(p_event uuid, p_key text, p_value numeric)
returns void language plpgsql security definer set search_path=public as $$
begin
  if p_key not in ('seat_rows','seat_cols','commission_pct') then raise exception 'key'; end if;
  if p_value < 0 or p_value > 100 then raise exception 'range'; end if;
  if my_role() <> 'admin' and not exists(select 1 from events where id=p_event and owner_id=auth.uid()) then raise exception 'denied'; end if;
  update events set modes = coalesce(modes,'{}'::jsonb) || jsonb_build_object(p_key, p_value) where id=p_event;
end $$;

-- Choix de place (apres achat confirme) : autant de places que de billets
create table if not exists public.seat_picks(
  event_id uuid not null, seat text not null, order_id uuid not null, created_at timestamptz not null default now(),
  primary key(event_id, seat));
alter table public.seat_picks enable row level security;
revoke all on public.seat_picks from anon, authenticated;

create or replace function public.seat_map(p_event uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select coalesce(jsonb_agg(seat),'[]') from seat_picks where event_id=p_event $$;

create or replace function public.pick_seat(p_event uuid, p_phone text, p_name text, p_seat text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare oid uuid; q int; have int; r int; c int; m jsonb;
begin
  select modes into m from events where id=p_event; r:=coalesce((m->>'seat_rows')::int,0); c:=coalesce((m->>'seat_cols')::int,0);
  if r=0 or c=0 or p_seat !~ '^[A-Z][0-9]{1,2}$' then raise exception 'invalid'; end if;
  if ascii(left(p_seat,1))-64 > r or substr(p_seat,2)::int > c or substr(p_seat,2)::int < 1 then raise exception 'invalid'; end if;
  select id, coalesce(total_qty,1) into oid, q from orders where event_id=p_event and status='confirmed'
    and phone_idx=blind(p_phone) and name ilike '%'||trim(p_name)||'%' order by created_at limit 1;
  if oid is null then raise exception 'no_ticket'; end if;
  select count(*) into have from seat_picks where order_id=oid;
  if have >= q then raise exception 'quota'; end if;
  insert into seat_picks(event_id,seat,order_id) values(p_event,p_seat,oid);
  return jsonb_build_object('ok',true);
exception when unique_violation then raise exception 'taken';
end $$;

create or replace function public.release_seat(p_event uuid, p_phone text, p_name text, p_seat text)
returns void language plpgsql security definer set search_path=public,extensions as $$
begin
  delete from seat_picks s where s.event_id=p_event and s.seat=p_seat and exists(select 1 from orders o where o.id=s.order_id
    and o.phone_idx=blind(p_phone) and o.name ilike '%'||trim(p_name)||'%');
end $$;

-- Tables de groupe : chacun achete son billet, la table regroupe les amis
create table if not exists public.group_tables(
  code text primary key default upper(substr(md5(random()::text),1,5)), event_id uuid not null, label text not null,
  size int not null check (size between 2 and 30), created_at timestamptz not null default now());
create table if not exists public.group_members(
  code text not null, name text not null, phone_enc bytea, phone_idx text not null, created_at timestamptz not null default now(),
  primary key(code, phone_idx));
alter table public.group_tables enable row level security; alter table public.group_members enable row level security;
revoke all on public.group_tables, public.group_members from anon, authenticated;

create or replace function public.create_table(p_event uuid, p_label text, p_size int, p_name text, p_phone text)
returns text language plpgsql security definer set search_path=public,extensions as $$
declare c text;
begin
  if length(trim(coalesce(p_label,''))) < 2 or length(p_label) > 40 or length(coalesce(p_phone,'')) < 6 or length(trim(coalesce(p_name,''))) < 2 then raise exception 'invalid'; end if;
  if (select count(*) from group_tables where event_id=p_event) >= 200 then raise exception 'limit'; end if;
  insert into group_tables(event_id,label,size) values(p_event,trim(p_label),p_size) returning code into c;
  insert into group_members(code,name,phone_enc,phone_idx) values(c,left(trim(p_name),60),enc(p_phone),blind(p_phone));
  return c;
end $$;

create or replace function public.join_table(p_code text, p_name text, p_phone text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare t group_tables; n int;
begin
  select * into t from group_tables where code=upper(trim(p_code)); if not found then raise exception 'unknown'; end if;
  select count(*) into n from group_members where code=t.code; if n >= t.size then raise exception 'full'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(coalesce(p_phone,'')) < 6 then raise exception 'invalid'; end if;
  insert into group_members(code,name,phone_enc,phone_idx) values(t.code,left(trim(p_name),60),enc(p_phone),blind(p_phone)) on conflict do nothing;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.tables_public(p_event uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code',t.code,'label',t.label,'size',t.size,
    'n',(select count(*) from group_members m where m.code=t.code),
    'names',(select coalesce(jsonb_agg(initcap(split_part(m.name,' ',1)) order by m.created_at),'[]') from group_members m where m.code=t.code)) order by t.created_at),'[]')
  from group_tables t where t.event_id=p_event $$;

-- Parrainage : +20 points pour le parrain et le filleul (les deux doivent avoir un billet confirme)
create table if not exists public.referrals(
  referee_idx text primary key, referrer_idx text not null, created_at timestamptz not null default now());
alter table public.referrals enable row level security; revoke all on public.referrals from anon, authenticated;

create or replace function public.my_referral(p_phone text, p_name text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare i text:=blind(p_phone); n int; mine boolean;
begin
  if not exists(select 1 from orders where status='confirmed' and phone_idx=i and name ilike '%'||trim(p_name)||'%') then raise exception 'no_ticket'; end if;
  select count(*) into n from referrals where referrer_idx=i; select exists(select 1 from referrals where referee_idx=i) into mine;
  return jsonb_build_object('code',upper(left(md5(i),6)),'friends',n,'bonus',20*n+case when mine then 20 else 0 end);
end $$;

create or replace function public.claim_referral(p_code text, p_phone text, p_name text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare me text:=blind(p_phone); ref text;
begin
  if not exists(select 1 from orders where status='confirmed' and phone_idx=me and name ilike '%'||trim(p_name)||'%') then raise exception 'no_ticket'; end if;
  select phone_idx into ref from orders where status='confirmed' and upper(left(md5(phone_idx),6))=upper(trim(p_code)) limit 1;
  if ref is null then raise exception 'unknown'; end if;
  if ref = me then raise exception 'self'; end if;
  insert into referrals(referee_idx,referrer_idx) values(me,ref);
  return jsonb_build_object('ok',true);
exception when unique_violation then raise exception 'already';
end $$;

-- Photos souvenirs : l'organisateur ajoute, tout le monde voit et telecharge
insert into storage.buckets(id,name,public) values('souvenirs','souvenirs',true) on conflict (id) do nothing;
drop policy if exists souv_read on storage.objects; drop policy if exists souv_write on storage.objects; drop policy if exists souv_del on storage.objects;
create policy souv_read on storage.objects for select to anon,authenticated using (bucket_id='souvenirs');
create policy souv_write on storage.objects for insert to authenticated with check (bucket_id='souvenirs' and (storage.foldername(name))[1]=auth.uid()::text);
create policy souv_del on storage.objects for delete to authenticated using (bucket_id='souvenirs' and (storage.foldername(name))[1]=auth.uid()::text);

create table if not exists public.event_photos(
  id uuid primary key default gen_random_uuid(), event_id uuid not null, path text not null, created_at timestamptz not null default now());
alter table public.event_photos enable row level security; revoke all on public.event_photos from anon, authenticated;

create or replace function public.add_photo(p_event uuid, p_path text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if my_role() <> 'admin' and not exists(select 1 from events where id=p_event and owner_id=auth.uid()) then raise exception 'denied'; end if;
  if p_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$' then raise exception 'invalid'; end if;
  if (select count(*) from event_photos where event_id=p_event) >= 200 then raise exception 'limit'; end if;
  insert into event_photos(event_id,path) values(p_event,p_path);
end $$;
create or replace function public.photos_public(p_event uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'path',path) order by created_at desc),'[]') from event_photos where event_id=p_event $$;
create or replace function public.delete_photo(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if my_role() <> 'admin' and not exists(select 1 from event_photos p join events e on e.id=p.event_id where p.id=p_id and e.owner_id=auth.uid()) then raise exception 'denied'; end if;
  delete from event_photos where id=p_id;
end $$;

grant execute on function public.transfer_ticket(uuid,text,text,text,text), public.list_resale(uuid,text,text), public.resale_public(uuid),
  public.resale_contact(uuid), public.cancel_resale(uuid,text,text), public.my_listings(text,text), public.complete_resale(uuid,text,text,text,text),
  public.set_event_option(uuid,text,numeric), public.seat_map(uuid), public.pick_seat(uuid,text,text,text), public.release_seat(uuid,text,text,text),
  public.create_table(uuid,text,int,text,text), public.join_table(text,text,text), public.tables_public(uuid),
  public.my_referral(text,text), public.claim_referral(text,text,text),
  public.add_photo(uuid,text), public.photos_public(uuid), public.delete_photo(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
