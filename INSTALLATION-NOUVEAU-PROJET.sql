-- =====================================================================================
-- LE RESTAU DU RIRE TICKETS - INSTALLATION COMPLETE D'UN NOUVEAU PROJET SUPABASE
-- A executer UNE fois, dans Supabase > SQL Editor, sur un projet VIDE.
-- Si l'editeur refuse un script aussi long (telephone), executez-le PARTIE par PARTIE :
-- chaque partie commence par une ligne "PARTIE n".
-- =====================================================================================
set check_function_bodies = off;

-- ================================= PARTIE 1 : base, roles, tables =====================
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.app_roles(user_id uuid primary key, role text not null check (role in ('admin','staff')));
alter table public.app_roles enable row level security;
revoke all on public.app_roles from anon, authenticated;

create or replace function public.my_role() returns text language sql stable security definer set search_path=public as
$$ select coalesce((select role from public.app_roles where user_id=auth.uid()), 'none') $$;
create or replace function public.is_admin() returns boolean language plpgsql security definer set search_path=public as
$$ begin return coalesce(public.my_role()='admin',false); exception when others then return false; end $$;
grant execute on function public.my_role(), public.is_admin() to anon, authenticated;

create table if not exists public.reservations(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  name text, phone text, email text,
  pays text, province text, ville text, commune text, quartier text, avenue text, loc text, note text,
  standard int not null default 0, vip int not null default 0, vvip int not null default 0,
  sponsor int not null default 0, grand_sponsor int not null default 0,
  total int default 0, fc numeric default 0, usd numeric default 0,
  payer text, rec text, proof_path text, seller text,
  status text default 'pending', used boolean default false,
  phone_enc bytea, email_enc bytea, payer_enc bytea, code_enc bytea, phone_idx text,
  pay_ref text, pay_provider text, hold boolean not null default false, expires_at timestamptz
);
create table if not exists public.waitlist(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  name text, phone text, category text, phone_enc bytea, phone_idx text
);
create table if not exists public.orders(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  event_id uuid, kind text, name text, phone text, email text, payer text, rec text,
  address jsonb, items jsonb, total_qty int, amounts jsonb, seller text, proof_path text,
  status text default 'pending', used boolean default false,
  phone_enc bytea, email_enc bytea, payer_enc bytea, phone_idx text,
  pay_ref text, pay_provider text, hold boolean not null default false, expires_at timestamptz
);
alter table public.reservations enable row level security;
alter table public.waitlist enable row level security;
drop policy if exists res_insert on public.reservations; drop policy if exists res_admin on public.reservations;
drop policy if exists wl_insert on public.waitlist; drop policy if exists wl_admin on public.waitlist;
create policy res_insert on public.reservations for insert to anon,authenticated with check (coalesce(status,'pending')='pending' and coalesce(used,false)=false);
create policy res_admin on public.reservations for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy wl_insert on public.waitlist for insert to anon,authenticated with check (true);
create policy wl_admin on public.waitlist for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant insert on public.reservations to anon; grant insert on public.waitlist to anon;
grant select,insert,update,delete on public.reservations to authenticated;
grant select,insert,update,delete on public.waitlist to authenticated;

-- ================================= PARTIE 2 : evenements, droits, stockage ============
create table if not exists public.events(id uuid primary key default gen_random_uuid());
alter table public.events add column if not exists owner_id uuid, add column if not exists title text, add column if not exists category text,
  add column if not exists country text, add column if not exists city text, add column if not exists venue text, add column if not exists starts_at timestamptz,
  add column if not exists description text, add column if not exists ticket_info text, add column if not exists poster_path text,
  add column if not exists tickets jsonb, add column if not exists pay_numbers jsonb, add column if not exists whatsapp text, add column if not exists pay_link text,
  add column if not exists modes jsonb, add column if not exists status text default 'pending', add column if not exists share_token text,
  add column if not exists created_at timestamptz default now(), add column if not exists dates jsonb;
alter table public.events alter column status set default 'pending';
alter table public.events alter column share_token set default encode(extensions.gen_random_bytes(12),'hex');
update public.events set share_token=encode(extensions.gen_random_bytes(12),'hex') where share_token is null;

