-- ═══════════════════════════════════════════════════════════════════
-- reset_cylinder_history  [2026-08-27]
-- Permite al cliente reiniciar el contador de cilindros y borrar todo su
-- historial de mediciones. Es IRREVERSIBLE, por eso exige la clave de acceso.
--
-- NO toca la fila de public.devices: device_mac, device_id, activation_key,
-- activated, firmware, access_key, plan, expires_at, full_weight, empty_weight
-- y last_calibration vienen de la activación de fábrica del ESP32-C3 o de la
-- configuración física de la instalación, y deben sobrevivir al reseteo.
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.reset_cylinder_history(
    p_device_mac text,
    p_access_key text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
    v_check     text;
    v_device_id text;
    n_sensor    bigint := 0;
    n_events    bigint := 0;
    n_daily     bigint := 0;
    n_alerts    bigint := 0;
begin
    -- 1. Verificación server-side. Sin clave correcta esto es un no-op total.
    v_check := public.verify_access_key(p_device_mac, p_access_key);
    if v_check <> 'ok' then
        return jsonb_build_object('ok', false, 'msg', v_check);
    end if;

    select d.device_id into v_device_id
      from public.devices d
     where d.device_mac = p_device_mac
     limit 1;

    if v_device_id is null then
        return jsonb_build_object('ok', false, 'msg', 'device_sin_device_id');
    end if;

    -- 2. Historial de mediciones y todo lo derivado de él.
    delete from public.sensor_data          where device_id = v_device_id;
    get diagnostics n_sensor = row_count;

    delete from public.cylinder_events      where device_id = v_device_id;
    get diagnostics n_events = row_count;

    delete from public.sensor_daily_summary where device_id = v_device_id;
    get diagnostics n_daily = row_count;

    delete from public.device_alerts        where device_id = v_device_id;
    get diagnostics n_alerts = row_count;

    -- 3. Contador a 1 y derivados históricos a cero. Nada más.
    update public.devices
       set current_cycle      = 1,
           consumo_diario_g   = null,
           consumo_updated_at = null
     where device_id = v_device_id;

    return jsonb_build_object(
        'ok',    true,
        'msg',   'reset_ok',
        'cycle', 1,
        'borrado', jsonb_build_object(
            'sensor_data',     n_sensor,
            'cylinder_events', n_events,
            'daily_summary',   n_daily,
            'alertas',         n_alerts
        )
    );
end;
$function$;

revoke all     on function public.reset_cylinder_history(text, text) from public;
grant  execute on function public.reset_cylinder_history(text, text) to anon, authenticated;;