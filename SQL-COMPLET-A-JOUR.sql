-- ===== LE RESTAU DU RIRE : SQL COMPLET A JOUR (00 a 06) =====
-- A executer dans Supabase > SQL Editor. Chaque partie peut etre relancee sans risque.

-- ########## 00-validation-et-admin.sql ##########
-- ============================================================================
-- 00 - VALIDATION DES EVENEMENTS + ACCES ADMINISTRATEUR (a lancer en premier)
-- Partie A : seuls les comptes administrateurs (table app_roles) ouvrent le Dashboard.
-- Partie B : un organisateur connecte peut envoyer son evenement (en attente),
--            seul l'admin peut le publier ou le refuser.
-- Relancable sans risque.
-- ============================================================================

-- ------------------------------ PARTIE A : ADMINS ------------------------------
-- Donne l'accès administrateur à un compte (sans écraser l'ancienne logique). Idempotent.
-- Comptes administrateurs : lerestaudurire@gmail.com et contact.mraugustin243@gmail.com
set check_function_bodies=off;

create table if not exists public.app_roles(user_id uuid primary key, role text not null check (role in ('admin','staff')));
alter table public.app_roles enable row level security;
revoke all on public.app_roles from anon, authenticated;

-- 1) Sauvegarde l'ancienne fonction (comptes écrits en dur) sous le nom my_role_legacy
do $$ declare src text; begin
  if not exists (select 1 from pg_proc where proname='my_role_legacy') then
    select prosrc into src from pg_proc where proname='my_role' and pronamespace='public'::regnamespace limit 1;
    execute 'create function public.my_role_legacy() returns text language sql stable security definer set search_path=public as $f$'||src||'$f$';
  end if;
end $$;

-- 2) my_role lit d'abord la table app_roles, sinon l'ancienne logique
create or replace function public.my_role() returns text language sql stable security definer set search_path=public as
$$ select coalesce((select role from public.app_roles where user_id=auth.uid()), public.my_role_legacy(), 'none') $$;
grant execute on function public.my_role(), public.my_role_legacy() to anon, authenticated;

-- 3) Le compte administrateur
insert into public.app_roles(user_id, role)
select id, 'admin' from auth.users where email in ('lerestaudurire@gmail.com','contact.mraugustin243@gmail.com')
on conflict (user_id) do update set role='admin';

-- --------------------- PARTIE B : EVENEMENTS ET DROITS ------------------------
-- Droits d'accès (RLS) : inscription → création d'événement → validation admin. Idempotent, à lancer APRÈS database.sql.
create or replace function public.is_admin() returns boolean language plpgsql security definer set search_path=public as
$$ begin return coalesce(public.my_role()='admin',false); exception when others then return false; end $$;

create table if not exists public.events(id uuid primary key default gen_random_uuid());
alter table public.events add column if not exists owner_id uuid, add column if not exists title text, add column if not exists category text,
  add column if not exists country text, add column if not exists city text, add column if not exists venue text, add column if not exists starts_at timestamptz,
  add column if not exists description text, add column if not exists ticket_info text, add column if not exists poster_path text,
  add column if not exists tickets jsonb, add column if not exists pay_numbers jsonb, add column if not exists whatsapp text, add column if not exists pay_link text,
  add column if not exists modes jsonb, add column if not exists status text default 'pending', add column if not exists share_token text,
  add column if not exists created_at timestamptz default now();
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

-- ########## 01-database.sql ##########
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
update public.reservations set phone_idx=blind(dec(phone_enc)) where phone_enc is not null;
update public.orders set phone_idx=blind(dec(phone_enc)) where phone_enc is not null;
update public.waitlist set phone_idx=blind(dec(phone_enc)) where phone_enc is not null;

-- Lectures déchiffrées (admin / organisateur / client avec nom + numéro)
drop function if exists public.admin_rows(); drop function if exists public.admin_waitlist(); drop function if exists public.find_ticket(text,text);
drop function if exists public.find_order(text,text); drop function if exists public.org_orders(uuid); drop function if exists public.staff_check(text);
drop function if exists public.staff_list();
create or replace function public.admin_rows() returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(to_jsonb(r)-'phone_enc'-'email_enc'-'payer_enc'-'code_enc'-'phone_idx'||jsonb_build_object('phone',dec(phone_enc),'email',dec(email_enc),'payer',dec(payer_enc),'ticket_code','LRR-'||upper(left(id::text,8))) order by created_at desc) from reservations r),'[]'); end $$;
create or replace function public.admin_waitlist() returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(to_jsonb(w)-'phone_enc'-'phone_idx'||jsonb_build_object('phone',dec(phone_enc)) order by created_at desc) from waitlist w),'[]'); end $$;
create or replace function public.find_ticket(p_phone text,p_name text) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(r)-'phone_enc'-'email_enc'-'payer_enc'-'code_enc'-'phone_idx'-'phone'-'email'-'payer'||jsonb_build_object('code','LRR-'||upper(left(id::text,8)))),'[]')
 from reservations r where status='confirmed' and phone_idx=blind(p_phone) and name ilike '%'||trim(p_name)||'%' $$;
