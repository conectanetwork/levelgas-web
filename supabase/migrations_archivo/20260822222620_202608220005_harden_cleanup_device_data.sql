-- =============================================================================
-- LevelGas — Blindar cleanup_device_data() en vez de dejarla bloqueada
-- Migración 202608220005
--
-- Al revisar el dashboard (commercial-app/apps/client/dist/dashboard/index.html,
-- función checkPlanExpiry/cleanupOnExpiry) se confirmó que SÍ llama a
-- cleanup_device_data(p_device_id) como parte normal del flujo: al detectar
-- localmente que el plan venció, limpia los datos del propio dispositivo.
-- La migración 202608220001 le había revocado EXECUTE a anon por completo
-- (correcto en su momento: no existía ningún control server-side, cualquiera
-- podía borrar los datos de CUALQUIER dispositivo con solo su device_id).
--
-- Fix definitivo: en vez de dejarla bloqueada (lo que rompe la limpieza
-- instantánea al vencer, cayendo solo en el cron diario), se añade la misma
-- verificación server-side que ya usa cleanup_expired_plans() — sólo actúa
-- si ESE dispositivo realmente tiene el plan vencido. Llamarla para un
-- dispositivo ajeno o no vencido pasa a ser un no-op inofensivo.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.cleanup_device_data(p_device_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
BEGIN
    -- Sólo actúa si el dispositivo existe, tiene plan pagado y YA venció.
    -- Server-side, no depende del reloj del cliente ni de nada que el
    -- llamante controle.
    IF NOT EXISTS (
        SELECT 1 FROM public.devices
        WHERE device_id = p_device_id
          AND plan IN ('hogar', 'empresa')
          AND expires_at IS NOT NULL
          AND expires_at < NOW()
    ) THEN
        RETURN; -- no-op: dispositivo ajeno, plan free, o aún vigente
    END IF;

    DELETE FROM public.sensor_data    WHERE device_id = p_device_id;
    DELETE FROM public.cylinder_events WHERE device_id = p_device_id;

    UPDATE public.devices
       SET current_cycle = 1, expires_at = NULL, plan = 'free'
     WHERE device_id = p_device_id;

    RAISE NOTICE 'Datos eliminados para dispositivo con plan vencido: %', p_device_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.cleanup_device_data(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_device_data(text) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
;