-- =============================================================================
-- LevelGas — Endurecimiento pre-lanzamiento (2026-08-22), parte 1/2
-- Ver migración anterior fallida para el detalle completo en comentarios.
-- =============================================================================

-- ── 1. Bug real: cleanup_retention_policy() comparaba TEXT con UUID ─────────
CREATE OR REPLACE FUNCTION public.cleanup_retention_policy()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
    rec          RECORD;
    cutoff_ts    TIMESTAMPTZ;
    deleted_rows INT;
    total_rows   INT := 0;
BEGIN
    FOR rec IN
        SELECT d.device_id AS device_id, d.plan AS plan, d.expires_at AS expires_at
        FROM public.devices d
        WHERE d.plan IS NOT NULL AND d.device_id IS NOT NULL
    LOOP
        CASE rec.plan
            WHEN 'free'    THEN cutoff_ts := NOW() - INTERVAL '7 days';
            WHEN 'hogar'   THEN cutoff_ts := NOW() - INTERVAL '30 days';
            WHEN 'empresa' THEN cutoff_ts := NOW() - INTERVAL '183 days';
            ELSE                cutoff_ts := NOW() - INTERVAL '7 days';
        END CASE;

        DELETE FROM public.sensor_data
        WHERE device_id = rec.device_id AND created_at < cutoff_ts;

        GET DIAGNOSTICS deleted_rows = ROW_COUNT;
        IF deleted_rows > 0 THEN
            total_rows := total_rows + deleted_rows;
            RAISE NOTICE 'device_id=% plan=% eliminados=% (cutoff=%)', rec.device_id, rec.plan, deleted_rows, cutoff_ts;
        END IF;
    END LOOP;

    FOR rec IN
        SELECT d.device_id AS device_id, d.plan AS plan, d.expires_at AS expires_at
        FROM public.devices d
        WHERE d.plan IN ('hogar', 'empresa') AND d.expires_at IS NOT NULL AND d.expires_at < NOW() AND d.device_id IS NOT NULL
    LOOP
        RAISE NOTICE 'Plan vencido: device_id=% plan=% expires_at=%', rec.device_id, rec.plan, rec.expires_at;

        DELETE FROM public.sensor_data WHERE device_id = rec.device_id;
        GET DIAGNOSTICS deleted_rows = ROW_COUNT;
        total_rows := total_rows + deleted_rows;

        DELETE FROM public.cylinder_events WHERE device_id = rec.device_id;

        UPDATE public.devices SET plan = 'free', expires_at = NULL, current_cycle = 1
        WHERE device_id = rec.device_id;

        RAISE NOTICE 'device_id=% degradado a Free, datos eliminados=%', rec.device_id, deleted_rows;
    END LOOP;

    RAISE NOTICE 'cleanup_retention_policy() completado. Total filas eliminadas: %', total_rows;
END;
$function$;

-- ── 2. Eliminar trigger roto con clave hardcodeada ───────────────────────────
DROP TRIGGER IF EXISTS check_alert_on_insert ON public.sensor_data;
DROP FUNCTION IF EXISTS public.trigger_alert_check();

-- ── 3. Limpiar funciones muertas/rotas de generaciones de esquema previas ───
DROP FUNCTION IF EXISTS public.cleanup_sensor_data_by_plan();
DROP FUNCTION IF EXISTS public.enforce_plan_expiration();
DROP FUNCTION IF EXISTS public.update_device_plan(text, text, integer);
DROP FUNCTION IF EXISTS public.detect_low_gas() CASCADE;
DROP FUNCTION IF EXISTS public.authenticate_device(text, text);
DROP FUNCTION IF EXISTS public.auto_register_device() CASCADE;

-- ── 4. search_path fijo en el resto de funciones señaladas por el linter ────
ALTER FUNCTION public.safe_increment_cycle(text)           SET search_path = 'public';
ALTER FUNCTION public.sync_cycle_to_last_data(text)         SET search_path = 'public';
ALTER FUNCTION public.update_last_seen()                    SET search_path = 'public';
ALTER FUNCTION public.get_device_storage_stats(text)        SET search_path = 'public';
ALTER FUNCTION public.assign_cycle_id()                      SET search_path = 'public';
ALTER FUNCTION public.fifo_free_plan_cleanup()               SET search_path = 'public';
ALTER FUNCTION public.cleanup_old_alerts()                   SET search_path = 'public';
ALTER FUNCTION public.update_consumo_diario()                SET search_path = 'public';
ALTER FUNCTION public.fn_update_device_on_sensor_insert()    SET search_path = 'public';

-- ── 5. cleanup-job (pg_cron) apuntaba a la función recién borrada ───────────
SELECT cron.unschedule('cleanup-job') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-job');

NOTIFY pgrst, 'reload schema';
;