create or replace function public.find_order(p_phone text,p_name text) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'used',used,'code','EV-'||upper(left(id::text,8)),
  'desc',(select string_agg(i->>'name'||' × '||(i->>'qty'),', ') from jsonb_array_elements(to_jsonb(items)) i))),'[]')
 from orders where status='confirmed' and phone_idx=blind(p_phone) and name ilike '%'||trim(p_name)||'%' $$;
create or replace function public.org_orders(p_event uuid) returns jsonb language plpgsql security definer set search_path=public as $$
begin if my_role()<>'admin' and not exists(select 1 from events where id=p_event and owner_id=auth.uid()) then raise exception 'denied'; end if;
 return coalesce((select jsonb_agg(to_jsonb(o)-'phone_enc'-'email_enc'-'payer_enc'-'phone_idx'||jsonb_build_object('phone',dec(phone_enc),'email',dec(email_enc),'payer',dec(payer_enc)) order by created_at desc) from orders o where event_id=p_event),'[]'); end $$;
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

-- ########## 02-simplypaye.sql ##########
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

-- ########## 03-database-policies.sql ##########
-- Droits d'accès (RLS) : inscription → création d'événement → validation admin. Idempotent, à lancer APRÈS database.sql.
set check_function_bodies=off;
create or replace function public.is_admin() returns boolean language plpgsql security definer set search_path=public as
$$ begin return coalesce(public.my_role()='admin',false); exception when others then return false; end $$;

create table if not exists public.events(id uuid primary key default gen_random_uuid());
alter table public.events add column if not exists owner_id uuid, add column if not exists title text, add column if not exists category text,
  add column if not exists country text, add column if not exists city text, add column if not exists venue text, add column if not exists starts_at timestamptz,
  add column if not exists description text, add column if not exists ticket_info text, add column if not exists poster_path text,
  add column if not exists tickets jsonb, add column if not exists pay_numbers jsonb, add column if not exists whatsapp text, add column if not exists pay_link text,
  add column if not exists modes jsonb, add column if not exists status text default 'pending', add column if not exists share_token text,
  add column if not exists created_at timestamptz default now();
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

-- ########## 04-admin-fix.sql ##########
-- Donne l'accès administrateur à un compte (sans écraser l'ancienne logique). Idempotent.
-- Comptes administrateurs : lerestaudurire@gmail.com et contact.mraugustin243@gmail.com
set check_function_bodies=off;

create table if not exists public.app_roles(user_id uuid primary key, role text not null check (role in ('admin','staff')));
alter table public.app_roles enable row level security;
revoke all on public.app_roles from anon, authenticated;

-- 1) Sauvegarde l'ancienne fonction (comptes écrits en dur) sous le nom my_role_legacy
do $$ declare src text; begin
  if not exists (select 1 from pg_proc where proname='my_role_legacy') then
    select prosrc into src from pg_proc where proname='my_role' and pronamespace='public'::regnamespace limit 1;
    execute 'create function public.my_role_legacy() returns text language sql stable security definer set search_path=public as $f$'||src||'$f$';
  end if;
end $$;

-- 2) my_role lit d'abord la table app_roles, sinon l'ancienne logique
create or replace function public.my_role() returns text language sql stable security definer set search_path=public as
$$ select coalesce((select role from public.app_roles where user_id=auth.uid()), public.my_role_legacy(), 'none') $$;
grant execute on function public.my_role(), public.my_role_legacy() to anon, authenticated;

-- 3) Le compte administrateur
insert into public.app_roles(user_id, role)
select id, 'admin' from auth.users where email in ('lerestaudurire@gmail.com','contact.mraugustin243@gmail.com')
on conflict (user_id) do update set role='admin';


-- ########## 05-fix-creation-evenement.sql ##########
-- 05 — Correction : "Création impossible (400) : expected JSON array [22P02]"
-- Cause : certaines colonnes de la table events existent déjà dans votre base avec un type
-- tableau (text[]), alors que le site envoie du JSON (objets). Les scripts précédents
-- ("add column if not exists") ne changent jamais le type d'une colonne déjà créée.
-- À exécuter UNE fois dans Supabase > SQL Editor. Sans danger si déjà correct.

