-- ── 0. Preflight ─────────────────────────────────────────────────────────────
DO $preflight$
BEGIN
    IF to_regclass('public.devices') IS NULL THEN
        RAISE EXCEPTION 'Preflight: falta public.devices.';
    END IF;
    IF to_regclass('public.sensor_data') IS NULL THEN
        RAISE EXCEPTION 'Preflight: falta public.sensor_data.';
    END IF;
END;
$preflight$;

-- ── 1. Columnas de diagnóstico en devices ────────────────────────────────────
ALTER TABLE public.devices
    ADD COLUMN IF NOT EXISTS wifi_ssid TEXT;

ALTER TABLE public.devices
    ADD COLUMN IF NOT EXISTS sensor_ok BOOLEAN DEFAULT TRUE;

COMMENT ON COLUMN public.devices.wifi_ssid IS
    'SSID al que estaba conectada la báscula en el último heartbeat (diagnóstico).';
COMMENT ON COLUMN public.devices.sensor_ok IS
    'FALSE si el firmware no obtuvo lectura válida del HX711 en su último ciclo.';

-- ── 2. Valores por defecto para dispositivos nuevos ──────────────────────────
DO $defaults$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='devices' AND column_name='plan') THEN
        ALTER TABLE public.devices ALTER COLUMN plan SET DEFAULT 'free';
        UPDATE public.devices SET plan = 'free' WHERE plan IS NULL;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema='public' AND table_name='devices' AND column_name='activated') THEN
        ALTER TABLE public.devices ALTER COLUMN activated SET DEFAULT FALSE;
        UPDATE public.devices SET activated = FALSE WHERE activated IS NULL;
    END IF;
END;
$defaults$;

-- ── 3. Índice de apoyo ───────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_devices_device_mac
    ON public.devices (device_mac);

-- ── 5. Recarga del esquema en PostgREST ──────────────────────────────────────
NOTIFY pgrst, 'reload schema';
;