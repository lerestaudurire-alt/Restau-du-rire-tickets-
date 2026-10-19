-- 21 - Avis apres spectacle (livre d'or), alertes "prochaine edition", historique + points de fidelite.
-- Relancable sans risque. Aucun code promo.

-- 1) Avis : seuls les vrais spectateurs (billet confirme, nom + numero) peuvent noter, 1 avis par personne et par evenement
create table if not exists public.event_reviews(
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null, name text not null, rating int not null check (rating between 1 and 5),
  comment text check (comment is null or length(comment) <= 600),
  phone_idx text not null, hidden boolean not null default false, created_at timestamptz not null default now(),
  unique(event_id, phone_idx));
alter table public.event_reviews enable row level security;
revoke all on public.event_reviews from anon, authenticated;

create or replace function public.submit_review(p_event uuid, p_name text, p_phone text, p_rating int, p_comment text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_name text; v_start timestamptz;
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'rating'; end if;
  if length(trim(coalesce(p_name,''))) < 3 or length(coalesce(p_phone,'')) < 6 then raise exception 'invalid'; end if;
  select greatest(e.starts_at, coalesce((select max(x::timestamptz) from jsonb_array_elements_text(coalesce(e.dates,'[]'::jsonb)) x), e.starts_at))
    into v_start from events e where e.id = p_event;
  if v_start is null or v_start > now() then raise exception 'not_over'; end if;
  if not exists(select 1 from orders where event_id = p_event and status = 'confirmed'
      and phone_idx = blind(p_phone) and name ilike '%'||trim(p_name)||'%') then raise exception 'no_ticket'; end if;
  v_name := initcap(split_part(trim(p_name),' ',1)) || coalesce(' '||upper(left(nullif(split_part(trim(p_name),' ',2),''),1))||'.','');
  insert into event_reviews(event_id,name,rating,comment,phone_idx)
    values(p_event, v_name, p_rating, nullif(left(trim(coalesce(p_comment,'')),600),''), blind(p_phone))
    on conflict (event_id, phone_idx) do update set rating = excluded.rating, comment = excluded.comment, name = excluded.name, created_at = now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.event_reviews_public(p_event uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select jsonb_build_object(
    'avg', coalesce((select round(avg(rating)::numeric,1) from event_reviews where event_id=p_event and not hidden),0),
    'n', (select count(*) from event_reviews where event_id=p_event and not hidden),
    'list', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'rating',rating,'comment',comment,'at',created_at) order by created_at desc)
      from (select * from event_reviews where event_id=p_event and not hidden order by created_at desc limit 60) r),'[]')) $$;

create or replace function public.hide_review(p_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if my_role() <> 'admin' and not exists(select 1 from event_reviews r join events e on e.id=r.event_id where r.id=p_id and e.owner_id=auth.uid()) then raise exception 'denied'; end if;
  update event_reviews set hidden = true where id = p_id;
end $$;

-- 2) "Me prevenir pour la prochaine edition" (chiffre comme le reste)
create table if not exists public.event_alerts(
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null, name text, phone_enc bytea, phone_idx text not null, created_at timestamptz not null default now(),
  unique(event_id, phone_idx));
alter table public.event_alerts enable row level security;
revoke all on public.event_alerts from anon, authenticated;

create or replace function public.subscribe_alert(p_event uuid, p_name text, p_phone text)
returns integer language plpgsql security definer set search_path=public,extensions as $$
begin
  if length(coalesce(p_phone,'')) < 6 or length(p_phone) > 20 or length(coalesce(p_name,'')) > 80 then raise exception 'invalid'; end if;
  insert into event_alerts(event_id,name,phone_enc,phone_idx) values(p_event, nullif(trim(p_name),''), enc(p_phone), blind(p_phone)) on conflict do nothing;
  return (select count(*)::int from event_alerts where event_id = p_event);
end $$;

create or replace function public.alert_count(p_event uuid)
returns integer language sql security definer stable set search_path=public as $$ select count(*)::int from event_alerts where event_id = p_event $$;

create or replace function public.org_alerts(p_event uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
begin
  if my_role() <> 'admin' and not exists(select 1 from events where id=p_event and owner_id=auth.uid()) then raise exception 'denied'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('name',name,'phone',public.dec(phone_enc)) order by created_at desc) from event_alerts where event_id=p_event),'[]');
end $$;

-- 3) Historique des soirees vecues + points de fidelite (10 points par billet confirme, +5 si scanne a l'entree)
create or replace function public.my_history(p_phone text, p_name text)
returns jsonb language sql security definer stable set search_path=public,extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object('event_id',o.event_id,'title',e.title,'venue',e.venue,'city',e.city,'at',e.starts_at,
      'qty',coalesce(o.total_qty,1),'used',coalesce(o.used,false),
      'points',coalesce(o.total_qty,1)*10 + case when o.used then 5 else 0 end) order by e.starts_at desc),'[]')
  from orders o join events e on e.id=o.event_id
  where o.status='confirmed' and o.phone_idx=blind(p_phone) and o.name ilike '%'||trim(p_name)||'%' $$;

grant execute on function public.submit_review(uuid,text,text,int,text), public.event_reviews_public(uuid), public.hide_review(uuid),
  public.subscribe_alert(uuid,text,text), public.alert_count(uuid), public.org_alerts(uuid), public.my_history(text,text) to anon, authenticated;
notify pgrst, 'reload schema';
