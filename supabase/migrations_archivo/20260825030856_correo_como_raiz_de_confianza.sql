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

    -- Estado del cliente: hay correo, todo cambio pasa por codigo.
    IF v_email IS NOT NULL THEN
        RETURN 'requiere_codigo';
    END IF;

    -- Estado de fabrica: si ya hay clave, hay que conocerla para reemplazarla.
    IF v_stored IS NOT NULL THEN
        IF private.es_hash_bcrypt(v_stored) THEN
            IF v_stored <> extensions.crypt(BTRIM(COALESCE(p_current_key, '')), v_stored) THEN
                RETURN 'clave_actual_incorrecta';
            END IF;
        ELSIF v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
            RETURN 'clave_actual_incorrecta';
        END IF;
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

CREATE OR REPLACE FUNCTION public.factory_wipe_device(p_device_mac text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_filas INT := 0;
BEGIN
    UPDATE public.devices
       SET access_key = NULL,
           user_email = NULL,
           user_phone = NULL
     WHERE device_mac = p_device_mac;

    GET DIAGNOSTICS v_filas = ROW_COUNT;
    IF v_filas = 0 THEN RETURN FALSE; END IF;

    UPDATE private.access_recovery
       SET used_at = NOW()
     WHERE device_mac = p_device_mac AND used_at IS NULL;

    RETURN TRUE;
END;
$function$;

REVOKE ALL ON FUNCTION public.factory_wipe_device(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.factory_wipe_device(text) TO service_role;;