alter table public.events enable row level security;
drop policy if exists ev_select on public.events; drop policy if exists ev_insert on public.events;
drop policy if exists ev_update on public.events; drop policy if exists ev_delete on public.events;
create policy ev_select on public.events for select to anon,authenticated using (status='published' or owner_id=auth.uid() or public.is_admin());
create policy ev_insert on public.events for insert to authenticated with check (owner_id=auth.uid() and coalesce(status,'pending')='pending');
create policy ev_update on public.events for update to authenticated using (public.is_admin() or (owner_id=auth.uid() and status='pending'))
  with check (public.is_admin() or (owner_id=auth.uid() and status='pending'));
create policy ev_delete on public.events for delete to authenticated using (public.is_admin() or (owner_id=auth.uid() and status='pending'));

alter table public.orders enable row level security;
drop policy if exists ord_insert on public.orders; drop policy if exists ord_select on public.orders; drop policy if exists ord_update on public.orders;
create policy ord_insert on public.orders for insert to anon,authenticated with check (coalesce(status,'pending')='pending' and coalesce(used,false)=false);
create policy ord_select on public.orders for select to authenticated using (public.is_admin() or exists(select 1 from public.events e where e.id=event_id and e.owner_id=auth.uid()));
create policy ord_update on public.orders for update to authenticated using (public.is_admin() or exists(select 1 from public.events e where e.id=event_id and e.owner_id=auth.uid()))
  with check (public.is_admin() or exists(select 1 from public.events e where e.id=event_id and e.owner_id=auth.uid()));

grant select on public.events to anon; grant select,insert,update,delete on public.events to authenticated;
grant insert on public.orders to anon; grant select,insert,update on public.orders to authenticated;

-- Stockage : affiches (public) et preuves de paiement (privé)
insert into storage.buckets(id,name,public) values('affiches','affiches',true) on conflict (id) do nothing;
insert into storage.buckets(id,name,public) values('preuves','preuves',false) on conflict (id) do nothing;
drop policy if exists aff_ins on storage.objects; drop policy if exists aff_sel on storage.objects;
drop policy if exists prv_ins on storage.objects; drop policy if exists prv_sel on storage.objects;
create policy aff_ins on storage.objects for insert to authenticated with check (bucket_id='affiches' and (storage.foldername(name))[1]=auth.uid()::text);
create policy aff_sel on storage.objects for select to anon,authenticated using (bucket_id='affiches');
create policy prv_ins on storage.objects for insert to anon,authenticated with check (bucket_id='preuves');
create policy prv_sel on storage.objects for select to authenticated using (bucket_id='preuves' and (public.is_admin() or exists(
  select 1 from public.orders o join public.events e on e.id=o.event_id where o.id::text=(storage.foldername(name))[2] and e.owner_id=auth.uid())));
grant execute on function public.is_admin() to anon, authenticated;

-- Verification : doit afficher vos administrateurs
select u.email, r.role from public.app_roles r join auth.users u on u.id=r.user_id;

