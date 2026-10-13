-- 14 - Stock limite : impossible de vendre plus de billets que le total programme (en ligne + especes + reservations).
-- Relancable sans risque.
create or replace function public.orders_stock_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare ev jsonb; t jsonb; it jsonb; lim int; sold int; want int;
begin
  if NEW.event_id is null or coalesce(NEW.status,'pending') in ('cancelled','rejected','expired','failed') then return NEW; end if;
  perform pg_advisory_xact_lock(hashtext(NEW.event_id::text));
  select tickets into ev from public.events where id = NEW.event_id;
  if ev is null or jsonb_typeof(ev) <> 'array' then return NEW; end if;
  for it in select * from jsonb_array_elements(coalesce(NEW.items,'[]'::jsonb)) loop
    t := null;
    select x into t from jsonb_array_elements(ev) x where x->>'id' = it->>'id' limit 1;
    lim := coalesce(nullif(t->>'stock','')::numeric, 0)::int;
    if t is not null and lim > 0 then
      select coalesce(sum((i->>'qty')::numeric),0)::int into sold
        from public.orders o, jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) i
        where o.event_id = NEW.event_id and o.status not in ('cancelled','rejected','expired','failed') and i->>'id' = it->>'id';
      want := coalesce((it->>'qty')::numeric, 0)::int;
      if sold + want > lim then
        raise exception 'SOLD_OUT: % (reste %)', coalesce(t->>'name',''), greatest(lim - sold, 0);
      end if;
    end if;
  end loop;
  return NEW;
end $$;
drop trigger if exists orders_stock_guard on public.orders;
create trigger orders_stock_guard before insert on public.orders for each row execute function public.orders_stock_guard();
notify pgrst, 'reload schema';
