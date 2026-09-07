-- Corrección: las funciones tenían EXECUTE concedido a PUBLIC (el rol implícito
-- por defecto de Postgres al crear una función), así que revocar solo de
-- anon/authenticated no bastaba — anon hereda todo lo que tenga PUBLIC.

REVOKE EXECUTE ON FUNCTION public.cleanup_device_data(text)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cleanup_expired_plans()        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cleanup_old_alerts()            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fifo_free_plan_cleanup()        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fn_free_plan_fifo()             FROM PUBLIC;

-- service_role (usado por Edge Functions y llamadas administrativas) conserva acceso.
GRANT EXECUTE ON FUNCTION public.cleanup_device_data(text)      TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_plans()        TO service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_old_alerts()            TO service_role;

NOTIFY pgrst, 'reload schema';
;