-- 202608230001 · handover_to_client exige clave vigente
CREATE OR REPLACE FUNCTION public.handover_to_client(
    p_device_mac  text,
    p_current_key text DEFAULT NULL::text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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

    -- PARCHE 2026-08-23: sin clave vigente no se autoriza el handover.
    -- Antes, un equipo sin access_key podia perder user_email y user_phone
    -- a manos de cualquiera que conociera la MAC (dato publico en la URL).
    IF v_stored IS NULL THEN RETURN FALSE; END IF;

    IF private.es_hash_bcrypt(v_stored) THEN
        IF v_stored <> extensions.crypt(BTRIM(COALESCE(p_current_key, '')), v_stored) THEN
            RETURN FALSE;
        END IF;
    ELSIF v_stored <> BTRIM(COALESCE(p_current_key, '')) THEN
        RETURN FALSE;
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
$function$;;