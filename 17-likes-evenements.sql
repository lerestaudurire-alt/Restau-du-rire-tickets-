-- 17 - "J'aime" sur les evenements (coeur + compteur). Relancable sans risque.
create table if not exists public.event_likes (
  event_id text not null,
  device   text not null,
  created_at timestamptz not null default now(),
  primary key (event_id, device)
);
alter table public.event_likes enable row level security; -- aucun acces direct : tout passe par les fonctions ci-dessous

create or replace function public.like_event(p_event text, p_device text, p_like boolean)
returns integer language plpgsql security definer set search_path = public as $$
begin
  if p_event is null or length(p_event) > 64 or p_device is null or length(p_device) < 8 or length(p_device) > 64 then
    raise exception 'invalid';
  end if;
  if p_like then
    insert into public.event_likes(event_id, device) values (p_event, p_device) on conflict do nothing;
  else
    delete from public.event_likes where event_id = p_event and device = p_device;
  end if;
  return (select count(*)::int from public.event_likes where event_id = p_event);
end $$;

create or replace function public.event_like_counts()
returns table(event_id text, n integer) language sql security definer set search_path = public stable as $$
  select event_id, count(*)::int from public.event_likes group by event_id;
$$;

grant execute on function public.like_event(text, text, boolean) to anon, authenticated;
grant execute on function public.event_like_counts() to anon, authenticated;
notify pgrst, 'reload schema';
