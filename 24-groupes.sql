-- =====================================================================
-- 24 - ACHAT EN GROUPE SUIVI (V13) : à exécuter UNE FOIS dans Supabase > SQL Editor (relançable sans risque)
-- Un meneur crée un groupe (code G....). Chaque ami saisit ce code à l'achat : la commande porte address.grp.
-- Le suivi (qui a payé) est public par code, avec les prénoms seulement.
-- =====================================================================
create table if not exists public.group_buys (
  code text primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  leader_name text not null,
  target int not null default 2,
  created_at timestamptz not null default now()
);
alter table public.group_buys enable row level security;   -- aucune policy publique : tout passe par les fonctions ci-dessous

create or replace function public.group_create(p_event uuid, p_leader text, p_target int)
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int := 0; ld text := left(trim(coalesce(p_leader, '')), 60);
begin
  if not exists (select 1 from public.events where id = p_event and status = 'published') then raise exception 'Événement indisponible'; end if;
  if length(ld) < 2 then raise exception 'Nom obligatoire'; end if;
  loop
    c := 'G' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 5));
    begin
      insert into public.group_buys(code, event_id, leader_name, target)
      values (c, p_event, ld, greatest(2, least(coalesce(p_target, 2), 50)));
      return c;
    exception when unique_violation then
      i := i + 1; if i > 6 then raise; end if;
    end;
  end loop;
end $$;

create or replace function public.group_status(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g public.group_buys; t text; r jsonb;
begin
  select * into g from public.group_buys where code = upper(trim(coalesce(p_code, '')));
  if not found then return null; end if;
  select title into t from public.events where id = g.event_id;
  select jsonb_build_object(
    'code', g.code, 'leader', g.leader_name, 'target', g.target, 'event_id', g.event_id, 'title', t,
    'confirmed', coalesce(sum(case when o.status = 'confirmed' then coalesce(o.total_qty, 0) end), 0),
    'pending',   coalesce(sum(case when o.status <> 'confirmed' then coalesce(o.total_qty, 0) end), 0),
    'members',   coalesce(jsonb_agg(jsonb_build_object('n', split_part(o.name, ' ', 1), 'q', coalesce(o.total_qty, 0), 's', o.status) order by o.created_at) filter (where o.id is not null), '[]'::jsonb))
  into r
  from (select 1) d
  left join public.orders o
    on o.event_id = g.event_id
   and upper(coalesce((o.address::jsonb)->>'grp', '')) = g.code
   and o.status not in ('cancelled', 'rejected', 'expired', 'failed');
  return r;
end $$;

grant execute on function public.group_create(uuid, text, int) to anon, authenticated;
grant execute on function public.group_status(text) to anon, authenticated;
notify pgrst, 'reload schema';
