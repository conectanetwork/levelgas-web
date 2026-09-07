-- Bloques 2, 3 y 4 de 20260906_paso0_seguridad.sql
-- Requiere index.html parcheado ya desplegado (usa set_recovery_contact).

-- ── 2) Cierre de la cadena de secuestro de cuenta ──────────────────────────
-- user_email / user_phone : raíz de confianza del flujo de recuperación.
-- device_id               : renombrar un equipo ajeno lo deja huérfano.
-- device_mac              : redundante con trg_devices_mac_inmutable; defensa en profundidad.
-- activation_key          : nadie lo escribe desde el navegador.
revoke update (user_email, user_phone, device_id, device_mac, activation_key)
    on public.devices from anon, authenticated;

-- El firmware solo INSERTA lecturas y el dashboard solo las LEE.
revoke update on public.sensor_data from anon, authenticated;

-- El dashboard inserta y lee eventos de recambio, nunca los modifica.
revoke update on public.cylinder_events from anon, authenticated;

-- ── 3) Grants latentes en tablas que el dashboard NO usa ───────────────────
-- Verificado: 0 referencias a estas tablas en index.html.
-- Las Edge Functions usan service_role y no se ven afectadas.
revoke all on public.device_alerts          from anon, authenticated;
revoke all on public.device_config          from anon, authenticated;
revoke all on public.sensor_daily_summary   from anon, authenticated;
revoke all on public.sensor_weekly_summary  from anon, authenticated;
revoke all on public.subscriptions          from anon, authenticated;
revoke all on public.user_plans             from anon, authenticated;

-- ── 4) last_seen_at solo lo mueve la telemetría ────────────────────────────
create or replace function public.update_last_seen()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  -- Las ediciones del dashboard (correo, teléfono, pesos, clave) NO deben
  -- resetear el reloj de obsolescencia: si lo hacen, una báscula muerta
  -- aparece como viva en el mapa de reposición.
  if NEW.battery_percentage is distinct from OLD.battery_percentage
     or NEW.battery_voltage is distinct from OLD.battery_voltage
     or NEW.firmware        is distinct from OLD.firmware
     or NEW.wifi_ssid       is distinct from OLD.wifi_ssid
     or NEW.sensor_ok       is distinct from OLD.sensor_ok
  then
    NEW.last_seen_at = now();
  end if;
  return NEW;
end;
$function$;;