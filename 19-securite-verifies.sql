-- 19 : SÉCURITÉ RENFORCÉE + ORGANISATEURS VÉRIFIÉS
-- À exécuter UNE fois dans Supabase > SQL Editor > Run. Sans danger si relancé.
-- Ne supprime aucune donnée.

-- ============ 1. Limite de requêtes (anti-spam / anti-bot) ============
create table if not exists public.rate_hits(k text not null, at timestamptz not null default now());
create index if not exists rate_hits_k_at on public.rate_hits(k, at desc);
alter table public.rate_hits enable row level security;
revoke all on public.rate_hits from anon, authenticated;

create or replace function public.rl_check(p_key text, p_max int, p_window interval)
returns void language plpgsql security definer set search_path=public as $$
declare n int; ip text;
begin
  begin ip := split_part(coalesce((current_setting('request.headers', true)::json)->>'x-forwarded-for','?'), ',', 1);
  exception when others then ip := '?'; end;
  delete from public.rate_hits where at < now() - interval '2 days';
  select count(*) into n from public.rate_hits where k = p_key||':'||ip and at > now() - p_window;
  if n >= p_max then raise exception 'Trop de demandes, réessayez plus tard.' using errcode='P0001'; end if;
  insert into public.rate_hits(k) values (p_key||':'||ip);
end $$;
revoke all on function public.rl_check(text,int,interval) from public, anon, authenticated;

create or replace function public.trg_rl() returns trigger language plpgsql security definer set search_path=public as $$
begin perform public.rl_check(tg_table_name, tg_argv[0]::int, (tg_argv[1]||' minutes')::interval); return new; end $$;

do $$ declare r record; begin
  for r in select * from (values
    ('contributions',30,60),('cotisations',10,1440),('newsletter',10,60),
    ('organizer_follows',120,60),('events',40,1440)) v(t,mx,mn)
  loop
    if to_regclass('public.'||r.t) is not null then
      execute format('drop trigger if exists rl_%1$s on public.%1$s', r.t);
      execute format('create trigger rl_%1$s before insert on public.%1$s for each row execute function public.trg_rl(%2$L,%3$L)', r.t, r.mx, r.mn);
    end if;
  end loop;
end $$;

-- ============ 2. Limites de taille et de valeur (refuse les données abusives) ============
do $$ begin
  begin alter table public.events add constraint ev_len check (char_length(title)<=200 and char_length(coalesce(description,''))<=6000) not valid; exception when others then null; end;
  begin alter table public.cotisations add constraint cot_len check (char_length(title)<=200 and char_length(coalesce(description,''))<=6000 and goal>0 and goal<=1000000000) not valid; exception when others then null; end;
  begin alter table public.contributions add constraint con_len check (char_length(coalesce(name,''))<=100 and char_length(coalesce(message,''))<=500 and amount>0 and amount<=1000000000) not valid; exception when others then null; end;
end $$;

-- ============ 3. Fichiers : images seulement, 5 Mo max ============
do $$ begin
  update storage.buckets set file_size_limit=5242880, allowed_mime_types=array['image/jpeg','image/png','image/webp'] where id='affiches';
  update storage.buckets set file_size_limit=5242880, allowed_mime_types=array['image/jpeg','image/png','image/webp','application/pdf'] where id='preuves';
exception when others then null; end $$;

-- ============ 4. Journal d'audit (qui a changé quoi) ============
create table if not exists public.audit_log(
  id bigserial primary key, at timestamptz not null default now(),
  actor uuid, tbl text, op text, row_id text, old_status text, new_status text);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
drop policy if exists audit_admin on public.audit_log;
create policy audit_admin on public.audit_log for select to authenticated using (public.is_admin());
grant select on public.audit_log to authenticated;

create or replace function public.trg_audit() returns trigger language plpgsql security definer set search_path=public as $$
declare o jsonb; n jsonb;
begin
  o := case when tg_op='INSERT' then null else to_jsonb(old) end; n := case when tg_op='DELETE' then null else to_jsonb(new) end;
  if tg_op='UPDATE' and coalesce(o->>'status','')=coalesce(n->>'status','') then return new; end if;
  insert into public.audit_log(actor,tbl,op,row_id,old_status,new_status)
  values (auth.uid(), tg_table_name, tg_op, coalesce(n->>'id',o->>'id'), o->>'status', n->>'status');
  return coalesce(new, old);
end $$;

do $$ declare r text; begin
  foreach r in array array['events','cotisations','contributions','orders','tickets','payouts'] loop
    if to_regclass('public.'||r) is not null then
      execute format('drop trigger if exists au_%1$s on public.%1$s', r);
      execute format('create trigger au_%1$s after insert or update or delete on public.%1$s for each row execute function public.trg_audit()', r);
    end if;
  end loop;
end $$;

-- ============ 5. Organisateurs vérifiés (badge) ============
create table if not exists public.verified_owners(owner text primary key, at timestamptz default now());
alter table public.verified_owners enable row level security;
revoke all on public.verified_owners from anon, authenticated;

create or replace function public.verified_owner_ids() returns setof text
language sql stable security definer set search_path=public as $$ select owner from public.verified_owners $$;
grant execute on function public.verified_owner_ids() to anon, authenticated;

create or replace function public.set_verified(p_owner text, p_on boolean) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur.'; end if;
  if p_on then insert into public.verified_owners(owner) values (p_owner) on conflict do nothing;
  else delete from public.verified_owners where owner = p_owner; end if;
end $$;
revoke all on function public.set_verified(text,boolean) from public, anon;
grant execute on function public.set_verified(text,boolean) to authenticated;

-- ============ 6. Contrôle : tables sans protection (doit renvoyer 0 ligne) ============
create or replace function public.security_report() returns table(tablename text, probleme text)
language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l''administrateur.'; end if;
  return query select t.tablename::text, 'RLS désactivé'::text from pg_tables t where t.schemaname='public' and not t.rowsecurity;
end $$;
revoke all on function public.security_report() from public, anon;
grant execute on function public.security_report() to authenticated;

-- Pour vérifier un organisateur : select public.set_verified('ID_DE_L_ORGANISATEUR', true);
-- (l'ID est la valeur owner_id de ses événements ; connectez-vous en administrateur d'abord,
--  ou exécutez : insert into public.verified_owners(owner) values ('ID_DE_L_ORGANISATEUR');)
