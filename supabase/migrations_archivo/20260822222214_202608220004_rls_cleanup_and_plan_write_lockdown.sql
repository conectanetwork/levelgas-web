-- =============================================================================
-- LevelGas — Limpieza de RLS y cierre del hueco de escritura de planes
-- Migración 202608220004 (ver comentario extenso en el intento anterior)
-- =============================================================================

-- ── 1. devices ────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "open_devices"               ON public.devices;
DROP POLICY IF EXISTS "user owns device"            ON public.devices;
DROP POLICY IF EXISTS "allow device select"         ON public.devices;
DROP POLICY IF EXISTS "allow_anon_update_contact"   ON public.devices;

CREATE POLICY devices_update_anon ON public.devices
    FOR UPDATE TO anon, authenticated
    USING (true) WITH CHECK (true);

-- ── 2. sensor_data ────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "open_data"               ON public.sensor_data;
DROP POLICY IF EXISTS "public read"             ON public.sensor_data;
DROP POLICY IF EXISTS "anon_select_sensor_data" ON public.sensor_data;
DROP POLICY IF EXISTS "user sees data"          ON public.sensor_data;
DROP POLICY IF EXISTS "user sees device data"   ON public.sensor_data;
DROP POLICY IF EXISTS "service_insert_sensor_data" ON public.sensor_data;
DROP POLICY IF EXISTS "allow_anon_delete_sensor"   ON public.sensor_data;

-- ── 3. cylinder_events ────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Allow insert cylinder events"    ON public.cylinder_events;
DROP POLICY IF EXISTS "allow_anon_delete_events"        ON public.cylinder_events;
DROP POLICY IF EXISTS "service_update_cylinder_events"  ON public.cylinder_events;

-- ── 4. user_plans / subscriptions ────────────────────────────────────────
DROP POLICY IF EXISTS "anon_select_user_plans"    ON public.user_plans;
DROP POLICY IF EXISTS "Users can view subscriptions" ON public.subscriptions;

-- ── 5. Bloqueo a nivel de columna de los campos de negocio en devices ───────
REVOKE UPDATE (plan, expires_at, activated, current_cycle, user_id)
    ON public.devices FROM anon, authenticated;

-- ── 6. Nuevo RPC: degradar el propio plan a Free requiere el access_key ─────
CREATE OR REPLACE FUNCTION public.self_downgrade_to_free(p_device_mac text, p_access_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_check TEXT;
BEGIN
    v_check := public.verify_access_key(p_device_mac, p_access_key);
    IF v_check <> 'ok' THEN
        RETURN jsonb_build_object('ok', false, 'msg', v_check);
    END IF;

    UPDATE public.devices
       SET plan = 'free', expires_at = NULL, current_cycle = 1
     WHERE device_mac = p_device_mac;

    RETURN jsonb_build_object('ok', true, 'msg', 'downgraded');
END;
$function$;

REVOKE ALL ON FUNCTION public.self_downgrade_to_free(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.self_downgrade_to_free(text, text) TO anon, authenticated;

-- ── 7. Índices: PK faltante, FK sin índice, constraints únicos duplicados ───
ALTER TABLE public.cylinder_events ADD COLUMN IF NOT EXISTS event_pk BIGINT GENERATED ALWAYS AS IDENTITY;
ALTER TABLE public.cylinder_events ADD PRIMARY KEY (event_pk);

CREATE INDEX IF NOT EXISTS idx_subscriptions_device_id ON public.subscriptions (device_id);

ALTER TABLE public.devices DROP CONSTRAINT IF EXISTS unique_activation_key;
ALTER TABLE public.devices DROP CONSTRAINT IF EXISTS devices_mac_unique;
ALTER TABLE public.devices DROP CONSTRAINT IF EXISTS unique_device_mac;

-- ── 8. Perf: evitar re-evaluar auth.role() por fila en device_alerts ────────
DROP POLICY IF EXISTS "service_role_only" ON public.device_alerts;
CREATE POLICY service_role_only ON public.device_alerts
    FOR ALL TO public
    USING ((SELECT auth.role()) = 'service_role')
    WITH CHECK ((SELECT auth.role()) = 'service_role');

NOTIFY pgrst, 'reload schema';
;