-- 0) Supprimer les anciennes contraintes CHECK qui utilisent des fonctions de tableau
--    (ex. cardinality(pay_numbers)) : elles bloquent la conversion en jsonb.
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid='public.events'::regclass and contype='c'
             and (pg_get_constraintdef(oid) ilike '%tickets%'
               or pg_get_constraintdef(oid) ilike '%pay_numbers%'
               or pg_get_constraintdef(oid) ilike '%modes%'
               or pg_get_constraintdef(oid) ilike '%cardinality%'
               or pg_get_constraintdef(oid) ilike '%array_length%') loop
    execute format('alter table public.events drop constraint %I', r.conname);
  end loop;
end $$;

do $$
declare c text;
begin
  foreach c in array array['tickets','pay_numbers'] loop
    if exists (select 1 from information_schema.columns
               where table_schema='public' and table_name='events' and column_name=c
                 and (data_type='ARRAY' or data_type in ('text','json','character varying'))) then
      execute format('alter table public.events alter column %I drop default', c);
      execute format('alter table public.events alter column %I type jsonb using
        case when %I is null then ''[]''::jsonb else to_jsonb(%I) end', c, c, c);
    end if;
  end loop;

  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='events' and column_name='modes'
               and data_type<>'jsonb') then
    alter table public.events alter column modes drop default;
    alter table public.events alter column modes type jsonb using '{}'::jsonb;
  end if;
end $$;

-- Valeurs par défaut sûres
alter table public.events alter column tickets set default '[]'::jsonb;
alter table public.events alter column pay_numbers set default '[]'::jsonb;
alter table public.events alter column modes set default '{}'::jsonb;

-- Même vérification pour les commandes (items envoyés en JSON)
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='orders' and column_name='items'
               and data_type<>'jsonb') then
    alter table public.orders alter column items type jsonb using to_jsonb(items);
  end if;
end $$;

notify pgrst, 'reload schema';

-- Contrôle : les 3 lignes doivent afficher "jsonb"

-- ########## 06 : evenements sur plusieurs dates (festival) ##########
alter table public.events add column if not exists ends_at timestamptz;
alter table public.events add column if not exists dates jsonb;
notify pgrst, 'reload schema';

-- ########## 07 : colonnes obligatoires heritees (ex. "cat") qui bloquent la creation ##########
do $$
declare r record;
begin
  for r in select column_name from information_schema.columns
           where table_schema='public' and table_name='events'
             and is_nullable='NO' and column_default is null and column_name<>'id' loop
    execute format('alter table public.events alter column %I drop not null', r.column_name);
  end loop;
end $$;
notify pgrst, 'reload schema';

-- ########## 08-suivi-organisateur.sql ##########
-- 08 — Page de suivi de l'organisateur (lien #progress/...) : fonction event_progress
-- Ne renvoie AUCUNE donnee personnelle (ni nom, ni telephone) : seulement les chiffres de vente.
drop function if exists public.event_progress(text);
create or replace function public.event_progress(p_token text) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce((
    select jsonb_build_object(
      'found', true,
      'title', e.title, 'venue', e.venue, 'city', e.city,
      'starts_at', e.starts_at, 'dates', e.dates,
      'tickets', coalesce(e.tickets,'[]'::jsonb),
      'orders', coalesce((
        select jsonb_agg(jsonb_build_object(
          'status', o.status,
          'kind', o.kind,
          'used', coalesce(o.used,false),
          'items', coalesce(o.items,'[]'::jsonb),
          'qty', coalesce(o.total_qty,(select coalesce(sum((i->>'qty')::int),0) from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i)),
          'amounts', coalesce(o.amounts,'{}'::jsonb),
          'day', to_char(o.created_at,'YYYY-MM-DD')))
        from public.orders o
        where o.event_id=e.id and o.status in ('pending','confirmed')), '[]'::jsonb))
    from public.events e
    where coalesce(p_token,'')<>'' and e.share_token=p_token
    limit 1
  ), jsonb_build_object('found', false));
$$;
grant execute on function public.event_progress(text) to anon, authenticated;
notify pgrst, 'reload schema';

