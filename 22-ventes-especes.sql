-- =====================================================================
-- 22 - VENTES EN ESPECES : civilité du client + date/heure de confirmation
-- À exécuter UNE FOIS dans Supabase > SQL Editor (relançable sans risque).
-- Les dashboards organisateur et propriétaire (admin) lisent déjà toutes les colonnes via org_orders :
-- les nouvelles colonnes apparaissent donc automatiquement. Seuls l'organisateur de l'événement et l'admin y ont accès.
-- =====================================================================
alter table public.orders add column if not exists civility text;
alter table public.orders add column if not exists confirmed_at timestamptz;
alter table public.orders add column if not exists confirmed_by uuid;

create or replace function public.orders_p6_meta() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if NEW.civility is not null and NEW.civility not in ('Monsieur', 'Madame') then NEW.civility := null; end if;
  if TG_OP = 'INSERT' then
    if NEW.status = 'confirmed' then NEW.confirmed_at := now(); NEW.confirmed_by := auth.uid();
    else NEW.confirmed_at := null; NEW.confirmed_by := null; end if;
  else
    NEW.confirmed_at := OLD.confirmed_at; NEW.confirmed_by := OLD.confirmed_by;
    if NEW.status = 'confirmed' and OLD.status is distinct from 'confirmed' then
      NEW.confirmed_at := now(); NEW.confirmed_by := auth.uid();
    end if;
  end if;
  return NEW;
end $$;
drop trigger if exists orders_p6_meta on public.orders;
create trigger orders_p6_meta before insert or update on public.orders for each row execute function public.orders_p6_meta();

notify pgrst, 'reload schema';
