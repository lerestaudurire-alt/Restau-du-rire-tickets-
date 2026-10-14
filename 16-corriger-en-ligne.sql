-- 16 — Les achats payés en ligne (SimplyPaye) étaient enregistrés « Réservation » : on les remet en « En ligne ».
-- Relançable sans risque. À coller dans Supabase > SQL Editor > Run.
update public.orders
   set kind = 'online'
 where pay_provider = 'simplypaye'
   and coalesce(kind,'') <> 'online';
notify pgrst, 'reload schema';
