-- 11 - Annonces & actualites (page d'accueil). Relancable sans risque.
create table if not exists public.announcements(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  title text not null, body text, image_url text, link_url text,
  active boolean not null default true, sort int default 0);
alter table public.announcements enable row level security;
drop policy if exists ann_read on public.announcements;
drop policy if exists ann_admin on public.announcements;
create policy ann_read on public.announcements for select to anon, authenticated using (active or public.is_admin());
create policy ann_admin on public.announcements for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.announcements to anon;
grant select, insert, update, delete on public.announcements to authenticated;
notify pgrst, 'reload schema';
