-- ═══════════════════════════════════════════════════════════════════
-- update_consumo_diario  [corregida 2026-08-27]
-- Antes usaba REGR_SLOPE sobre el peso bruto de los últimos 7 días. Cualquier
-- recarga o cambio de cilindro dentro de esa ventana aplana la recta: para
-- SG-BE8BA300 daba 206 g/día cuando el consumo real era ~2.600 g/día, y ese
-- valor alimenta el respaldo de "días restantes" del dashboard.
-- Ahora suma las CAÍDAS de peso entre lecturas consecutivas y las divide por
-- el tiempo que abarcan. Las subidas no cuentan como consumo, así que las
-- recargas dejan de distorsionar el resultado.
-- Ventana de 14 días (antes 7) para un ritmo más estable.
-- ═══════════════════════════════════════════════════════════════════
create or replace function public.update_consumo_diario()
returns void
language plpgsql
set search_path to 'public'
as $function$
declare
  dev  record;
  v_g  numeric;
begin
  for dev in select distinct device_mac from public.sensor_data where device_mac is not null loop

    with lect as (
      select created_at,
             weight,
             lag(weight) over (order by created_at) as prev_w
        from public.sensor_data
       where device_mac  = dev.device_mac
         and created_at >= now() - interval '14 days'
    ),
    agg as (
      select coalesce(sum(greatest(0, prev_w - weight)), 0) as caida,
             extract(epoch from (max(created_at) - min(created_at))) / 86400.0 as dias,
             count(*) as n
        from lect
    )
    select case
             when n >= 2 and dias > 0.25 and caida > 0 then (caida * 1000) / dias
           end
      into v_g
      from agg;

    if v_g is not null and v_g > 0 then
      update public.devices
         set consumo_diario_g   = v_g,
             consumo_updated_at = now()
       where device_mac = dev.device_mac;
    end if;

  end loop;
end;
$function$;;