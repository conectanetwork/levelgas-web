-- Bloque 1 de 20260906_paso0_seguridad.sql
-- Solo CREA la RPC de reemplazo. No revoca nada: sin cambios de conducta para
-- el dashboard actual. Los revokes (bloques 2-4) van después de desplegar el
-- index.html parcheado.
create or replace function public.set_recovery_contact(
    p_device_mac  text,
    p_email       text,
    p_phone       text default null,
    p_access_key  text default null
)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
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
$function$;

comment on function public.set_recovery_contact(text, text, text, text) is
  'Fija el correo/telefono de recuperacion validando la clave de acceso server-side. '
  'Reemplaza el UPDATE directo de anon sobre devices.user_email (paso 0, 2026-09-06).';

revoke all     on function public.set_recovery_contact(text, text, text, text) from public;
grant  execute on function public.set_recovery_contact(text, text, text, text) to anon, authenticated;;