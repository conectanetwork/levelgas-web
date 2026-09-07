--
-- PostgreSQL database dump
--

\restrict vXgwMjfnVe1KsOpYrcXGeuRvHZfwW9SWoImLIJnXUgyanqfo4KKfewhjyHKZosW

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: private; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA private;


--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: es_hash_bcrypt(text); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.es_hash_bcrypt(p_valor text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $_$
    SELECT p_valor IS NOT NULL AND left(p_valor, 2) = '$2';
$_$;


--
-- Name: access_key_exists(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.access_key_exists(p_device_mac text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT COALESCE(
        (SELECT NULLIF(BTRIM(d.access_key), '') IS NOT NULL
           FROM public.devices d
          WHERE d.device_mac = p_device_mac
          LIMIT 1),
        FALSE
    );
$$;


--
-- Name: assign_cycle_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_cycle_id() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN

  SELECT current_cycle
  INTO NEW.cycle_id
  FROM devices
  WHERE device_id = NEW.device_id
  LIMIT 1;

  RETURN NEW;

END;
$$;


--
-- Name: cleanup_device_data(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_device_data(p_device_id text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: cleanup_expired_plans(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_expired_plans() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    rec RECORD;
    total_deleted INT := 0;
    rows_deleted  INT;
BEGIN
    -- Iterar sobre todos los dispositivos con plan expirado
    FOR rec IN
        SELECT device_id, plan, expires_at
        FROM devices
        WHERE plan IN ('hogar','empresa')
          AND expires_at IS NOT NULL
          AND expires_at < NOW()
    LOOP
        -- Eliminar sensor_data
        DELETE FROM sensor_data WHERE device_id = rec.device_id;
        GET DIAGNOSTICS rows_deleted = ROW_COUNT;
        total_deleted := total_deleted + rows_deleted;

        -- Eliminar cylinder_events
        DELETE FROM cylinder_events WHERE device_id = rec.device_id;

        -- Resetear dispositivo
        UPDATE devices
        SET plan          = 'free',
            current_cycle = 1,
            expires_at    = NULL
        WHERE device_id = rec.device_id;

        RAISE NOTICE 'Limpiado: % (plan %, % lecturas eliminadas)',
                     rec.device_id, rec.plan, rows_deleted;
    END LOOP;

    RAISE NOTICE 'Limpieza completada. Total lecturas eliminadas: %', total_deleted;
END;
$$;


--
-- Name: cleanup_old_alerts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_old_alerts() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    DELETE FROM device_alerts WHERE sent_at < NOW() - INTERVAL '7 days';
  $$;


--
-- Name: cleanup_retention_policy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_retention_policy() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: devices_mac_inmutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.devices_mac_inmutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if current_user in ('anon','authenticated')
     and NEW.device_mac is distinct from OLD.device_mac then
    raise exception 'device_mac es inmutable (intento: % → %)', OLD.device_mac, NEW.device_mac
      using errcode = '42501';
  end if;
  return NEW;
end;
$$;


--
-- Name: factory_wipe_device(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.factory_wipe_device(p_device_mac text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: fifo_free_plan_cleanup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fifo_free_plan_cleanup() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    dev_plan    TEXT;
    oldest_id   BIGINT;
    cutoff_ts   TIMESTAMPTZ;
BEGIN
    SELECT plan INTO dev_plan
    FROM public.devices
    WHERE device_id = NEW.device_id;

    IF dev_plan = 'free' THEN
        cutoff_ts := NOW() - INTERVAL '7 days';

        SELECT id INTO oldest_id
        FROM public.sensor_data
        WHERE device_id = NEW.device_id
          AND created_at < cutoff_ts
        ORDER BY created_at ASC
        LIMIT 1;

        IF oldest_id IS NOT NULL THEN
            DELETE FROM public.sensor_data WHERE id = oldest_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: fn_free_plan_fifo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_free_plan_fifo() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    -- Solo actúa si el dispositivo tiene plan FREE
    IF EXISTS (
        SELECT 1
        FROM   devices
        WHERE  device_id = NEW.device_id
        AND    plan = 'free'
    ) THEN
        -- Retener últimos 7 días (antes era 24h)
        -- El gráfico diario filtra a 24h en el JS — independiente de esto
        DELETE FROM sensor_data
        WHERE  device_id  = NEW.device_id
        AND    created_at < (NOW() - INTERVAL '7 days');
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: fn_update_device_on_sensor_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_update_device_on_sensor_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE devices
  SET
    last_seen_at       = NOW(),
    battery_percentage = COALESCE(NEW.battery_percentage, battery_percentage),
    battery_voltage    = COALESCE(NEW.battery_voltage,    battery_voltage)
  WHERE device_mac = NEW.device_mac;

  RETURN NEW;
END;
$$;


--
-- Name: get_device_storage_stats(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_device_storage_stats(p_device_id text DEFAULT NULL::text) RETURNS TABLE(device_id text, plan_type text, retention_days integer, current_records bigint, oldest_record timestamp with time zone, newest_record timestamp with time zone, storage_usage_kb numeric)
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        sd.device_id,
        COALESCE(dp.plan_type, 'free') as plan_type,
        COALESCE(dp.retention_days, 2) as retention_days,
        COUNT(sd.*) as current_records,
        MIN(sd.timestamp) as oldest_record,
        MAX(sd.timestamp) as newest_record,
        ROUND((COUNT(sd.*) * 0.05)::NUMERIC, 2) as storage_usage_kb  -- ~50 bytes por registro
    FROM sensor_data sd
    LEFT JOIN device_plans dp ON sd.device_id = dp.device_id
    WHERE (p_device_id IS NULL OR sd.device_id = p_device_id)
    GROUP BY sd.device_id, dp.plan_type, dp.retention_days
    ORDER BY current_records DESC;
END;
$$;


--
-- Name: handover_consume_code(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handover_consume_code(p_device_mac text, p_code text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: handover_to_client(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handover_to_client(p_device_mac text, p_current_key text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
$$;


--
-- Name: recovery_consume_code(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recovery_consume_code(p_device_mac text, p_code text, p_new_key text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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
$$;


--
-- Name: recovery_consume_email_change(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recovery_consume_email_change(p_device_mac text, p_code text, p_new_email text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
$_$;


--
-- Name: recovery_email_hint(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recovery_email_hint(p_device_mac text) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
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


--
-- Name: recovery_issue_code(text, text, text, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recovery_issue_code(p_device_mac text, p_code text, p_email text, p_ttl_minutes integer DEFAULT 15, p_purpose text DEFAULT 'clave'::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: reset_access_key(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_access_key(p_device_mac text, p_current_key text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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


--
-- Name: reset_cylinder_history(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_cylinder_history(p_device_mac text, p_access_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: safe_increment_cycle(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.safe_increment_cycle(p_device_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_current_cycle INTEGER;
    v_tiene_datos   BOOLEAN;
    v_nuevo_ciclo   INTEGER;
BEGIN
    SELECT current_cycle INTO v_current_cycle
    FROM   public.devices
    WHERE  device_id = p_device_id
    LIMIT  1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'msg', 'device_not_found');
    END IF;

    -- ¿El ciclo actual tiene al menos 1 dato del sensor?
    SELECT EXISTS (
        SELECT 1 FROM public.sensor_data
        WHERE  device_id = p_device_id
          AND  cycle_id  = v_current_cycle
    ) INTO v_tiene_datos;

    -- Sin datos en el ciclo actual → no incrementar
    IF NOT v_tiene_datos THEN
        RETURN jsonb_build_object(
            'ok',    false,
            'cycle', v_current_cycle,
            'msg',   'pending_confirmation'
        );
    END IF;

    -- Ciclo confirmado → incrementar
    v_nuevo_ciclo := v_current_cycle + 1;
    UPDATE public.devices
    SET    current_cycle = v_nuevo_ciclo
    WHERE  device_id     = p_device_id;

    RETURN jsonb_build_object(
        'ok',    true,
        'cycle', v_nuevo_ciclo,
        'msg',   'ok'
    );
END;
$$;


--
-- Name: self_downgrade_to_free(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.self_downgrade_to_free(p_device_mac text, p_access_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
$$;


--
-- Name: set_access_key(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_access_key(p_device_mac text, p_new_key text, p_current_key text DEFAULT NULL::text, p_recovery_email text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
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
$_$;


--
-- Name: set_recovery_contact(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_recovery_contact(p_device_mac text, p_email text, p_phone text DEFAULT NULL::text, p_access_key text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare
    v_stored text;
    v_email  text;
    v_found  boolean := false;
    v_mail   text := lower(btrim(coalesce(p_email, '')));
    v_phone  text := nullif(btrim(coalesce(p_phone, '')), '');
    v_key    text := btrim(coalesce(p_access_key, ''));
begin
    if v_mail !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        return 'correo_invalido';
    end if;

    select nullif(btrim(d.access_key), ''), nullif(btrim(d.user_email), ''), true
      into v_stored, v_email, v_found
      from public.devices d
     where d.device_mac = p_device_mac
     limit 1;

    if not coalesce(v_found, false) then
        return 'sin_dispositivo';
    end if;

    if v_stored is not null then
        -- El equipo ya tiene clave: hay que conocerla, tanto para fijar el correo
        -- por primera vez como para reemplazarlo. Soporta hash bcrypt y el
        -- formato antiguo en texto plano, igual que set_access_key.
        if v_key = '' then
            return 'requiere_clave';
        end if;

        if private.es_hash_bcrypt(v_stored) then
            if v_stored <> extensions.crypt(v_key, v_stored) then
                return 'clave_actual_incorrecta';
            end if;
        elsif v_stored <> v_key then
            return 'clave_actual_incorrecta';
        end if;
    else
        -- Estado de fábrica (sin clave). Solo se permite el PRIMER registro.
        if v_email is not null then
            return 'requiere_codigo';
        end if;
    end if;

    update public.devices
       set user_email = v_mail,
           user_phone = coalesce(v_phone, user_phone)
     where device_mac = p_device_mac;

    return 'ok';
end;
$_$;


--
-- Name: FUNCTION set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text) IS 'Fija el correo/telefono de recuperacion validando la clave de acceso server-side. Reemplaza el UPDATE directo de anon sobre devices.user_email (paso 0, 2026-09-06).';


--
-- Name: sync_cycle_to_last_data(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_cycle_to_last_data(p_device_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_last_cycle    INTEGER;
    v_current_cycle INTEGER;
BEGIN
    -- Ciclo más reciente que tiene datos reales
    SELECT cycle_id INTO v_last_cycle
    FROM   public.sensor_data
    WHERE  device_id = p_device_id
    ORDER  BY created_at DESC
    LIMIT  1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'cycle', 1, 'msg', 'no_data');
    END IF;

    -- Obtener ciclo actual
    SELECT current_cycle INTO v_current_cycle
    FROM   public.devices WHERE device_id = p_device_id LIMIT 1;

    -- Si ya están sincronizados, no hacer nada
    IF v_current_cycle = v_last_cycle THEN
        RETURN jsonb_build_object('ok', true, 'cycle', v_last_cycle, 'msg', 'already_synced');
    END IF;

    -- Retroceder current_cycle al último con datos
    UPDATE public.devices
    SET    current_cycle = v_last_cycle
    WHERE  device_id     = p_device_id;

    RETURN jsonb_build_object(
        'ok',    true,
        'cycle', v_last_cycle,
        'msg',   'synced'
    );
END;
$$;


--
-- Name: update_consumo_diario(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_consumo_diario() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  dev     record;
  v_desde timestamp;
  v_g     numeric;
  v_n     int;
  v_dias  numeric;
begin
  for dev in select distinct device_id from public.sensor_data where device_id is not null loop

    -- Ventana preferida: desde el último cambio de cilindro registrado.
    select max(created_at) + interval '15 seconds'
      into v_desde
      from public.cylinder_events
     where device_id = dev.device_id and event_type = 'cylinder_change';

    v_desde := greatest(coalesce(v_desde, now() - interval '14 days'),
                        now() - interval '14 days');

    select count(*),
           extract(epoch from (max(created_at) - min(created_at))) / 86400.0
      into v_n, v_dias
      from public.sensor_data
     where device_id = dev.device_id and created_at >= v_desde;

    -- Cilindro demasiado nuevo para una muestra útil → ampliar la ventana.
    if coalesce(v_n,0) < 4 or coalesce(v_dias,0) < 1 then
      v_desde := now() - interval '14 days';
    end if;

    with lect as (
      select created_at, weight,
             lag(weight) over (order by created_at) as prev_w
        from public.sensor_data
       where device_id = dev.device_id and created_at >= v_desde
    ),
    agg as (
      select coalesce(sum(greatest(0, prev_w - weight)), 0) as caida,
             extract(epoch from (max(created_at) - min(created_at))) / 86400.0 as dias,
             count(*) as n
        from lect
    )
    select case when n >= 2 and dias > 0.25 and caida > 0 then (caida * 1000) / dias end
      into v_g from agg;

    if v_g is not null and v_g > 0 then
      update public.devices
         set consumo_diario_g = v_g, consumo_updated_at = now()
       where device_id = dev.device_id;
    end if;

  end loop;
end;
$$;


--
-- Name: update_last_seen(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_last_seen() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  -- Las ediciones del dashboard (correo, teléfono, pesos, clave) NO deben
  -- resetear el reloj de obsolescencia: si lo hacen, una báscula muerta
  -- aparece como viva en el mapa de reposición.
  if NEW.battery_percentage is distinct from OLD.battery_percentage
     or NEW.battery_voltage is distinct from OLD.battery_voltage
     or NEW.firmware        is distinct from OLD.firmware
     or NEW.wifi_ssid       is distinct from OLD.wifi_ssid
     or NEW.sensor_ok       is distinct from OLD.sensor_ok
  then
    NEW.last_seen_at = now();
  end if;
  return NEW;
end;
$$;


--
-- Name: verify_access_key(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_access_key(p_device_mac text, p_key text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: access_recovery; Type: TABLE; Schema: private; Owner: -
--

CREATE TABLE private.access_recovery (
    id bigint NOT NULL,
    device_mac text NOT NULL,
    code_hash text NOT NULL,
    email_sent text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    purpose text DEFAULT 'clave'::text NOT NULL,
    CONSTRAINT access_recovery_purpose_check CHECK ((purpose = ANY (ARRAY['clave'::text, 'correo'::text, 'entrega'::text])))
);


--
-- Name: access_recovery_id_seq; Type: SEQUENCE; Schema: private; Owner: -
--

CREATE SEQUENCE private.access_recovery_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: access_recovery_id_seq; Type: SEQUENCE OWNED BY; Schema: private; Owner: -
--

ALTER SEQUENCE private.access_recovery_id_seq OWNED BY private.access_recovery.id;


--
-- Name: cylinder_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cylinder_events (
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    device_id text,
    event_type text,
    old_weight real,
    new_weight real,
    id uuid,
    notes text,
    event_pk bigint NOT NULL
);


--
-- Name: cylinder_events_event_pk_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.cylinder_events ALTER COLUMN event_pk ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.cylinder_events_event_pk_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: device_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_alerts (
    id bigint NOT NULL,
    device_id text NOT NULL,
    alert_type text NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL,
    email_ok boolean DEFAULT false NOT NULL,
    sms_ok boolean DEFAULT false NOT NULL,
    CONSTRAINT device_alerts_alert_type_check CHECK ((alert_type = ANY (ARRAY['gas'::text, 'battery'::text, 'gas_bat'::text])))
);


--
-- Name: device_alerts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_alerts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_alerts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_alerts_id_seq OWNED BY public.device_alerts.id;


--
-- Name: device_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_config (
    id bigint NOT NULL,
    device_mac text NOT NULL,
    container_name text DEFAULT 'Contenedor'::text,
    empty_weight numeric DEFAULT 0,
    full_weight numeric DEFAULT 15,
    unit text DEFAULT 'kg'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    alert_threshold numeric DEFAULT 20
);


--
-- Name: device_config_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.device_config ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.device_config_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    device_mac text NOT NULL,
    activation_key text,
    activated boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    activated_at timestamp with time zone,
    firmware text,
    device_id text,
    expires_at timestamp without time zone,
    full_weight numeric,
    empty_weight numeric,
    current_cycle integer DEFAULT 1,
    phone text,
    email text,
    consumo_diario_g numeric,
    consumo_updated_at timestamp with time zone,
    last_calibration jsonb,
    battery_percentage integer,
    battery_voltage numeric(5,3),
    last_seen_at timestamp with time zone DEFAULT now(),
    wifi_ssid text,
    access_key text,
    plan text DEFAULT 'free'::text NOT NULL,
    user_email text,
    user_phone text,
    sensor_ok boolean DEFAULT true
);


--
-- Name: COLUMN devices.wifi_ssid; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.devices.wifi_ssid IS 'SSID al que estaba conectada la báscula en el último heartbeat (diagnóstico).';


--
-- Name: COLUMN devices.access_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.devices.access_key IS 'Clave de acceso del dashboard LevelGas para sincronizar el acceso entre terminales.';


--
-- Name: COLUMN devices.sensor_ok; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.devices.sensor_ok IS 'FALSE si el firmware no obtuvo lectura válida del HX711 en su último ciclo.';


--
-- Name: sensor_daily_summary; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sensor_daily_summary (
    id bigint NOT NULL,
    device_id text NOT NULL,
    day date NOT NULL,
    min_weight numeric,
    max_weight numeric,
    avg_weight numeric,
    consumption numeric,
    samples integer,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: sensor_daily_summary_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sensor_daily_summary ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sensor_daily_summary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sensor_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sensor_data (
    id bigint NOT NULL,
    device_id text,
    weight numeric,
    battery_percentage numeric,
    battery_voltage numeric,
    full_weight numeric,
    empty_weight numeric,
    created_at timestamp without time zone DEFAULT now(),
    device_mac text,
    cycle_id integer DEFAULT 1,
    wifi_ssid text
);


--
-- Name: COLUMN sensor_data.full_weight; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sensor_data.full_weight IS 'Peso configurado del cilindro lleno en kg (0 = no configurado)';


--
-- Name: COLUMN sensor_data.empty_weight; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sensor_data.empty_weight IS 'Peso configurado del cilindro vacío en kg (0 = no configurado)';


--
-- Name: COLUMN sensor_data.wifi_ssid; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sensor_data.wifi_ssid IS 'SSID de la red WiFi conectada al momento del envío (diagnóstico)';


--
-- Name: sensor_data_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sensor_data ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sensor_data_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sensor_weekly_summary; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sensor_weekly_summary (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: sensor_weekly_summary_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sensor_weekly_summary ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sensor_weekly_summary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    device_id uuid,
    stripe_subscription_id text,
    stripe_customer_id text,
    price_id text,
    status text,
    current_period_end timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: user_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_plans (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text,
    device_id text,
    plan text DEFAULT 'free'::text,
    updated_at timestamp without time zone DEFAULT now(),
    status text DEFAULT 'active'::text,
    grace_until timestamp without time zone
);


--
-- Name: v_latest_sensor_data_by_mac; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_latest_sensor_data_by_mac AS
 SELECT DISTINCT ON (device_mac) id,
    created_at,
    device_mac,
    device_id,
    weight,
    battery_percentage,
    battery_voltage,
    full_weight,
    empty_weight
   FROM public.sensor_data
  WHERE ((device_mac IS NOT NULL) AND (TRIM(BOTH FROM device_mac) <> ''::text))
  ORDER BY device_mac, created_at DESC;


--
-- Name: v_plan_expiry_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_plan_expiry_status AS
 SELECT device_id,
    plan,
    expires_at,
        CASE
            WHEN (expires_at IS NULL) THEN 'sin_fecha'::text
            WHEN (expires_at < now()) THEN 'VENCIDO'::text
            WHEN (expires_at < (now() + '2 days'::interval)) THEN 'vence_pronto'::text
            ELSE 'vigente'::text
        END AS estado,
    ( SELECT count(*) AS count
           FROM public.sensor_data s
          WHERE (s.device_id = d.device_id)) AS lecturas,
    ( SELECT count(*) AS count
           FROM public.cylinder_events c
          WHERE (c.device_id = d.device_id)) AS eventos
   FROM public.devices d
  WHERE (plan = ANY (ARRAY['hogar'::text, 'empresa'::text]));


--
-- Name: v_sensor_data_enriched; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_sensor_data_enriched AS
 SELECT s.id,
    s.created_at,
    s.device_mac,
    s.device_id,
    d.id AS device_row_uuid,
    d.user_id,
    d.activation_key,
    d.plan,
    d.activated,
    d.activated_at,
    d.expires_at,
    d.current_cycle,
    d.firmware,
    s.weight,
    s.battery_percentage,
    s.battery_voltage,
    s.full_weight,
    s.empty_weight
   FROM (public.sensor_data s
     LEFT JOIN public.devices d ON ((d.device_mac = s.device_mac)));


--
-- Name: access_recovery id; Type: DEFAULT; Schema: private; Owner: -
--

ALTER TABLE ONLY private.access_recovery ALTER COLUMN id SET DEFAULT nextval('private.access_recovery_id_seq'::regclass);


--
-- Name: device_alerts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts ALTER COLUMN id SET DEFAULT nextval('public.device_alerts_id_seq'::regclass);


--
-- Name: access_recovery access_recovery_pkey; Type: CONSTRAINT; Schema: private; Owner: -
--

ALTER TABLE ONLY private.access_recovery
    ADD CONSTRAINT access_recovery_pkey PRIMARY KEY (id);


--
-- Name: cylinder_events cylinder_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cylinder_events
    ADD CONSTRAINT cylinder_events_pkey PRIMARY KEY (event_pk);


--
-- Name: device_alerts device_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts
    ADD CONSTRAINT device_alerts_pkey PRIMARY KEY (id);


--
-- Name: device_config device_config_device_mac_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_config
    ADD CONSTRAINT device_config_device_mac_key UNIQUE (device_mac);


--
-- Name: device_config device_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_config
    ADD CONSTRAINT device_config_pkey PRIMARY KEY (id);


--
-- Name: devices devices_activation_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_activation_key_key UNIQUE (activation_key);


--
-- Name: devices devices_device_id_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_device_id_unique UNIQUE (device_id);


--
-- Name: devices devices_device_mac_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_device_mac_key UNIQUE (device_mac);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: sensor_daily_summary sensor_daily_summary_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sensor_daily_summary
    ADD CONSTRAINT sensor_daily_summary_pkey PRIMARY KEY (id);


--
-- Name: sensor_data sensor_data_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sensor_data
    ADD CONSTRAINT sensor_data_pkey PRIMARY KEY (id);


--
-- Name: sensor_weekly_summary sensor_weekly_summary_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sensor_weekly_summary
    ADD CONSTRAINT sensor_weekly_summary_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: subscriptions subscriptions_stripe_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_stripe_subscription_id_key UNIQUE (stripe_subscription_id);


--
-- Name: sensor_daily_summary unique_device_day; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sensor_daily_summary
    ADD CONSTRAINT unique_device_day UNIQUE (device_id, day);


--
-- Name: user_plans user_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_plans
    ADD CONSTRAINT user_plans_pkey PRIMARY KEY (id);


--
-- Name: idx_access_recovery_mac_created; Type: INDEX; Schema: private; Owner: -
--

CREATE INDEX idx_access_recovery_mac_created ON private.access_recovery USING btree (device_mac, created_at DESC);


--
-- Name: idx_device_alerts_device_sent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_alerts_device_sent ON public.device_alerts USING btree (device_id, sent_at DESC);


--
-- Name: idx_devices_device_mac; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_device_mac ON public.devices USING btree (device_mac);


--
-- Name: idx_devices_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_user ON public.devices USING btree (user_id);


--
-- Name: idx_sensor_data_device_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sensor_data_device_created ON public.sensor_data USING btree (device_id, created_at DESC);


--
-- Name: idx_sensor_data_device_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sensor_data_device_id ON public.sensor_data USING btree (device_id);


--
-- Name: idx_sensor_data_device_mac; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sensor_data_device_mac ON public.sensor_data USING btree (device_mac);


--
-- Name: idx_sensor_data_device_mac_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sensor_data_device_mac_created_at ON public.sensor_data USING btree (device_mac, created_at DESC);


--
-- Name: idx_subscriptions_device_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscriptions_device_id ON public.subscriptions USING btree (device_id);


--
-- Name: idx_summary_device_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_summary_device_day ON public.sensor_daily_summary USING btree (device_id, day);


--
-- Name: sensor_data set_cycle_id_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_cycle_id_trigger BEFORE INSERT ON public.sensor_data FOR EACH ROW EXECUTE FUNCTION public.assign_cycle_id();


--
-- Name: devices trg_devices_mac_inmutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_devices_mac_inmutable BEFORE UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION public.devices_mac_inmutable();


--
-- Name: sensor_data trg_free_plan_fifo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_free_plan_fifo AFTER INSERT ON public.sensor_data FOR EACH ROW EXECUTE FUNCTION public.fifo_free_plan_cleanup();


--
-- Name: sensor_data trg_update_device_on_sensor_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_device_on_sensor_insert AFTER INSERT ON public.sensor_data FOR EACH ROW EXECUTE FUNCTION public.fn_update_device_on_sensor_insert();


--
-- Name: devices trg_update_last_seen; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_update_last_seen BEFORE UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION public.update_last_seen();


--
-- Name: device_alerts device_alerts_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts
    ADD CONSTRAINT device_alerts_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(device_id) ON DELETE CASCADE;


--
-- Name: devices devices_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: sensor_data allow_anon_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY allow_anon_insert ON public.sensor_data FOR INSERT TO anon WITH CHECK (true);


--
-- Name: sensor_data allow_anon_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY allow_anon_select ON public.sensor_data FOR SELECT TO anon USING (true);


--
-- Name: cylinder_events anon_select_cylinder_events; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY anon_select_cylinder_events ON public.cylinder_events FOR SELECT USING (true);


--
-- Name: cylinder_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cylinder_events ENABLE ROW LEVEL SECURITY;

--
-- Name: device_alerts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.device_alerts ENABLE ROW LEVEL SECURITY;

--
-- Name: device_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.device_config ENABLE ROW LEVEL SECURITY;

--
-- Name: devices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

--
-- Name: devices devices_insert_anon; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY devices_insert_anon ON public.devices FOR INSERT TO anon WITH CHECK (((COALESCE(plan, 'free'::text) = 'free'::text) AND (expires_at IS NULL) AND (access_key IS NULL) AND (user_email IS NULL) AND (user_phone IS NULL) AND (activated IS NOT TRUE) AND (user_id IS NULL)));


--
-- Name: devices devices_select_anon; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY devices_select_anon ON public.devices FOR SELECT TO anon USING (true);


--
-- Name: devices devices_update_anon; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY devices_update_anon ON public.devices FOR UPDATE TO authenticated, anon USING (true) WITH CHECK (true);


--
-- Name: sensor_daily_summary; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sensor_daily_summary ENABLE ROW LEVEL SECURITY;

--
-- Name: sensor_data; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sensor_data ENABLE ROW LEVEL SECURITY;

--
-- Name: sensor_weekly_summary; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sensor_weekly_summary ENABLE ROW LEVEL SECURITY;

--
-- Name: user_plans service_all_user_plans; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_all_user_plans ON public.user_plans USING ((auth.role() = 'service_role'::text)) WITH CHECK ((auth.role() = 'service_role'::text));


--
-- Name: cylinder_events service_insert_cylinder_events; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_insert_cylinder_events ON public.cylinder_events FOR INSERT WITH CHECK (true);


--
-- Name: device_alerts service_role_only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY service_role_only ON public.device_alerts USING ((( SELECT auth.role() AS role) = 'service_role'::text)) WITH CHECK ((( SELECT auth.role() AS role) = 'service_role'::text));


--
-- Name: subscriptions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: user_plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION es_hash_bcrypt(p_valor text); Type: ACL; Schema: private; Owner: -
--

REVOKE ALL ON FUNCTION private.es_hash_bcrypt(p_valor text) FROM PUBLIC;


--
-- Name: FUNCTION access_key_exists(p_device_mac text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.access_key_exists(p_device_mac text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.access_key_exists(p_device_mac text) TO anon;
GRANT ALL ON FUNCTION public.access_key_exists(p_device_mac text) TO authenticated;
GRANT ALL ON FUNCTION public.access_key_exists(p_device_mac text) TO service_role;


--
-- Name: FUNCTION assign_cycle_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.assign_cycle_id() TO anon;
GRANT ALL ON FUNCTION public.assign_cycle_id() TO authenticated;
GRANT ALL ON FUNCTION public.assign_cycle_id() TO service_role;


--
-- Name: FUNCTION cleanup_device_data(p_device_id text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cleanup_device_data(p_device_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cleanup_device_data(p_device_id text) TO service_role;
GRANT ALL ON FUNCTION public.cleanup_device_data(p_device_id text) TO anon;
GRANT ALL ON FUNCTION public.cleanup_device_data(p_device_id text) TO authenticated;


--
-- Name: FUNCTION cleanup_expired_plans(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cleanup_expired_plans() FROM PUBLIC;
GRANT ALL ON FUNCTION public.cleanup_expired_plans() TO service_role;


--
-- Name: FUNCTION cleanup_old_alerts(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cleanup_old_alerts() FROM PUBLIC;
GRANT ALL ON FUNCTION public.cleanup_old_alerts() TO service_role;


--
-- Name: FUNCTION cleanup_retention_policy(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cleanup_retention_policy() FROM PUBLIC;
GRANT ALL ON FUNCTION public.cleanup_retention_policy() TO service_role;


--
-- Name: FUNCTION devices_mac_inmutable(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.devices_mac_inmutable() TO anon;
GRANT ALL ON FUNCTION public.devices_mac_inmutable() TO authenticated;
GRANT ALL ON FUNCTION public.devices_mac_inmutable() TO service_role;


--
-- Name: FUNCTION factory_wipe_device(p_device_mac text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.factory_wipe_device(p_device_mac text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.factory_wipe_device(p_device_mac text) TO service_role;


--
-- Name: FUNCTION fifo_free_plan_cleanup(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fifo_free_plan_cleanup() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fifo_free_plan_cleanup() TO service_role;


--
-- Name: FUNCTION fn_free_plan_fifo(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fn_free_plan_fifo() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_free_plan_fifo() TO service_role;


--
-- Name: FUNCTION fn_update_device_on_sensor_insert(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.fn_update_device_on_sensor_insert() TO anon;
GRANT ALL ON FUNCTION public.fn_update_device_on_sensor_insert() TO authenticated;
GRANT ALL ON FUNCTION public.fn_update_device_on_sensor_insert() TO service_role;


--
-- Name: FUNCTION get_device_storage_stats(p_device_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_device_storage_stats(p_device_id text) TO anon;
GRANT ALL ON FUNCTION public.get_device_storage_stats(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.get_device_storage_stats(p_device_id text) TO service_role;


--
-- Name: FUNCTION handover_consume_code(p_device_mac text, p_code text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.handover_consume_code(p_device_mac text, p_code text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.handover_consume_code(p_device_mac text, p_code text) TO service_role;


--
-- Name: FUNCTION handover_to_client(p_device_mac text, p_current_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.handover_to_client(p_device_mac text, p_current_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.handover_to_client(p_device_mac text, p_current_key text) TO service_role;


--
-- Name: FUNCTION recovery_consume_code(p_device_mac text, p_code text, p_new_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recovery_consume_code(p_device_mac text, p_code text, p_new_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recovery_consume_code(p_device_mac text, p_code text, p_new_key text) TO service_role;


--
-- Name: FUNCTION recovery_consume_email_change(p_device_mac text, p_code text, p_new_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recovery_consume_email_change(p_device_mac text, p_code text, p_new_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recovery_consume_email_change(p_device_mac text, p_code text, p_new_email text) TO service_role;


--
-- Name: FUNCTION recovery_email_hint(p_device_mac text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recovery_email_hint(p_device_mac text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recovery_email_hint(p_device_mac text) TO anon;
GRANT ALL ON FUNCTION public.recovery_email_hint(p_device_mac text) TO authenticated;
GRANT ALL ON FUNCTION public.recovery_email_hint(p_device_mac text) TO service_role;


--
-- Name: FUNCTION recovery_issue_code(p_device_mac text, p_code text, p_email text, p_ttl_minutes integer, p_purpose text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recovery_issue_code(p_device_mac text, p_code text, p_email text, p_ttl_minutes integer, p_purpose text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recovery_issue_code(p_device_mac text, p_code text, p_email text, p_ttl_minutes integer, p_purpose text) TO service_role;


--
-- Name: FUNCTION reset_access_key(p_device_mac text, p_current_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reset_access_key(p_device_mac text, p_current_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reset_access_key(p_device_mac text, p_current_key text) TO service_role;


--
-- Name: FUNCTION reset_cylinder_history(p_device_mac text, p_access_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reset_cylinder_history(p_device_mac text, p_access_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reset_cylinder_history(p_device_mac text, p_access_key text) TO anon;
GRANT ALL ON FUNCTION public.reset_cylinder_history(p_device_mac text, p_access_key text) TO authenticated;
GRANT ALL ON FUNCTION public.reset_cylinder_history(p_device_mac text, p_access_key text) TO service_role;


--
-- Name: FUNCTION safe_increment_cycle(p_device_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.safe_increment_cycle(p_device_id text) TO anon;
GRANT ALL ON FUNCTION public.safe_increment_cycle(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.safe_increment_cycle(p_device_id text) TO service_role;


--
-- Name: FUNCTION self_downgrade_to_free(p_device_mac text, p_access_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.self_downgrade_to_free(p_device_mac text, p_access_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.self_downgrade_to_free(p_device_mac text, p_access_key text) TO anon;
GRANT ALL ON FUNCTION public.self_downgrade_to_free(p_device_mac text, p_access_key text) TO authenticated;
GRANT ALL ON FUNCTION public.self_downgrade_to_free(p_device_mac text, p_access_key text) TO service_role;


--
-- Name: FUNCTION set_access_key(p_device_mac text, p_new_key text, p_current_key text, p_recovery_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_access_key(p_device_mac text, p_new_key text, p_current_key text, p_recovery_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_access_key(p_device_mac text, p_new_key text, p_current_key text, p_recovery_email text) TO anon;
GRANT ALL ON FUNCTION public.set_access_key(p_device_mac text, p_new_key text, p_current_key text, p_recovery_email text) TO authenticated;
GRANT ALL ON FUNCTION public.set_access_key(p_device_mac text, p_new_key text, p_current_key text, p_recovery_email text) TO service_role;


--
-- Name: FUNCTION set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text) TO anon;
GRANT ALL ON FUNCTION public.set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text) TO authenticated;
GRANT ALL ON FUNCTION public.set_recovery_contact(p_device_mac text, p_email text, p_phone text, p_access_key text) TO service_role;


--
-- Name: FUNCTION sync_cycle_to_last_data(p_device_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sync_cycle_to_last_data(p_device_id text) TO anon;
GRANT ALL ON FUNCTION public.sync_cycle_to_last_data(p_device_id text) TO authenticated;
GRANT ALL ON FUNCTION public.sync_cycle_to_last_data(p_device_id text) TO service_role;


--
-- Name: FUNCTION update_consumo_diario(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_consumo_diario() TO anon;
GRANT ALL ON FUNCTION public.update_consumo_diario() TO authenticated;
GRANT ALL ON FUNCTION public.update_consumo_diario() TO service_role;


--
-- Name: FUNCTION update_last_seen(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_last_seen() TO anon;
GRANT ALL ON FUNCTION public.update_last_seen() TO authenticated;
GRANT ALL ON FUNCTION public.update_last_seen() TO service_role;


--
-- Name: FUNCTION verify_access_key(p_device_mac text, p_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.verify_access_key(p_device_mac text, p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.verify_access_key(p_device_mac text, p_key text) TO anon;
GRANT ALL ON FUNCTION public.verify_access_key(p_device_mac text, p_key text) TO authenticated;
GRANT ALL ON FUNCTION public.verify_access_key(p_device_mac text, p_key text) TO service_role;


--
-- Name: TABLE cylinder_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,REFERENCES,TRIGGER,MAINTAIN ON TABLE public.cylinder_events TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN ON TABLE public.cylinder_events TO authenticated;
GRANT ALL ON TABLE public.cylinder_events TO service_role;


--
-- Name: SEQUENCE cylinder_events_event_pk_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.cylinder_events_event_pk_seq TO anon;
GRANT ALL ON SEQUENCE public.cylinder_events_event_pk_seq TO authenticated;
GRANT ALL ON SEQUENCE public.cylinder_events_event_pk_seq TO service_role;


--
-- Name: TABLE device_alerts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.device_alerts TO service_role;


--
-- Name: SEQUENCE device_alerts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.device_alerts_id_seq TO anon;
GRANT ALL ON SEQUENCE public.device_alerts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.device_alerts_id_seq TO service_role;


--
-- Name: TABLE device_config; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.device_config TO service_role;


--
-- Name: SEQUENCE device_config_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.device_config_id_seq TO anon;
GRANT ALL ON SEQUENCE public.device_config_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.device_config_id_seq TO service_role;


--
-- Name: TABLE devices; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT,REFERENCES,TRIGGER,MAINTAIN ON TABLE public.devices TO anon;
GRANT INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN ON TABLE public.devices TO authenticated;
GRANT ALL ON TABLE public.devices TO service_role;


--
-- Name: COLUMN devices.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.devices TO anon;
GRANT SELECT(id) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.device_mac; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(device_mac) ON TABLE public.devices TO anon;
GRANT SELECT(device_mac) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.activation_key; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(activation_key) ON TABLE public.devices TO anon;
GRANT SELECT(activation_key) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.activated; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(activated) ON TABLE public.devices TO anon;
GRANT SELECT(activated) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.devices TO anon;
GRANT SELECT(created_at) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.activated_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(activated_at) ON TABLE public.devices TO anon;
GRANT SELECT(activated_at) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.firmware; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(firmware),UPDATE(firmware) ON TABLE public.devices TO anon;
GRANT SELECT(firmware),UPDATE(firmware) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.device_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(device_id) ON TABLE public.devices TO anon;
GRANT SELECT(device_id) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.expires_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(expires_at) ON TABLE public.devices TO anon;
GRANT SELECT(expires_at) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.full_weight; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(full_weight),UPDATE(full_weight) ON TABLE public.devices TO anon;
GRANT SELECT(full_weight),UPDATE(full_weight) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.empty_weight; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(empty_weight),UPDATE(empty_weight) ON TABLE public.devices TO anon;
GRANT SELECT(empty_weight),UPDATE(empty_weight) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.current_cycle; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(current_cycle) ON TABLE public.devices TO anon;
GRANT SELECT(current_cycle) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.phone; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(phone),UPDATE(phone) ON TABLE public.devices TO anon;
GRANT SELECT(phone),UPDATE(phone) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.email; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(email),UPDATE(email) ON TABLE public.devices TO anon;
GRANT SELECT(email),UPDATE(email) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.consumo_diario_g; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(consumo_diario_g) ON TABLE public.devices TO anon;
GRANT SELECT(consumo_diario_g) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.consumo_updated_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(consumo_updated_at) ON TABLE public.devices TO anon;
GRANT SELECT(consumo_updated_at) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.last_calibration; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(last_calibration),UPDATE(last_calibration) ON TABLE public.devices TO anon;
GRANT SELECT(last_calibration),UPDATE(last_calibration) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.battery_percentage; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(battery_percentage),UPDATE(battery_percentage) ON TABLE public.devices TO anon;
GRANT SELECT(battery_percentage),UPDATE(battery_percentage) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.battery_voltage; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(battery_voltage),UPDATE(battery_voltage) ON TABLE public.devices TO anon;
GRANT SELECT(battery_voltage),UPDATE(battery_voltage) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.last_seen_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(last_seen_at) ON TABLE public.devices TO anon;
GRANT SELECT(last_seen_at) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.wifi_ssid; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(wifi_ssid),UPDATE(wifi_ssid) ON TABLE public.devices TO anon;
GRANT SELECT(wifi_ssid),UPDATE(wifi_ssid) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.plan; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(plan) ON TABLE public.devices TO anon;
GRANT SELECT(plan) ON TABLE public.devices TO authenticated;


--
-- Name: COLUMN devices.sensor_ok; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(sensor_ok),UPDATE(sensor_ok) ON TABLE public.devices TO anon;
GRANT SELECT(sensor_ok),UPDATE(sensor_ok) ON TABLE public.devices TO authenticated;


--
-- Name: TABLE sensor_daily_summary; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sensor_daily_summary TO service_role;


--
-- Name: SEQUENCE sensor_daily_summary_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sensor_daily_summary_id_seq TO anon;
GRANT ALL ON SEQUENCE public.sensor_daily_summary_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sensor_daily_summary_id_seq TO service_role;


--
-- Name: TABLE sensor_data; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,REFERENCES,TRIGGER,MAINTAIN ON TABLE public.sensor_data TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,MAINTAIN ON TABLE public.sensor_data TO authenticated;
GRANT ALL ON TABLE public.sensor_data TO service_role;


--
-- Name: SEQUENCE sensor_data_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sensor_data_id_seq TO anon;
GRANT ALL ON SEQUENCE public.sensor_data_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sensor_data_id_seq TO service_role;


--
-- Name: TABLE sensor_weekly_summary; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sensor_weekly_summary TO service_role;


--
-- Name: SEQUENCE sensor_weekly_summary_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sensor_weekly_summary_id_seq TO anon;
GRANT ALL ON SEQUENCE public.sensor_weekly_summary_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sensor_weekly_summary_id_seq TO service_role;


--
-- Name: TABLE subscriptions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.subscriptions TO service_role;


--
-- Name: TABLE user_plans; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.user_plans TO service_role;


--
-- Name: TABLE v_latest_sensor_data_by_mac; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_latest_sensor_data_by_mac TO service_role;


--
-- Name: TABLE v_plan_expiry_status; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_plan_expiry_status TO service_role;


--
-- Name: TABLE v_sensor_data_enriched; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_sensor_data_enriched TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict vXgwMjfnVe1KsOpYrcXGeuRvHZfwW9SWoImLIJnXUgyanqfo4KKfewhjyHKZosW

