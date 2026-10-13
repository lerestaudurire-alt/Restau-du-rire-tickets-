-- Mise a jour uniquement (parties 05, 06, 07) : SANS les anciens scripts 00 a 04.
-- A coller dans Supabase > SQL Editor pour une base deja installee.

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
