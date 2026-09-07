-- El modelo "cambiar la clave exige codigo al correo" quedaba anulado por dos
-- caminos que solo pedian la clave actual:
--   reset_access_key   -> dejaba access_key en NULL, y con NULL set_access_key
--                         vuelve a aceptar un alta sin codigo.
--   handover_to_client -> borraba clave Y correo, permitiendo que quien supiera
--                         la clave registrara su propio correo y se quedara con
--                         el equipo de forma permanente.

ALTER TABLE private.access_recovery DROP CONSTRAINT IF EXISTS access_recovery_purpose_check;
ALTER TABLE private.access_recovery
    ADD CONSTRAINT access_recovery_purpose_check
    CHECK (purpose IN ('clave', 'correo', 'entrega'));

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
    v_purpose   TEXT := CASE
                          WHEN p_purpose = 'correo'  THEN 'correo'
                          WHEN p_purpose = 'entrega' THEN 'entrega'
                          ELSE 'clave'
                        END;
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

-- Entrega al cliente: borra clave, correo y telefono, pero solo contra un
-- codigo enviado al correo registrado (en fabrica, el del operario).
CREATE OR REPLACE FUNCTION public.handover_consume_code(
    p_device_mac text,
    p_code       text
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
BEGIN
    SELECT r.id, r.code_hash, r.expires_at, r.attempts
      INTO v_id, v_hash, v_exp, v_intentos
      FROM private.access_recovery r
     WHERE r.device_mac = p_device_mac
       AND r.purpose    = 'entrega'
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

    UPDATE public.devices
       SET access_key = NULL,
           user_email = NULL,
           user_phone = NULL
     WHERE device_mac = p_device_mac;

    -- Invalida TODOS los codigos vivos del equipo, incluido el recien usado:
    -- tras la entrega no debe quedar nada aprovechable del dueno anterior.
    UPDATE private.access_recovery
       SET used_at = NOW()
     WHERE device_mac = p_device_mac AND used_at IS NULL;

    RETURN 'ok';
END;
$function$;

-- anon ya no puede llamar a estos dos caminos directos.
REVOKE ALL ON FUNCTION public.reset_access_key(text,text)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.handover_to_client(text,text)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.handover_consume_code(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reset_access_key(text,text)     TO service_role;
GRANT EXECUTE ON FUNCTION public.handover_to_client(text,text)   TO service_role;
GRANT EXECUTE ON FUNCTION public.handover_consume_code(text,text) TO service_role;;