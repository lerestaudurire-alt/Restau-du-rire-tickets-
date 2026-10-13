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
