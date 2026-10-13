-- 13 - Plusieurs images par annonce. Relancable sans risque.
alter table public.announcements add column if not exists images jsonb default '[]'::jsonb;
notify pgrst, 'reload schema';
