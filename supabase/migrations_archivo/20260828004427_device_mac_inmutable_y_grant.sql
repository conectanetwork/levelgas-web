-- ═══════════════════════════════════════════════════════════════════
-- device_mac: UPDATE concedido, pero inmutable por trigger   [2026-08-28]
--
-- PostgREST, en un upsert (?on_conflict=device_mac + resolution=merge-duplicates),
-- genera DO UPDATE SET sobre TODAS las columnas del payload, incluida la propia
-- columna de conflicto. Sin UPDATE sobre device_mac el registro del ESP32 muere
-- con 42501 aunque el valor no cambie.
--
-- Conceder UPDATE (device_mac) a secas permitiría a cualquiera con la clave
-- publicable reescribir el MAC de un equipo ajeno y dejar al cliente sin datos.
-- Por eso va acompañado de un trigger que lo vuelve inmutable: el upsert escribe
-- el mismo valor y pasa; cualquier intento real de cambiarlo se rechaza.
-- service_role y postgres quedan fuera del candado para tareas de mantenimiento.
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.devices_mac_inmutable()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if current_user in ('anon','authenticated')
     and NEW.device_mac is distinct from OLD.device_mac then
    raise exception 'device_mac es inmutable (de % a %)', OLD.device_mac, NEW.device_mac
      using errcode = '42501';
  end if;
  return NEW;
end;
$function$;

drop trigger if exists trg_devices_mac_inmutable on public.devices;
create trigger trg_devices_mac_inmutable
  before update on public.devices
  for each row execute function public.devices_mac_inmutable();

grant update (device_mac) on public.devices to anon, authenticated;;