-- =====================================================================
-- 28 - NOUVELLES CATEGORIES DE BILLETS SUR UN EVENEMENT DEJA EN LIGNE
--      + QUOTAS PAR VENDEUR (stockes dans events.modes.sellers)
-- A executer UNE FOIS dans Supabase > SQL Editor (relancable sans risque).
-- Prerequis : 21-fonctions-pro.sql deja lance (fonction p4_owns).
-- =====================================================================

-- 1) Ajouter une ou plusieurs categories a un evenement publie.
--    Reserve a l'organisateur de l'evenement et a l'administrateur.
--    Les categories existantes ne sont JAMAIS modifiees ni supprimees
--    (les billets deja vendus restent valables).
create or replace function public.owner_add_tickets(p_event uuid, p_new jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cur jsonb;
  n jsonb;
  nid text;
  i int;
  nm text;
  pr numeric;
  cu text;
  st numeric;
  nxt int;
begin
  if not public.p4_owns(p_event) then
    raise exception 'refuse';
  end if;
  if p_new is null or jsonb_typeof(p_new) <> 'array' or jsonb_array_length(p_new) = 0 then
    raise exception 'Aucune categorie a ajouter';
  end if;
  if jsonb_array_length(p_new) > 20 then
    raise exception 'Maximum 20 categories a la fois';
  end if;

  select coalesce(tickets, '[]'::jsonb) into cur from public.events where id = p_event for update;
  if cur is null then cur := '[]'::jsonb; end if;

  -- prochain numero libre (t1, t2, ... -> t<max+1>)
  select coalesce(max((regexp_replace(x->>'id', '\D', '', 'g'))::int), 0) + 1
    into nxt
    from jsonb_array_elements(cur) x
   where regexp_replace(coalesce(x->>'id',''), '\D', '', 'g') <> '';
  if nxt is null then nxt := jsonb_array_length(cur) + 1; end if;

  for i in 0 .. jsonb_array_length(p_new) - 1 loop
    n  := p_new -> i;
    nm := left(btrim(coalesce(n->>'name', '')), 60);
    if nm = '' then raise exception 'Nom de categorie obligatoire'; end if;
    -- refuse un nom deja utilise (insensible a la casse)
    if exists (select 1 from jsonb_array_elements(cur) x where lower(btrim(x->>'name')) = lower(nm)) then
      raise exception 'La categorie « % » existe deja', nm;
    end if;
    pr := coalesce(nullif(n->>'price', '')::numeric, 0);
    if pr < 0 then raise exception 'Prix invalide'; end if;
    cu := case when upper(coalesce(n->>'currency', 'FC')) in ('USD', '$') then 'USD' else 'FC' end;
    st := nullif(n->>'stock', '')::numeric;
    if st is not null and (st < 1 or st > 1000000) then raise exception 'Stock invalide'; end if;
    nid := 't' || nxt::text;
    nxt := nxt + 1;
    cur := cur || jsonb_build_array(jsonb_build_object(
      'id', nid, 'name', nm, 'price', pr, 'currency', cu, 'stock', st));
  end loop;

  update public.events set tickets = cur where id = p_event;
  return cur;
end $$;
revoke all on function public.owner_add_tickets(uuid, jsonb) from public, anon;
grant execute on function public.owner_add_tickets(uuid, jsonb) to authenticated;

-- 2) Ventes detaillees par vendeur (jour, heure, acheteur, WhatsApp, categorie).
--    Sert au tableau « Vendeurs & quotas » et au rapport CSV complet.
--    Reserve a l'organisateur de l'evenement et a l'administrateur.
create or replace function public.seller_sales(p_event uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare res jsonb;
begin
  if not public.p4_owns(p_event) then
    raise exception 'refuse';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'vendeur', btrim(o.seller), 'acheteur', o.name, 'whatsapp', o.phone,
      'kind', o.kind, 'status', o.status, 'items', coalesce(o.items, '[]'::jsonb),
      'qty', coalesce(o.total_qty, 0), 'amounts', coalesce(o.amounts, '{}'::jsonb),
      'created_at', o.created_at, 'confirmed_at', o.confirmed_at
    ) order by o.created_at), '[]'::jsonb)
  into res
  from public.orders o
  where o.event_id = p_event
    and o.seller is not null and btrim(o.seller) <> ''
    and o.status not in ('cancelled', 'rejected', 'expired', 'failed');
  return res;
end $$;
revoke all on function public.seller_sales(uuid) from public, anon;
grant execute on function public.seller_sales(uuid) to authenticated;

notify pgrst, 'reload schema';
