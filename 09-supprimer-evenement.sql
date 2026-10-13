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
