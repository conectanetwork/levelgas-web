BEGIN;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ── 0. Preflight ─────────────────────────────────────────────────────────────
DO $preflight$
BEGIN
    IF to_regclass('public.devices') IS NULL THEN
        RAISE EXCEPTION 'Preflight: falta public.devices.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='devices' AND column_name='access_key') THEN
        RAISE EXCEPTION 'Preflight: falta devices.access_key.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name='devices' AND column_name='user_email') THEN
        RAISE EXCEPTION 'Preflight: falta devices.user_email. Aplica antes 202608020001 o crea la columna.';
    END IF;
    IF to_regprocedure('public.verify_access_key(text,text)') IS NULL THEN
        RAISE EXCEPTION 'Preflight: falta verify_access_key. Aplica antes 202608100002.';
    END IF;
END;
$preflight$;

-- =============================================================================
-- 1. ALMACÉN DE CÓDIGOS DE RECUPERACIÓN
-- =============================================================================
CREATE TABLE IF NOT EXISTS private.access_recovery (
    id          BIGSERIAL   PRIMARY KEY,
    device_mac  TEXT        NOT NULL,
    code_hash   TEXT        NOT NULL,
    email_sent  TEXT        NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ,
    attempts    INT         NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_access_recovery_mac_created
    ON private.access_recovery (device_mac, created_at DESC);

REVOKE ALL ON private.access_recovery FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 2. HASHEO DE access_key — MODO DUAL
-- =============================================================================
CREATE OR REPLACE FUNCTION private.es_hash_bcrypt(p_valor TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
    SELECT p_valor IS NOT NULL AND left(p_valor, 2) = '$2';
$$;

CREATE OR REPLACE FUNCTION public.verify_access_key(p_device_mac TEXT, p_key TEXT)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_stored TEXT;
    v_found  BOOLEAN := FALSE;
    v_key    TEXT    := BTRIM(COALESCE(p_key, ''));
BEGIN
    SELECT NULLIF(BTRIM(d.access_key), ''), TRUE
      INTO v_stored, v_found
      FROM public.devices d
     WHERE d.device_mac = p_device_mac
     LIMIT 1;

    IF NOT COALESCE(v_found, FALSE) THEN RETURN 'sin_dispositivo';  END IF;
    IF v_stored IS NULL              THEN RETURN 'sin_clave_remota'; END IF;

    IF private.es_hash_bcrypt(v_stored) THEN
        IF v_stored = extensions.crypt(v_key, v_stored) THEN
            RETURN 'ok';
        END IF;
        RETURN 'no_coincide';
    END IF;

    IF length(v_stored) = length(v_key) AND v_stored = v_key THEN
        UPDATE public.devices
           SET access_key = extensions.crypt(v_key, extensions.gen_salt('bf'))
         WHERE device_mac = p_device_mac;
        RETURN 'ok';
    END IF;
    RETURN 'no_coincide';
END;
$$;

-- =============================================================================
-- 3. CREAR / CAMBIAR CLAVE — AHORA CON CORREO DE RECUPERACIÓN OBLIGATORIO
-- =============================================================================
DROP FUNCTION IF EXISTS public.set_access_key(TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.set_access_key(
    p_device_mac     TEXT,
    p_new_key        TEXT,
    p_current_key    TEXT DEFAULT NULL,
    p_recovery_email TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_stored TEXT;
    v_email  TEXT;
    v_found  BOOLEAN := FALSE;
    v_new    TEXT    := BTRIM(COALESCE(p_new_key, ''));
    v_mail   TEXT    := lower(BTRIM(COALESCE(p_recovery_email, '')));
BEGIN
    IF length(v_new) < 4 THEN RETURN 'clave_corta'; END IF;

    SELECT NULLIF(BTRIM(d.access_key), ''), NULLIF(BTRIM(d.user_email), ''), TRUE
      INTO v_stored, v_email, v_found
      FROM public.devices d
     WHERE d.device_mac = p_device_mac
     LIMIT 1;

    IF NOT COALESCE(v_found, FALSE) THEN RETURN 'sin_dispositivo'; END IF;

    IF v_stored IS NOT NULL THEN
        IF private.es_hash_bcrypt(v_stored) THEN
            IF v_stored <> extensions.crypt(BTRIM(COALESCE(p_current_key,'')), v_stored) THEN
                RETURN 'clave_actual_incorrecta';
            END IF;
        ELSIF v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
            RETURN 'clave_actual_incorrecta';
        END IF;
    END IF;

    IF v_stored IS NULL AND v_email IS NULL THEN
        IF v_mail = '' THEN RETURN 'correo_requerido'; END IF;
    END IF;

    IF v_mail <> '' AND v_mail !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RETURN 'correo_invalido';
    END IF;

    UPDATE public.devices
       SET access_key = extensions.crypt(v_new, extensions.gen_salt('bf')),
           user_email = COALESCE(NULLIF(v_mail, ''), user_email)
     WHERE device_mac = p_device_mac;

    RETURN 'ok';
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

    IF NOT COALESCE(v_found, FALSE) THEN RETURN FALSE; END IF;
    IF v_stored IS NULL              THEN RETURN TRUE;  END IF;

    IF private.es_hash_bcrypt(v_stored) THEN
        IF v_stored <> extensions.crypt(BTRIM(COALESCE(p_current_key,'')), v_stored) THEN
            RETURN FALSE;
        END IF;
    ELSIF v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
        RETURN FALSE;
    END IF;

    UPDATE public.devices SET access_key = NULL WHERE device_mac = p_device_mac;
    RETURN TRUE;
END;
$$;

-- =============================================================================
-- 4. ¿ESTE EQUIPO TIENE CORREO DE RECUPERACIÓN?
-- =============================================================================
CREATE OR REPLACE FUNCTION public.recovery_email_hint(p_device_mac TEXT)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_email TEXT;
    v_user  TEXT;
    v_dom   TEXT;
BEGIN
    SELECT NULLIF(BTRIM(d.user_email), '') INTO v_email
      FROM public.devices d WHERE d.device_mac = p_device_mac LIMIT 1;

    IF v_email IS NULL THEN RETURN NULL; END IF;

    v_user := split_part(v_email, '@', 1);
    v_dom  := split_part(v_email, '@', 2);
    IF length(v_user) <= 2 THEN
        RETURN left(v_user, 1) || '***@' || v_dom;
    END IF;
    RETURN left(v_user, 1) || repeat('*', 3) || right(v_user, 1) || '@' || v_dom;
END;
$$;

-- =============================================================================
-- 4b. ENTREGA AL CLIENTE — RESET DE FÁBRICA DE CLAVE Y CORREO
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handover_to_client(
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

    IF NOT COALESCE(v_found, FALSE) THEN RETURN FALSE; END IF;

    IF v_stored IS NOT NULL THEN
        IF private.es_hash_bcrypt(v_stored) THEN
            IF v_stored <> extensions.crypt(BTRIM(COALESCE(p_current_key,'')), v_stored) THEN
                RETURN FALSE;
            END IF;
        ELSIF v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
            RETURN FALSE;
        END IF;
    END IF;

    UPDATE public.devices
       SET access_key = NULL,
           user_email = NULL,
           user_phone = NULL
     WHERE device_mac = p_device_mac;

    UPDATE private.access_recovery
       SET used_at = NOW()
     WHERE device_mac = p_device_mac AND used_at IS NULL;

    RETURN TRUE;
END;
$$;

-- =============================================================================
-- 5. PUENTE PARA LA EDGE FUNCTION
-- =============================================================================
CREATE OR REPLACE FUNCTION public.recovery_issue_code(
    p_device_mac  TEXT,
    p_code        TEXT,
    p_email       TEXT,
    p_ttl_minutes INT DEFAULT 15
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_recientes INT;
BEGIN
    SELECT count(*) INTO v_recientes
      FROM private.access_recovery r
     WHERE r.device_mac = p_device_mac
       AND r.created_at > NOW() - INTERVAL '1 hour';

    IF v_recientes >= 3 THEN
        RETURN 'limite_excedido';
    END IF;

    UPDATE private.access_recovery
       SET used_at = NOW()
     WHERE device_mac = p_device_mac AND used_at IS NULL AND expires_at > NOW();

    INSERT INTO private.access_recovery (device_mac, code_hash, email_sent, expires_at)
    VALUES (
        p_device_mac,
        extensions.crypt(p_code, extensions.gen_salt('bf')),
        p_email,
        NOW() + make_interval(mins => GREATEST(1, LEAST(60, p_ttl_minutes)))
    );

    DELETE FROM private.access_recovery
     WHERE expires_at < NOW() - INTERVAL '1 day';

    RETURN 'ok';
END;
$$;

CREATE OR REPLACE FUNCTION public.recovery_consume_code(
    p_device_mac TEXT,
    p_code       TEXT,
    p_new_key    TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_id       BIGINT;
    v_hash     TEXT;
    v_exp      TIMESTAMPTZ;
    v_intentos INT;
    v_new      TEXT := BTRIM(COALESCE(p_new_key, ''));
BEGIN
    IF length(v_new) < 4 THEN RETURN 'clave_corta'; END IF;

    SELECT r.id, r.code_hash, r.expires_at, r.attempts
      INTO v_id, v_hash, v_exp, v_intentos
      FROM private.access_recovery r
     WHERE r.device_mac = p_device_mac
       AND r.used_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 1;

    IF v_id IS NULL      THEN RETURN 'codigo_invalido';  END IF;
    IF v_exp < NOW()     THEN RETURN 'codigo_expirado';  END IF;
    IF v_intentos >= 5   THEN RETURN 'demasiados_intentos'; END IF;

    UPDATE private.access_recovery SET attempts = attempts + 1 WHERE id = v_id;

    IF v_hash <> extensions.crypt(BTRIM(COALESCE(p_code, '')), v_hash) THEN
        RETURN 'codigo_invalido';
    END IF;

    UPDATE private.access_recovery SET used_at = NOW() WHERE id = v_id;

    UPDATE public.devices
       SET access_key = extensions.crypt(v_new, extensions.gen_salt('bf'))
     WHERE device_mac = p_device_mac;

    RETURN 'ok';
END;
$$;

-- =============================================================================
-- 6. PERMISOS
-- =============================================================================
REVOKE ALL ON FUNCTION public.set_access_key(TEXT,TEXT,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.recovery_email_hint(TEXT)           FROM PUBLIC;
REVOKE ALL ON FUNCTION private.es_hash_bcrypt(TEXT)               FROM PUBLIC;

REVOKE ALL ON FUNCTION public.handover_to_client(TEXT,TEXT)          FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_access_key(TEXT,TEXT,TEXT,TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recovery_email_hint(TEXT)           TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.handover_to_client(TEXT,TEXT)       TO anon, authenticated;

REVOKE ALL ON FUNCTION public.recovery_issue_code(TEXT,TEXT,TEXT,INT)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recovery_consume_code(TEXT,TEXT,TEXT)    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recovery_issue_code(TEXT,TEXT,TEXT,INT) TO service_role;
GRANT EXECUTE ON FUNCTION public.recovery_consume_code(TEXT,TEXT,TEXT)   TO service_role;

COMMIT;

NOTIFY pgrst, 'reload schema';
;