-- ================================= PARTIE 3 : chiffrement AES-256 et fonctions admin ===
-- Le Restau du Rire — migration v2 (à exécuter dans Supabase > SQL Editor). Idempotente.
-- Chiffrement AES-256 (pgcrypto) des numéros, e-mails et codes de billets ; tout est déchiffré
-- uniquement par des fonctions réservées à l'admin / l'organisateur.
set check_function_bodies=off;
create extension if not exists pgcrypto with schema extensions;
create table if not exists public.app_secrets(k text primary key, v text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;
insert into public.app_secrets values('aes_key',encode(extensions.gen_random_bytes(32),'hex')) on conflict do nothing;
insert into public.app_secrets values('webhook_secret',encode(extensions.gen_random_bytes(24),'hex')) on conflict do nothing;

create or replace function public.enc(t text) returns bytea language sql security definer set search_path=public,extensions as
$$ select case when t is null or t='' then null else pgp_sym_encrypt(t,(select v from app_secrets where k='aes_key'),'cipher-algo=aes256,compress-algo=0') end $$;
create or replace function public.dec(b bytea) returns text language sql security definer set search_path=public,extensions as
$$ select case when b is null then null else pgp_sym_decrypt(b,(select v from app_secrets where k='aes_key')) end $$;
create or replace function public.blind(t text) returns text language sql security definer set search_path=public,extensions as
$$ select encode(hmac(right(regexp_replace(coalesce(t,''),'\D','','g'),9),(select v from app_secrets where k='aes_key'),'sha256'),'hex') $$;
revoke execute on function public.enc(text),public.dec(bytea),public.blind(text) from public,anon,authenticated;
grant execute on function public.enc(text),public.dec(bytea),public.blind(text) to service_role;

-- Compatibilité : crée les colonnes de base si ta table n'a pas exactement le schéma attendu
create table if not exists public.orders(id uuid primary key default gen_random_uuid());
alter table public.orders add column if not exists event_id uuid, add column if not exists kind text, add column if not exists name text,
  add column if not exists phone text, add column if not exists email text, add column if not exists payer text, add column if not exists rec text,
  add column if not exists address jsonb, add column if not exists items jsonb, add column if not exists total_qty int, add column if not exists amounts jsonb,
  add column if not exists seller text, add column if not exists proof_path text, add column if not exists status text default 'pending',
  add column if not exists used boolean default false, add column if not exists created_at timestamptz default now();
alter table public.waitlist add column if not exists phone text, add column if not exists name text, add column if not exists category text,
  add column if not exists created_at timestamptz default now();

-- Colonnes chiffrées + lien de paiement automatique
alter table public.reservations add column if not exists phone_enc bytea, add column if not exists email_enc bytea,
  add column if not exists payer_enc bytea, add column if not exists code_enc bytea, add column if not exists phone_idx text;
alter table public.orders add column if not exists phone_enc bytea, add column if not exists email_enc bytea,
  add column if not exists payer_enc bytea, add column if not exists phone_idx text;
alter table public.waitlist add column if not exists phone_enc bytea, add column if not exists phone_idx text;
alter table public.events add column if not exists pay_link text, add column if not exists ticket_info text;
alter table public.orders drop constraint if exists orders_kind_check;
drop table if exists public.promos cascade;  -- codes promo supprimés

-- Trigger : chiffre puis masque les valeurs en clair
create or replace function public.enc_row() returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare j jsonb:=to_jsonb(NEW); u jsonb:='{}'; k text; c text;
begin
  if j->>'phone' is not null and j->>'phone' not like '•%' then
    if TG_TABLE_NAME='reservations' and TG_OP='INSERT' and
       (select count(*) from reservations where phone_idx=blind(j->>'phone') and created_at>now()-interval '1 hour')>=8
    then raise exception 'Trop de demandes, réessayez plus tard'; end if;
    u:=u||jsonb_build_object('phone_enc','\x'||encode(enc(j->>'phone'),'hex'),'phone_idx',blind(j->>'phone'),
         'phone','••••'||right(regexp_replace(j->>'phone','\D','','g'),2));
  end if;
  foreach k in array array['email','payer'] loop
    c:=j->>k; if c is not null and c<>'' and c not like '•%' then
      u:=u||jsonb_build_object(k||'_enc','\x'||encode(enc(c),'hex'),k,'••••'); end if; end loop;
  if j->>'ticket_code' is not null and j->>'ticket_code' not like '•%' then
    u:=u||jsonb_build_object('code_enc','\x'||encode(enc(j->>'ticket_code'),'hex'),'ticket_code','••••'); end if;
  NEW:=jsonb_populate_record(NEW,u); return NEW; end $$;
do $$ declare t text; begin foreach t in array array['reservations','orders','waitlist'] loop
  execute format('drop trigger if exists trg_enc on public.%I',t);
  execute format('create trigger trg_enc before insert or update on public.%I for each row execute function public.enc_row()',t);
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name='phone') then
    execute format('update public.%I set phone=phone',t); end if;
end loop; end $$;

-- Réindexe les numéros existants (index sur les 9 derniers chiffres : 0812… et 243812… se retrouvent)
update public.reservations set phone_idx=blind(public.dec(phone_enc)) where phone_enc is not null;
update public.orders set phone_idx=blind(public.dec(phone_enc)) where phone_enc is not null;
update public.waitlist set phone_idx=blind(public.dec(phone_enc)) where phone_enc is not null;

