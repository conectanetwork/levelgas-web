-- Corrección del trigger [2026-08-28]
-- La versión anterior era SECURITY DEFINER, así que dentro de la función
-- current_user pasaba a ser el dueño (postgres) y la comparación con
-- 'anon'/'authenticated' nunca se cumplía: el candado no cerraba.
-- Verificado en banco: anon logró reescribir el device_mac de otro equipo.
-- Un trigger que solo compara NEW y OLD no necesita privilegios elevados.
create or replace function public.devices_mac_inmutable()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if current_user in ('anon','authenticated')
     and NEW.device_mac is distinct from OLD.device_mac then
    raise exception 'device_mac es inmutable (intento: % → %)', OLD.device_mac, NEW.device_mac
      using errcode = '42501';
  end if;
  return NEW;
end;
$function$;;