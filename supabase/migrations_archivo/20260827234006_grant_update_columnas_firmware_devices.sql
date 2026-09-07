-- ═══════════════════════════════════════════════════════════════════
-- Permisos de escritura del firmware sobre devices   [2026-08-27]
--
-- El endurecimiento del 22-23/08 reemplazó los GRANT de tabla por GRANT por
-- columna para que anon no pudiera leer ni escribir access_key. Correcto, pero
-- dejó fuera TODAS las columnas que escribe el ESP32-C3:
--   · registro  → UPSERT con activation_key y device_id  (conflicto = UPDATE)
--   · heartbeat → PATCH con battery_percentage, battery_voltage,
--                 wifi_ssid, sensor_ok
-- Resultado: HTTP 401 "permission denied for table devices" en cada arranque.
--
-- Aquí se devuelve UPDATE solo sobre esas columnas. Siguen prohibidas para anon:
--   access_key   → la clave de acceso del cliente (tampoco se puede leer)
--   plan         → nadie puede auto-asignarse un plan pagado
--   expires_at   → ni extenderse la vigencia
--   activated    → ni marcarse como activado
--   current_cycle, consumo_diario_g, consumo_updated_at → los maneja el servidor
-- ═══════════════════════════════════════════════════════════════════
grant update (
    activation_key,        -- legacy, derivada del MAC; no es secreta
    device_id,             -- derivada del MAC
    battery_percentage,
    battery_voltage,
    wifi_ssid,
    sensor_ok,
    firmware
) on public.devices to anon, authenticated;

-- Higiene: TRUNCATE y DELETE no los filtra RLS y el firmware no los necesita.
revoke truncate on public.devices         from anon, authenticated;
revoke truncate on public.sensor_data     from anon, authenticated;
revoke truncate on public.cylinder_events from anon, authenticated;
revoke delete   on public.devices         from anon;
revoke delete   on public.cylinder_events from anon;;