-- Lectures déchiffrées (admin / organisateur / client avec nom + numéro)
drop function if exists public.admin_rows(); drop function if exists public.admin_waitlist(); drop function if exists public.find_ticket(text,text);
drop function if exists public.find_order(text,text); drop function if exists public.org_orders(uuid); drop function if exists public.staff_check(text);
drop function if exists public.staff_list();
create or replace function public.admin_rows() returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(to_jsonb(r)-'phone_enc'-'email_enc'-'payer_enc'-'code_enc'-'phone_idx'||jsonb_build_object('phone',public.dec(phone_enc),'email',public.dec(email_enc),'payer',public.dec(payer_enc),'ticket_code','LRR-'||upper(left(id::text,8))) order by created_at desc) from reservations r),'[]'); end $$;
create or replace function public.admin_waitlist() returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(to_jsonb(w)-'phone_enc'-'phone_idx'||jsonb_build_object('phone',public.dec(phone_enc)) order by created_at desc) from waitlist w),'[]'); end $$;
create or replace function public.find_ticket(p_phone text,p_name text) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(r)-'phone_enc'-'email_enc'-'payer_enc'-'code_enc'-'phone_idx'-'phone'-'email'-'payer'||jsonb_build_object('code','LRR-'||upper(left(id::text,8)))),'[]')
 from reservations r where status='confirmed' and phone_idx=blind(p_phone) and name ilike '%'||trim(p_name)||'%' $$;
create or replace function public.find_order(p_phone text,p_name text) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'used',used,'code','EV-'||upper(left(id::text,8)),
  'desc',(select string_agg(i->>'name'||' × '||(i->>'qty'),', ') from jsonb_array_elements(to_jsonb(items)) i))),'[]')
 from orders where status='confirmed' and phone_idx=blind(p_phone) and name ilike '%'||trim(p_name)||'%' $$;
create or replace function public.org_orders(p_event uuid) returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' and not exists(select 1 from events where id=p_event and owner_id=auth.uid()) then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(to_jsonb(o)-'phone_enc'-'email_enc'-'payer_enc'-'phone_idx'||jsonb_build_object('phone',public.dec(phone_enc),'email',public.dec(email_enc),'payer',public.dec(payer_enc)) order by created_at desc) from orders o where event_id=p_event),'[]'); end $$;
create or replace function public.staff_check(p_code text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r reservations; begin if my_role() not in('admin','staff') then raise exception 'denied'; end if;
 select * into r from reservations where id::text=lower(trim(p_code)) or 'LRR-'||upper(left(id::text,8))=upper(regexp_replace(p_code,'\s','','g')) limit 1;
 if not found then return jsonb_build_object('found',false); end if;
 return jsonb_build_object('found',true)||to_jsonb(r)-'phone_enc'-'email_enc'-'payer_enc'-'code_enc'-'phone_idx'-'phone'-'email'-'payer'; end $$;
create or replace function public.staff_list() returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role() not in('admin','staff') then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'code','LRR-'||upper(left(id::text,8)),'name',name,'used',used,'standard',standard,'vip',vip,'vvip',vvip,'sponsor',sponsor,'grand_sponsor',grand_sponsor)) from reservations where status='confirmed'),'[]'); end $$;

-- Pilotage plateforme (admin uniquement)
create or replace function public.admin_overview() returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('title',t.title,'country',t.country,'status',t.status,'confirmed',t.c,'pending',t.p,'fc',t.fc,'usd',t.usd))
  from (select e.title,e.country,e.status,
   coalesce(sum(o.total_qty) filter(where o.status='confirmed'),0) c, coalesce(sum(o.total_qty) filter(where o.status='pending'),0) p,
   coalesce(sum((o.amounts->>'FC')::numeric) filter(where o.status='confirmed'),0) fc, coalesce(sum((o.amounts->>'USD')::numeric) filter(where o.status='confirmed'),0) usd
   from events e left join orders o on o.event_id=e.id group by e.id) t),'[]'); end $$;

-- Journal d'audit des décisions admin
create table if not exists public.admin_audit(id bigserial primary key,at timestamptz default now(),who uuid,event_id uuid,old_status text,new_status text);
alter table public.admin_audit enable row level security; revoke all on public.admin_audit from anon,authenticated;
create or replace function public.audit_ev() returns trigger language plpgsql security definer set search_path=public as $$
begin if NEW.status is distinct from OLD.status then insert into admin_audit(who,event_id,old_status,new_status) values(auth.uid(),NEW.id,OLD.status,NEW.status); end if; return NEW; end $$;
drop trigger if exists trg_audit on public.events; create trigger trg_audit after update on public.events for each row execute function public.audit_ev();

