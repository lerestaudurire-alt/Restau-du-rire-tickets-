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
