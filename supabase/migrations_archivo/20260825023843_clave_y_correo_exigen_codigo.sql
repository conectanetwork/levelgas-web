ALTER TABLE private.access_recovery
    ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'clave';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'access_recovery_purpose_check'
           AND conrelid = 'private.access_recovery'::regclass
    ) THEN
        ALTER TABLE private.access_recovery
            ADD CONSTRAINT access_recovery_purpose_check
            CHECK (purpose IN ('clave', 'correo'));
    END IF;
END $$;

DROP FUNCTION IF EXISTS public.recovery_issue_code(text, text, text, integer);

CREATE OR REPLACE FUNCTION public.recovery_issue_code(
    p_device_mac   text,
    p_code         text,
    p_email        text,
    p_ttl_minutes  integer DEFAULT 15,
    p_purpose      text    DEFAULT 'clave'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_recientes INT;
    v_purpose   TEXT := CASE WHEN p_purpose = 'correo' THEN 'correo' ELSE 'clave' END;
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
     WHERE device_mac = p_device_mac
       AND purpose    = v_purpose
       AND used_at IS NULL
       AND expires_at > NOW();

    INSERT INTO private.access_recovery (device_mac, code_hash, email_sent, expires_at, purpose)
    VALUES (
        p_device_mac,
        extensions.crypt(p_code, extensions.gen_salt('bf')),
        p_email,
        NOW() + make_interval(mins => GREATEST(1, LEAST(60, p_ttl_minutes))),
        v_purpose
    );

    DELETE FROM private.access_recovery
     WHERE expires_at < NOW() - INTERVAL '1 day';

    RETURN 'ok';
END;
$function$;

CREATE OR REPLACE FUNCTION public.recovery_consume_code(
    p_device_mac text,
    p_code       text,
    p_new_key    text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
       AND r.purpose    = 'clave'
       AND r.used_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 1;

    IF v_id IS NULL      THEN RETURN 'codigo_invalido';     END IF;
    IF v_exp < NOW()     THEN RETURN 'codigo_expirado';     END IF;
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
$function$;

CREATE OR REPLACE FUNCTION public.recovery_consume_email_change(
    p_device_mac text,
    p_code       text,
    p_new_email  text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_id       BIGINT;
    v_hash     TEXT;
    v_exp      TIMESTAMPTZ;
    v_intentos INT;
    v_mail     TEXT := lower(BTRIM(COALESCE(p_new_email, '')));
BEGIN
    IF v_mail = '' OR v_mail !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RETURN 'correo_invalido';
    END IF;

    SELECT r.id, r.code_hash, r.expires_at, r.attempts
      INTO v_id, v_hash, v_exp, v_intentos
      FROM private.access_recovery r
     WHERE r.device_mac = p_device_mac
       AND r.purpose    = 'correo'
       AND r.used_at IS NULL
     ORDER BY r.created_at DESC
     LIMIT 1;

    IF v_id IS NULL      THEN RETURN 'codigo_invalido';     END IF;
    IF v_exp < NOW()     THEN RETURN 'codigo_expirado';     END IF;
    IF v_intentos >= 5   THEN RETURN 'demasiados_intentos'; END IF;

    UPDATE private.access_recovery SET attempts = attempts + 1 WHERE id = v_id;

    IF v_hash <> extensions.crypt(BTRIM(COALESCE(p_code, '')), v_hash) THEN
        RETURN 'codigo_invalido';
    END IF;

    UPDATE private.access_recovery SET used_at = NOW() WHERE id = v_id;

    UPDATE public.devices
       SET user_email = v_mail
     WHERE device_mac = p_device_mac;

    RETURN 'ok';
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_access_key(
    p_device_mac      text,
    p_new_key         text,
    p_current_key     text DEFAULT NULL::text,
    p_recovery_email  text DEFAULT NULL::text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
        RETURN 'requiere_codigo';
    END IF;

    IF v_email IS NULL AND v_mail = '' THEN
        RETURN 'correo_requerido';
    END IF;

    IF v_mail <> '' AND v_mail !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
        RETURN 'correo_invalido';
    END IF;

    UPDATE public.devices
       SET access_key = extensions.crypt(v_new, extensions.gen_salt('bf')),
           user_email = COALESCE(user_email, NULLIF(v_mail, ''))
     WHERE device_mac = p_device_mac;

    RETURN 'ok';
END;
$function$;

REVOKE ALL ON FUNCTION public.recovery_issue_code(text,text,text,integer,text)   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recovery_consume_code(text,text,text)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.recovery_consume_email_change(text,text,text)      FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recovery_issue_code(text,text,text,integer,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.recovery_consume_code(text,text,text)            TO service_role;
GRANT EXECUTE ON FUNCTION public.recovery_consume_email_change(text,text,text)    TO service_role;;