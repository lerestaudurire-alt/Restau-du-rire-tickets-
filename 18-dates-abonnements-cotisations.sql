-- 18 - Lieu par date, abonnement aux organisateurs, cotisations. Relancable sans risque.

-- 1) Evenements : lieu par date + nom de l'organisateur
alter table public.events add column if not exists date_places jsonb, add column if not exists organizer_name text;

-- 2) Abonnements aux organisateurs (par appareil, sans compte)
create table if not exists public.organizer_follows (
  owner text not null, device text not null, created_at timestamptz not null default now(),
  primary key (owner, device));
alter table public.organizer_follows enable row level security;
create or replace function public.follow_organizer(p_owner text, p_device text, p_follow boolean)
returns integer language plpgsql security definer set search_path = public as $$
begin
  if p_owner is null or length(p_owner) > 64 or p_device is null or length(p_device) < 8 or length(p_device) > 64 then raise exception 'invalid'; end if;
  if p_follow then insert into public.organizer_follows(owner, device) values (p_owner, p_device) on conflict do nothing;
  else delete from public.organizer_follows where owner = p_owner and device = p_device; end if;
  return (select count(*)::int from public.organizer_follows where owner = p_owner);
end $$;
create or replace function public.organizer_follow_counts()
returns table(owner text, n integer) language sql security definer set search_path = public stable as $$
  select owner, count(*)::int from public.organizer_follows group by owner; $$;
grant execute on function public.follow_organizer(text,text,boolean), public.organizer_follow_counts() to anon, authenticated;

-- 3) Cotisations
create table if not exists public.cotisations (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null, title text not null, category text default 'solidarite', description text,
  goal numeric not null check (goal > 0), currency text not null default 'FC',
  deadline timestamptz, poster_path text, organizer_name text, whatsapp text, pay_numbers jsonb,
  status text not null default 'pending' check (status in ('pending','published','rejected','closed')),
  created_at timestamptz not null default now());
alter table public.cotisations enable row level security;
drop policy if exists cot_select on public.cotisations; drop policy if exists cot_insert on public.cotisations;
drop policy if exists cot_update on public.cotisations; drop policy if exists cot_delete on public.cotisations;
create policy cot_select on public.cotisations for select to anon, authenticated using (status in ('published','closed') or owner_id = auth.uid() or public.is_admin());
create policy cot_insert on public.cotisations for insert to authenticated with check (owner_id = auth.uid() and status = 'pending');
create policy cot_update on public.cotisations for update to authenticated using (public.is_admin() or (owner_id = auth.uid() and status = 'pending')) with check (public.is_admin() or (owner_id = auth.uid() and status = 'pending'));
create policy cot_delete on public.cotisations for delete to authenticated using (public.is_admin() or (owner_id = auth.uid() and status = 'pending'));

create table if not exists public.contributions (
  id uuid primary key default gen_random_uuid(),
  cotisation_id uuid not null references public.cotisations(id) on delete cascade,
  name text, anonymous boolean not null default false, message text,
  amount numeric not null check (amount > 0), proof_path text,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  created_at timestamptz not null default now());
alter table public.contributions enable row level security;
drop policy if exists contrib_insert on public.contributions; drop policy if exists contrib_select on public.contributions; drop policy if exists contrib_update on public.contributions;
create policy contrib_insert on public.contributions for insert to anon, authenticated with check (
  status = 'pending' and exists (select 1 from public.cotisations c where c.id = cotisation_id and c.status = 'published'));
create policy contrib_select on public.contributions for select to authenticated using (
  public.is_admin() or exists (select 1 from public.cotisations c where c.id = cotisation_id and c.owner_id = auth.uid()));
create policy contrib_update on public.contributions for update to authenticated using (
  public.is_admin() or exists (select 1 from public.cotisations c where c.id = cotisation_id and c.owner_id = auth.uid()))
  with check (public.is_admin() or exists (select 1 from public.cotisations c where c.id = cotisation_id and c.owner_id = auth.uid()));

-- Le proprietaire d'une cotisation peut voir les preuves de paiement de ses contributeurs
drop policy if exists prv_sel_cot on storage.objects;
create policy prv_sel_cot on storage.objects for select to authenticated using (
  bucket_id = 'preuves' and exists (select 1 from public.contributions k join public.cotisations c on c.id = k.cotisation_id
    where k.proof_path = name and c.owner_id = auth.uid()));

-- Totaux publics (contributions confirmees uniquement)
create or replace function public.cotisation_totals()
returns table(id uuid, collected numeric, n integer) language sql security definer set search_path = public stable as $$
  select cotisation_id, coalesce(sum(amount),0), count(*)::int from public.contributions where status = 'confirmed' group by cotisation_id; $$;
-- Mur des contributeurs (pas de numero, nom masque si anonyme)
create or replace function public.cotisation_donors(p_id uuid)
returns table(name text, amount numeric, message text, created_at timestamptz) language sql security definer set search_path = public stable as $$
  select case when anonymous or coalesce(name,'') = '' then 'Anonyme' else name end, amount, message, created_at
  from public.contributions where cotisation_id = p_id and status = 'confirmed' order by created_at desc limit 30; $$;
grant execute on function public.cotisation_totals(), public.cotisation_donors(uuid) to anon, authenticated;
notify pgrst, 'reload schema';

-- 4) Newsletter (e-mails chiffres comme le reste des donnees)
create table if not exists public.newsletter (
  id uuid primary key default gen_random_uuid(),
  email_enc bytea not null, email_idx text not null unique, created_at timestamptz not null default now());
alter table public.newsletter enable row level security;
create or replace function public.subscribe_newsletter(p_email text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare e text := lower(trim(coalesce(p_email,'')));
begin
  if length(e) > 200 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid'; end if;
  insert into public.newsletter(email_enc, email_idx)
  values (public.enc(e), encode(hmac(e, (select v from public.app_secrets where k = 'aes_key'), 'sha256'), 'hex'))
  on conflict (email_idx) do nothing;
  return true;
end $$;
create or replace function public.admin_newsletter()
returns table(email text, created_at timestamptz) language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin() then raise exception 'denied'; end if;
  return query select public.dec(n.email_enc), n.created_at from public.newsletter n order by n.created_at desc;
end $$;
grant execute on function public.subscribe_newsletter(text) to anon, authenticated;
grant execute on function public.admin_newsletter() to authenticated;
notify pgrst, 'reload schema';