-- Achat automatique : à appeler depuis le webhook de votre passerelle (Edge Function)
-- Secret : select v from app_secrets where k='webhook_secret';
create or replace function public.auto_confirm_order(p_order uuid,p_secret text) returns boolean language plpgsql security definer set search_path=public as $$
begin if p_secret is distinct from (select v from app_secrets where k='webhook_secret') then return false; end if;
 update orders set status='confirmed' where id=p_order and kind='online'; return found; end $$;

grant execute on function public.find_ticket(text,text),public.find_order(text,text),public.auto_confirm_order(uuid,text) to anon,authenticated;
grant execute on function public.admin_rows(),public.admin_waitlist(),public.org_orders(uuid),public.staff_check(text),public.staff_list(),public.admin_overview() to authenticated;

-- ================================= PARTIE 4 : paiement en ligne et reservations ========
-- À exécuter une fois dans Supabase > SQL Editor (réexécutable sans risque)

-- ===== Paiement SimplyPaye =====
alter table public.reservations add column if not exists pay_ref text;
alter table public.reservations add column if not exists pay_provider text;
alter table public.orders       add column if not exists pay_ref text;
alter table public.orders       add column if not exists pay_provider text;

-- ===== Réservations "payer plus tard" =====
alter table public.reservations add column if not exists hold boolean not null default false;
alter table public.reservations add column if not exists expires_at timestamptz;
alter table public.orders       add column if not exists hold boolean not null default false;
alter table public.orders       add column if not exists expires_at timestamptz;

-- Commandes gratuites / à payer plus tard : pas de capture, pas de payeur
alter table public.reservations alter column proof_path drop not null;
alter table public.orders       alter column proof_path drop not null;
alter table public.reservations alter column payer drop not null;
alter table public.reservations alter column rec   drop not null;
alter table public.orders       alter column payer drop not null;
alter table public.orders       alter column rec   drop not null;

create index if not exists reservations_pay_idx  on public.reservations (pay_provider, status, created_at);
create index if not exists orders_pay_idx        on public.orders       (pay_provider, status, created_at);
create index if not exists reservations_hold_idx on public.reservations (hold, status, expires_at);
create index if not exists orders_hold_idx       on public.orders       (hold, status, expires_at);

-- Libère les places des réservations non payées à temps (appelée par le site à chaque ouverture)
create or replace function public.expire_holds()
returns void language sql security definer set search_path = public as $$
  update public.orders       set status = 'cancelled' where hold and status = 'pending' and pay_ref is null and expires_at < now();
  update public.reservations set status = 'cancelled' where hold and status = 'pending' and pay_ref is null and expires_at < now();
$$;
grant execute on function public.expire_holds() to anon, authenticated;

-- (Optionnel) nettoyage automatique toutes les 10 min si l'extension pg_cron est activée :
-- select cron.schedule('expire-holds', '*/10 * * * *', 'select public.expire_holds()');

-- ================================= PARTIE 5 : stocks, scan, suivi, suppression ========
create or replace function public.stock() returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'total', coalesce(sum(standard+vip+vvip+sponsor+grand_sponsor),0),
    'standard', coalesce(sum(standard),0), 'vip', coalesce(sum(vip),0), 'vvip', coalesce(sum(vvip),0),
    'sponsor', coalesce(sum(sponsor),0), 'grand_sponsor', coalesce(sum(grand_sponsor),0))
  from public.reservations where status<>'cancelled' $$;
create or replace function public.billets_pris() returns int language sql stable security definer set search_path=public as $$
  select coalesce(sum(standard),0)::int from public.reservations where status<>'cancelled' $$;
create or replace function public.event_stock(p_event uuid) returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_object_agg(k,v),'{}'::jsonb) from (
    select i->>'id' as k, sum((i->>'qty')::int) as v
    from public.orders o, jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i
    where o.event_id=p_event and o.status<>'cancelled' group by 1) t $$;
grant execute on function public.stock(), public.billets_pris(), public.event_stock(uuid) to anon, authenticated;

