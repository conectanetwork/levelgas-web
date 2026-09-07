BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;

-- ── 0. Preflight ─────────────────────────────────────────────────────────────
DO $preflight$
BEGIN
    IF to_regclass('public.devices') IS NULL THEN
        RAISE EXCEPTION 'Preflight: falta public.devices.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='public' AND table_name='devices' AND column_name='access_key'
    ) THEN
        RAISE EXCEPTION 'Preflight: falta devices.access_key. Aplica antes 202608020001 o crea la columna.';
    END IF;
END;
$preflight$;

-- =============================================================================
-- 1. FUNCIONES DE ACCESO (la clave nunca sale de la base de datos)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.access_key_exists(p_device_mac TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT COALESCE(
        (SELECT NULLIF(BTRIM(d.access_key), '') IS NOT NULL
           FROM public.devices d
          WHERE d.device_mac = p_device_mac
          LIMIT 1),
        FALSE
    );
$$;

CREATE OR REPLACE FUNCTION public.verify_access_key(p_device_mac TEXT, p_key TEXT)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_stored TEXT;
    v_found  BOOLEAN := FALSE;
BEGIN
    SELECT NULLIF(BTRIM(d.access_key), ''), TRUE
      INTO v_stored, v_found
      FROM public.devices d
     WHERE d.device_mac = p_device_mac
     LIMIT 1;

    IF NOT COALESCE(v_found, FALSE) THEN
        RETURN 'sin_dispositivo';
    END IF;
    IF v_stored IS NULL THEN
        RETURN 'sin_clave_remota';
    END IF;
    IF length(v_stored) = length(COALESCE(BTRIM(p_key), ''))
       AND v_stored = BTRIM(p_key) THEN
        RETURN 'ok';
    END IF;
    RETURN 'no_coincide';
END;
$$;

CREATE OR REPLACE FUNCTION public.set_access_key(
    p_device_mac  TEXT,
    p_new_key     TEXT,
    p_current_key TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_stored TEXT;
    v_found  BOOLEAN := FALSE;
    v_new    TEXT    := BTRIM(COALESCE(p_new_key, ''));
BEGIN
    IF length(v_new) < 4 THEN
        RAISE EXCEPTION 'La clave debe tener al menos 4 caracteres.';
    END IF;

    SELECT NULLIF(BTRIM(d.access_key), ''), TRUE
      INTO v_stored, v_found
      FROM public.devices d
     WHERE d.device_mac = p_device_mac
     LIMIT 1;

    IF NOT COALESCE(v_found, FALSE) THEN
        RETURN FALSE;
    END IF;

    IF v_stored IS NOT NULL AND v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
        RETURN FALSE;
    END IF;

    UPDATE public.devices
       SET access_key = v_new
     WHERE device_mac = p_device_mac;

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.reset_access_key(
    p_device_mac  TEXT,
    p_current_key TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_stored TEXT;
    v_found  BOOLEAN := FALSE;
BEGIN
    SELECT NULLIF(BTRIM(d.access_key), ''), TRUE
      INTO v_stored, v_found
      FROM public.devices d
     WHERE d.device_mac = p_device_mac
     LIMIT 1;

    IF NOT COALESCE(v_found, FALSE) THEN
        RETURN FALSE;
    END IF;
    IF v_stored IS NULL THEN
        RETURN TRUE;
    END IF;
    IF v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
        RETURN FALSE;
    END IF;

    UPDATE public.devices SET access_key = NULL WHERE device_mac = p_device_mac;
    RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.access_key_exists(TEXT)        FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_access_key(TEXT, TEXT)  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_access_key(TEXT,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reset_access_key(TEXT,TEXT)    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.access_key_exists(TEXT)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_access_key(TEXT, TEXT)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_access_key(TEXT,TEXT,TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reset_access_key(TEXT,TEXT)    TO anon, authenticated;

-- =============================================================================
-- 2. LECTURA POR COLUMNAS: anon deja de poder leer access_key
-- =============================================================================
DO $grants_select$
DECLARE
    cols TEXT;
BEGIN
    SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'devices'
       AND column_name <> 'access_key';

    IF cols IS NULL THEN
        RAISE EXCEPTION 'No se pudieron enumerar las columnas de public.devices.';
    END IF;

    REVOKE SELECT ON public.devices FROM anon;
    EXECUTE format('GRANT SELECT (%s) ON public.devices TO anon', cols);
    RAISE NOTICE 'anon: SELECT concedido por columnas, access_key excluida.';
END;
$grants_select$;

-- =============================================================================
-- 3. ESCRITURA POR COLUMNAS: anon deja de poder tocar plan, vigencia ni clave
-- =============================================================================
DO $grants_update$
DECLARE
    cols TEXT;
BEGIN
    SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'devices'
       AND column_name NOT IN ('access_key', 'plan', 'expires_at', 'activated', 'account_id');

    IF cols IS NULL THEN
        RAISE EXCEPTION 'No se pudieron enumerar las columnas de public.devices.';
    END IF;

    REVOKE UPDATE ON public.devices FROM anon;
    EXECUTE format('GRANT UPDATE (%s) ON public.devices TO anon', cols);
    RAISE NOTICE 'anon: UPDATE concedido por columnas; plan, expires_at, activated, account_id y access_key bloqueadas.';
END;
$grants_update$;

-- =============================================================================
-- 4. BORRADO: anon deja de poder eliminar historial
-- =============================================================================
REVOKE DELETE ON public.sensor_data     FROM anon;
REVOKE DELETE ON public.cylinder_events FROM anon;

COMMIT;

NOTIFY pgrst, 'reload schema';
;