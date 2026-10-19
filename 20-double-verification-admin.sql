-- 20 : DOUBLE VÉRIFICATION ADMIN + PROTECTIONS SUPPLÉMENTAIRES
-- À lancer APRÈS le 19. Sans danger si relancé. Si vous relancez un ancien gros fichier SQL, relancez celui-ci ensuite.
-- La double vérification n'est PAS imposée tant que vous ne l'activez pas (étape en bas) : aucun risque de blocage.

create table if not exists public.security_settings(k text primary key, v text);
alter table public.security_settings enable row level security;
revoke all on public.security_settings from anon, authenticated;
insert into public.security_settings(k,v) values ('admin_mfa','off') on conflict do nothing;

-- is_admin() : même rôle qu'avant, mais exige la double vérification quand elle est activée
create or replace function public.is_admin() returns boolean language plpgsql security definer set search_path=public as $$
begin
  return coalesce(public.my_role()='admin',false)
    and (coalesce((select v from public.security_settings where k='admin_mfa'),'off')<>'on'
         or coalesce(auth.jwt()->>'aal','aal1')='aal2');
exception when others then return false; end $$;
grant execute on function public.is_admin() to anon, authenticated;

-- Activer / désactiver l'obligation (l'activer exige d'être connecté avec le code)
create or replace function public.set_admin_mfa(p_on boolean) returns text language plpgsql security definer set search_path=public as $$
begin
  if coalesce(public.my_role(),'none')<>'admin' then raise exception 'Réservé à l''administrateur.'; end if;
  if p_on and coalesce(auth.jwt()->>'aal','aal1')<>'aal2' then
    raise exception 'Activez d''abord la double vérification dans Mon espace, reconnectez-vous avec le code, puis relancez.'; end if;
  insert into public.security_settings(k,v) values('admin_mfa',case when p_on then 'on' else 'off' end)
    on conflict (k) do update set v=excluded.v;
  return case when p_on then 'Double vérification OBLIGATOIRE pour l''admin' else 'Double vérification facultative' end;
end $$;
revoke all on function public.set_admin_mfa(boolean) from public, anon;
grant execute on function public.set_admin_mfa(boolean) to authenticated;

-- Liste d'attente : limite anti-spam + taille
do $$ begin
  if to_regclass('public.waitlist') is not null then
    drop trigger if exists rl_waitlist on public.waitlist;
    create trigger rl_waitlist before insert on public.waitlist for each row execute function public.trg_rl('waitlist','20','60');
  end if;
exception when others then null; end $$;

-- Dépôt de preuves de paiement : limite par adresse (peut être refusé selon vos droits Supabase : sans gravité)
do $$ begin
  drop trigger if exists rl_upload on storage.objects;
  create trigger rl_upload before insert on storage.objects for each row execute function public.trg_rl('upload','60','60');
exception when others then null; end $$;

-- ============ POUR IMPOSER LA DOUBLE VÉRIFICATION À L'ADMIN (plus tard) ============
-- 1) Supabase > Authentication > Sign In / Providers > Multi-Factor : activez TOTP.
-- 2) Sur le site : Mon espace > Double vérification > Activer. Reconnectez-vous avec le code.
-- 3) Connecté en admin, exécutez dans le SQL Editor de l'application ou via le site :  select public.set_admin_mfa(true);
--    (Dans le SQL Editor Supabase, vous êtes « postgres » : utilisez plutôt  update public.security_settings set v='on' where k='admin_mfa';)
-- Pour revenir en arrière en cas de problème :  update public.security_settings set v='off' where k='admin_mfa';
