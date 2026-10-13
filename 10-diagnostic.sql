-- 10 - Diagnostic du systeme (bouton "Lancer le diagnostic" du Dashboard). Relancable sans risque.
create or replace function public.system_check() returns jsonb language plpgsql security definer set search_path=public as $$
declare r jsonb:='[]'; t text; f text;
begin
  if not public.is_admin() then raise exception 'denied'; end if;
  -- types des colonnes JSON
  for t,f in select * from (values ('events','tickets'),('events','pay_numbers'),('events','modes'),('orders','items')) v(a,b) loop
    r:=r||jsonb_build_object('n','Colonne '||t||'.'||f||' en jsonb','ok',coalesce((select data_type='jsonb' from information_schema.columns where table_schema='public' and table_name=t and column_name=f),false),
      'h','Lancez MISE-A-JOUR-SEULEMENT.sql (partie 05).');
  end loop;
  -- colonnes indispensables
  for t,f in select * from (values ('events','ticket_info'),('events','pay_link'),('events','dates'),('events','ends_at'),('events','share_token'),('events','owner_id'),
    ('orders','phone_enc'),('orders','phone_idx'),('orders','pay_ref'),('orders','hold'),('orders','expires_at'),
    ('reservations','phone_enc'),('reservations','phone_idx'),('reservations','pay_ref'),('reservations','hold'),('reservations','expires_at')) v(a,b) loop
    r:=r||jsonb_build_object('n','Colonne '||t||'.'||f,'ok',exists(select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=f),
      'h','Lancez SQL-COMPLET-A-JOUR.sql (ou MISE-A-JOUR-SEULEMENT.sql).');
  end loop;
  -- fonctions
  foreach f in array array['my_role','is_admin','admin_rows','admin_waitlist','find_ticket','find_order','org_orders','staff_check','staff_list','admin_overview','event_progress','delete_event','expire_holds','blind','enc','dec'] loop
    r:=r||jsonb_build_object('n','Fonction '||f,'ok',exists(select 1 from pg_proc where proname=f and pronamespace='public'::regnamespace),'h','Lancez SQL-COMPLET-A-JOUR.sql.');
  end loop;
  -- droits d'acces
  for t,f in select * from (values ('events','ev_insert'),('events','ev_select'),('events','ev_update'),('orders','ord_insert')) v(a,b) loop
    r:=r||jsonb_build_object('n','Droit '||f,'ok',exists(select 1 from pg_policies where schemaname='public' and tablename=t and policyname=f),'h','Lancez 03-database-policies.sql (inclus dans SQL-COMPLET-A-JOUR.sql).');
  end loop;
  -- administrateurs, cle de chiffrement, stockage
  r:=r||jsonb_build_object('n','Au moins un administrateur','ok',exists(select 1 from public.app_roles where role='admin'),'h','Lancez 04-admin-fix.sql.');
  r:=r||jsonb_build_object('n','Cle de chiffrement AES-256','ok',exists(select 1 from public.app_secrets where k='aes_key'),'h','Lancez 01-database.sql.');
  r:=r||jsonb_build_object('n','Stockage des affiches et preuves','ok',(select count(*) from storage.buckets where id in ('affiches','preuves'))=2,'h','Lancez 03-database-policies.sql.');
  return r;
end $$;
revoke all on function public.system_check() from public, anon;
grant execute on function public.system_check() to authenticated;
notify pgrst, 'reload schema';
