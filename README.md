# levelgas-web

Sitio de producción de LevelGas: landing de marketing + `/dashboard/` (con el flujo
de acceso y recuperación de clave ya endurecidos) + `/dashboard/demo/` + retorno de
pago Flow (`/dashboard/return.html`).

Publicado con GitHub Pages. Dominio personalizado en `CNAME`.

Origen: build `apps/client/dist/` del monorepo `commercial-app` (ver el repo
`LevelGas` completo para el código fuente React/Vite, migraciones SQL y firmware).

**Antes de este sitio ser el definitivo**, aplica en Supabase las tres migraciones
de `supabase/migrations/2026081*` del repo `LevelGas` — este dashboard llama a
`set_access_key`, `verify_access_key`, `reset_access_key`, `access_key_exists`,
`recovery_email_hint` y `handover_to_client`, que no existen hasta aplicarlas.