-- ########## 09-supprimer-evenement.sql ##########
-- 09 — Suppression d'un evenement depuis le tableau de bord
-- Admin : peut tout supprimer. Organisateur : seulement ses evenements SANS commande confirmee.
drop function if exists public.delete_event(uuid);
create or replace function public.delete_event(p_id uuid) returns boolean
language plpgsql security definer set search_path=public as $$
declare ev public.events%rowtype;
begin
  select * into ev from public.events where id=p_id;
  if not found then raise exception 'introuvable'; end if;
  if not public.is_admin() then
    if ev.owner_id is distinct from auth.uid() then raise exception 'refuse'; end if;
    if exists(select 1 from public.orders where event_id=p_id and status='confirmed') then
      raise exception 'Cet evenement a deja des billets confirmes : contactez l''administrateur pour le supprimer.';
    end if;
  end if;
  delete from public.orders where event_id=p_id;
  delete from public.events where id=p_id;
  return true;
end $$;
revoke all on function public.delete_event(uuid) from public, anon;
grant execute on function public.delete_event(uuid) to authenticated;
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

-- ########## 15-ventes-par-vendeur.sql ##########
-- 15 - Ventes par vendeur (achat en especes) + securite renforcee
-- A coller dans Supabase > SQL Editor > Run. Relancable sans risque.

-- 1) Nettoyage automatique du nom du vendeur : espaces en trop, longueur max 60
create or replace function public.clean_seller() returns trigger
language plpgsql as $$
begin
  if NEW.seller is not null then
    NEW.seller := nullif(left(regexp_replace(btrim(NEW.seller), '\s+', ' ', 'g'), 60), '');
  end if;
  return NEW;
end $$;

drop trigger if exists clean_seller_orders on public.orders;
create trigger clean_seller_orders before insert or update of seller on public.orders
  for each row execute function public.clean_seller();

drop trigger if exists clean_seller_reservations on public.reservations;
create trigger clean_seller_reservations before insert or update of seller on public.reservations
  for each row execute function public.clean_seller();

-- 2) Index : regroupement rapide par vendeur (insensible a la casse)
create index if not exists orders_seller_idx on public.orders (event_id, lower(seller)) where seller is not null;
create index if not exists reservations_seller_idx on public.reservations (lower(seller)) where seller is not null;

-- 3) Rapport par vendeur d'un evenement : billets confirmes / en attente, detail par categorie, montants par devise.
--    Reserve a l'administrateur et au proprietaire de l'evenement.
create or replace function public.seller_report(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare res jsonb;
begin
  if not public.is_admin() then
    if not exists (select 1 from public.events e where e.id = p_event and e.owner_id = auth.uid()) then
      raise exception 'refuse';
    end if;
  end if;

  with base as (
    select o.id, lower(btrim(o.seller)) as k, btrim(o.seller) as nom, o.status,
           coalesce(o.total_qty, 0) as qty, coalesce(o.items, '[]'::jsonb) as items, coalesce(o.amounts, '{}'::jsonb) as amounts
    from public.orders o
    where o.event_id = p_event and o.seller is not null and btrim(o.seller) <> ''
      and o.status not in ('cancelled','rejected','expired','failed')
  ),
  cats as (
    select b.k, i->>'name' as cat, sum(coalesce((i->>'qty')::numeric, 0))::int as qty
    from base b, jsonb_array_elements(b.items) i
    where b.status = 'confirmed' group by b.k, i->>'name'
  ),
  amts as (
    select b.k, a.key as devise, sum(coalesce(a.value::numeric, 0)) as total
    from base b, jsonb_each_text(b.amounts) a
    where b.status = 'confirmed' group by b.k, a.key
  ),
  tot as (
    select k, min(nom) as nom,
           coalesce(sum(qty) filter (where status = 'confirmed'), 0)::int as confirmes,
           coalesce(sum(qty) filter (where status <> 'confirmed'), 0)::int as en_attente
    from base group by k
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'vendeur', t.nom, 'confirmes', t.confirmes, 'en_attente', t.en_attente,
      'categories', coalesce((select jsonb_object_agg(c.cat, c.qty) from cats c where c.k = t.k), '{}'::jsonb),
      'montants',  coalesce((select jsonb_object_agg(a.devise, a.total) from amts a where a.k = t.k), '{}'::jsonb)
    ) order by t.confirmes desc), '[]'::jsonb)
  into res from tot t;
  return res;
end $$;
revoke all on function public.seller_report(uuid) from public, anon;
grant execute on function public.seller_report(uuid) to authenticated;

-- 4) Securite : s'assurer que RLS est active sur les tables sensibles
alter table public.orders enable row level security;
alter table public.reservations enable row level security;
alter table public.waitlist enable row level security;

notify pgrst, 'reload schema';
