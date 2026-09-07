-- Cierra accesos públicos no documentados encontrados en el advisor de seguridad
-- de Supabase el 2026-08-22: funciones destructivas y vistas SECURITY DEFINER
-- que exponían activation_key y datos de todos los dispositivos a `anon`.

REVOKE EXECUTE ON FUNCTION public.cleanup_device_data(text)      FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cleanup_expired_plans()        FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cleanup_old_alerts()            FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cleanup_retention_policy()      FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fifo_free_plan_cleanup()        FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.fn_free_plan_fifo()             FROM anon, authenticated;

REVOKE ALL ON public.v_sensor_data_enriched       FROM anon, authenticated;
REVOKE ALL ON public.v_plan_expiry_status         FROM anon, authenticated;
REVOKE ALL ON public.v_latest_sensor_data_by_mac  FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
;