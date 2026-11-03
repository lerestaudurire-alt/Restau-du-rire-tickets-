-- Compteur de vues du Restau du Rire
-- À coller dans Supabase > SQL Editor > Run (une seule fois).

create table if not exists public.event_page_views (
  id         bigint generated always as identity primary key,
  event_id   text        not null,
  created_at timestamptz not null default now()
);
create index if not exists event_page_views_event_idx on public.event_page_views (event_id);

-- Personne ne lit/écrit la table directement : tout passe par les 2 fonctions ci-dessous.
alter table public.event_page_views enable row level security;

drop function if exists public.track_view(text);
drop function if exists public.track_view(uuid);
drop function if exists public.event_view_counts();

-- +1 chaque fois qu'un nouveau visiteur ouvre la page d'un événement
create function public.track_view(p_event text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_event is null or length(p_event) = 0 or length(p_event) > 100 then
    return;
  end if;
  insert into public.event_page_views (event_id) values (p_event);
end;
$$;

-- Nombre de vues par événement (affiché sur les cartes et sur la page)
create function public.event_view_counts()
returns table (event_id text, n bigint)
language sql
stable
security definer
set search_path = public
as $$
  select v.event_id, count(*)::bigint as n
  from public.event_page_views v
  group by v.event_id;
$$;

grant execute on function public.track_view(text)      to anon, authenticated;
grant execute on function public.event_view_counts()   to anon, authenticated;