create or replace function public.staff_enter(p_id uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
  if my_role() not in ('admin','staff') then raise exception 'denied'; end if;
  update public.reservations set used=true where id=p_id;
  if not found then update public.orders set used=true where id=p_id; end if;
  return true;
end $$;
grant execute on function public.staff_enter(uuid) to authenticated;

-- Scan : cherche d'abord dans les reservations de l'edition, puis dans les commandes d'evenements
drop function if exists public.staff_check(text);
create or replace function public.staff_check(p_code text) returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.reservations; o public.orders;
begin
  if my_role() not in ('admin','staff') then raise exception 'denied'; end if;
  select * into r from public.reservations
    where id::text=lower(trim(p_code)) or 'LRR-'||upper(left(id::text,8))=upper(regexp_replace(p_code,'\s','','g')) limit 1;
  if found then
    return jsonb_build_object('found',true)||to_jsonb(r)-'phone_enc'-'email_enc'-'payer_enc'-'code_enc'-'phone_idx'-'phone'-'email'-'payer';
  end if;
  select * into o from public.orders
    where id::text=lower(trim(p_code)) or 'EV-'||upper(left(id::text,8))=upper(regexp_replace(p_code,'\s','','g')) limit 1;
  if found then
    return jsonb_build_object('found',true,'id',o.id,'name',o.name,'status',o.status,'used',coalesce(o.used,false),
      'items',coalesce(o.items,'[]'::jsonb),
      'desc',(select string_agg(i->>'name'||' x '||(i->>'qty'),', ') from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i));
  end if;
  return jsonb_build_object('found',false);
end $$;
grant execute on function public.staff_check(text) to authenticated;

-- Page de suivi de l'organisateur (aucune donnee personnelle)
drop function if exists public.event_progress(text);
create or replace function public.event_progress(p_token text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce((
    select jsonb_build_object(
      'found', true, 'title', e.title, 'venue', e.venue, 'city', e.city,
      'starts_at', e.starts_at, 'dates', e.dates, 'tickets', coalesce(e.tickets,'[]'::jsonb),
      'orders', coalesce((
        select jsonb_agg(jsonb_build_object(
          'status', o.status, 'kind', o.kind, 'used', coalesce(o.used,false),
          'items', coalesce(o.items,'[]'::jsonb),
          'qty', coalesce(o.total_qty,(select coalesce(sum((i->>'qty')::int),0) from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i)),
          'amounts', coalesce(o.amounts,'{}'::jsonb), 'day', to_char(o.created_at,'YYYY-MM-DD')))
        from public.orders o where o.event_id=e.id and o.status in ('pending','confirmed')), '[]'::jsonb))
    from public.events e where coalesce(p_token,'')<>'' and e.share_token=p_token limit 1
  ), jsonb_build_object('found', false)) $$;
grant execute on function public.event_progress(text) to anon, authenticated;

-- Suppression d'un evenement (admin : tout ; organisateur : sans billets confirmes)
drop function if exists public.delete_event(uuid);
create or replace function public.delete_event(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_owner uuid;
begin
  select owner_id into v_owner from public.events where id = p_id;
  if not found then raise exception 'Evenement introuvable'; end if;
  if not public.is_admin() then
    if v_owner is distinct from auth.uid() then raise exception 'Acces refuse'; end if;
    if exists (select 1 from public.orders where event_id = p_id and status = 'confirmed') then
      raise exception 'Billets deja confirmes : contactez ladministrateur';
    end if;
  end if;
  delete from public.orders where event_id = p_id;
  delete from public.events where id = p_id;
  return true;
end $$;
revoke all on function public.delete_event(uuid) from public, anon;
grant execute on function public.delete_event(uuid) to authenticated;

-- ================================= PARTIE 6 : compte administrateur ====================
-- 1) Creez d'abord votre compte sur le site (Compte > Creer un compte).
-- 2) Remplacez les adresses ci-dessous par la votre, puis executez cette partie.
insert into public.app_roles(user_id, role)
select id, 'admin' from auth.users where email in ('lerestaudurire@gmail.com','contact.mraugustin243@gmail.com')
on conflict (user_id) do update set role='admin';

notify pgrst, 'reload schema';


-- ########## 10-diagnostic.sql ##########
-- 10 - Diagnostic du systeme (bouton "Lancer le diagnostic" du Dashboard). Relancable sans risque.
create or replace function public.system_check() returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb:='[]'; t text; f text;
begin
  if not public.is_admin() then raise exception 'denied'; end if;
  -- types des colonnes JSON
  for t,f in select * from (values ('events','tickets'),('events','pay_numbers'),('events','modes'),('orders','items')) v(a,b) loop
    r:=r||jsonb_build_object('n','Colonne '||t||'.'||f||' en jsonb','ok',coalesce((select data_type='jsonb' from information_schema.columns where table_schema='public' and table_name=t and column_name=f),false),
      'h','Lancez MISE-A-JOUR-SEULEMENT.sql (partie 05).');
  end loop;
  -- colonnes indispensables
  for t,f in select * from (values ('events','ticket_info'),('events','pay_link'),('events','dates'),('events','ends_at'),('events','share_token'),('events','owner_id'),
    ('orders','phone_enc'),('orders','phone_idx'),('orders','pay_ref'),('orders','hold'),('orders','expires_at'),
    ('reservations','phone_enc'),('reservations','phone_idx'),('reservations','pay_ref'),('reservations','hold'),('reservations','expires_at')) v(a,b) loop
    r:=r||jsonb_build_object('n','Colonne '||t||'.'||f,'ok',exists(select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=f),
      'h','Lancez SQL-COMPLET-A-JOUR.sql (ou MISE-A-JOUR-SEULEMENT.sql).');
  end loop;
  -- fonctions
  foreach f in array array['my_role','is_admin','admin_rows','admin_waitlist','find_ticket','find_order','org_orders','staff_check','staff_list','admin_overview','event_progress','delete_event','expire_holds','blind','enc','dec'] loop
    r:=r||jsonb_build_object('n','Fonction '||f,'ok',exists(select 1 from pg_proc where proname=f and pronamespace='public'::regnamespace),'h','Lancez SQL-COMPLET-A-JOUR.sql.');
  end loop;
  -- droits d'acces
  for t,f in select * from (values ('events','ev_insert'),('events','ev_select'),('events','ev_update'),('orders','ord_insert')) v(a,b) loop
    r:=r||jsonb_build_object('n','Droit '||f,'ok',exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname=f),'h','Lancez 03-database-policies.sql (inclus dans SQL-COMPLET-A-JOUR.sql).');
  end loop;
  -- administrateurs, cle de chiffrement, stockage
  r:=r||jsonb_build_object('n','Au moins un administrateur','ok',exists(select 1 from public.app_roles where role='admin'),'h','Lancez 04-admin-fix.sql.');
  r:=r||jsonb_build_object('n','Cle de chiffrement AES-256','ok',exists(select 1 from public.app_secrets where k='aes_key'),'h','Lancez 01-database.sql.');
  r:=r||jsonb_build_object('n','Stockage des affiches et preuves','ok',(select count(*) from storage.buckets where id in ('affiches','preuves'))=2,'h','Lancez 03-database-policies.sql.');
  return r;
