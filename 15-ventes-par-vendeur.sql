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