end $$;
revoke all on function public.system_check() from public, anon;
grant execute on function public.system_check() to authenticated;
notify pgrst, 'reload schema';


-- ########## 11 : statuts des commandes (corrige "orders_status_check" : le statut confirmed etait refuse) ##########
-- 11 - Corrige l'erreur "orders_status_check" : la base refusait le statut "confirmed" pour les commandes.
-- Relancable sans risque (les anciennes lignes ne sont pas modifiées).
do $$ declare t text; c record; begin
  foreach t in array array['orders','reservations'] loop
    for c in select conname from pg_constraint
             where conrelid=('public.'||t)::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%status%' loop
      execute format('alter table public.%I drop constraint %I', t, c.conname);
    end loop;
    execute format('alter table public.%I add constraint %I check (status in (''pending'',''confirmed'',''cancelled'',''rejected'',''expired'',''failed'',''refunded'')) not valid', t, t||'_status_check');
  end loop;
end $$;
notify pgrst, 'reload schema';

-- ########## 12 : stock = commandes en attente + confirmees (les billets diminuent des l'enregistrement) ##########
-- Les billets diminuent des qu'une commande est enregistree (en attente ou confirmee), pas seulement apres confirmation.
drop function if exists public.stock();
create or replace function public.stock() returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'total', coalesce(sum(standard+vip+vvip+sponsor+grand_sponsor),0),
    'standard', coalesce(sum(standard),0), 'vip', coalesce(sum(vip),0), 'vvip', coalesce(sum(vvip),0),
    'sponsor', coalesce(sum(sponsor),0), 'grand_sponsor', coalesce(sum(grand_sponsor),0))
  from public.reservations where status<>'cancelled' $$;
grant execute on function public.stock() to anon, authenticated;
notify pgrst, 'reload schema';


-- ########## 13 : annonces ##########
-- 11 - Annonces & actualites (page d'accueil). Relancable sans risque.
create table if not exists public.announcements(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  title text not null, body text, image_url text, link_url text,
  active boolean not null default true, sort int default 0);
alter table public.announcements enable row level security;
drop policy if exists ann_read on public.announcements;
drop policy if exists ann_admin on public.announcements;
create policy ann_read on public.announcements for select to anon, authenticated using (active or public.is_admin());
create policy ann_admin on public.announcements for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.announcements to anon;
grant select, insert, update, delete on public.announcements to authenticated;
notify pgrst, 'reload schema';

-- ########## 14 : organisateurs ##########
-- 12 - Organisateurs : reversements, modeles d'evenement libres, adresse facultative. Relancable sans risque.
-- Les modeles d'evenement (gala d'humour, theatre...) : on retire toute contrainte limitant la categorie.
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid='public.events'::regclass and contype='c'
           and pg_get_constraintdef(oid) ilike '%category%' loop
    execute format('alter table public.events drop constraint %I', c.conname);
  end loop; end $$;
-- L'adresse n'est plus obligatoire (sauf reservation)
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='orders' and column_name='address') then
    alter table public.orders alter column address drop not null; end if; end $$;
-- Reversements aux organisateurs (suivi des sommes envoyees sur leur Mobile Money)
create table if not exists public.payouts(
  id uuid primary key default gen_random_uuid(), created_at timestamptz default now(),
  event_id uuid not null, amount numeric not null check (amount > 0), currency text not null default 'CDF', note text);
alter table public.payouts enable row level security;
drop policy if exists payouts_admin on public.payouts; drop policy if exists payouts_owner on public.payouts;
create policy payouts_admin on public.payouts for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy payouts_owner on public.payouts for select to authenticated
  using (exists (select 1 from public.events e where e.id = payouts.event_id and e.owner_id = auth.uid()));
grant select on public.payouts to authenticated; grant insert, update, delete on public.payouts to authenticated;
notify pgrst, 'reload schema';

-- ########## 15 : images des annonces ##########
-- 13 - Plusieurs images par annonce. Relancable sans risque.
alter table public.announcements add column if not exists images jsonb default '[]'::jsonb;
notify pgrst, 'reload schema';

-- ########## 16 : stock limite (Sold out) ##########
-- 14 - Stock limite : impossible de vendre plus de billets que le total programme (en ligne + especes + reservations).
-- Relancable sans risque.
create or replace function public.orders_stock_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ev jsonb; t jsonb; it jsonb; lim int; sold int; want int;
begin
  if NEW.event_id is null or coalesce(NEW.status,'pending') in ('cancelled','rejected','expired','failed') then return NEW; end if;
  perform pg_advisory_xact_lock(hashtext(NEW.event_id::text));
  select tickets into ev from public.events where id = NEW.event_id;
  if ev is null or jsonb_typeof(ev) <> 'array' then return NEW; end if;
  for it in select * from jsonb_array_elements(coalesce(NEW.items,'[]'::jsonb)) loop
    t := null;
    select x into t from jsonb_array_elements(ev) x where x->>'id' = it->>'id' limit 1;
    lim := coalesce(nullif(t->>'stock','')::numeric, 0)::int;
    if t is not null and lim > 0 then
      select coalesce(sum((i->>'qty')::numeric),0)::int into sold
        from public.orders o, jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i
        where o.event_id = NEW.event_id and o.status not in ('cancelled','rejected','expired','failed') and i->>'id' = it->>'id';
      want := coalesce((it->>'qty')::numeric, 0)::int;
      if sold + want > lim then
        raise exception 'SOLD_OUT: % (reste %)', coalesce(t->>'name',''), greatest(lim - sold, 0);
      end if;
    end if;
  end loop;
  return NEW;
end $$;
drop trigger if exists orders_stock_guard on public.orders;
create trigger orders_stock_guard before insert on public.orders for each row execute function public.orders_stock_guard();
notify pgrst, 'reload schema';
