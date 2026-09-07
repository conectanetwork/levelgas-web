-- update_consumo_diario  [2026-08-27, v2]
-- Igual criterio que el dashboard: el ritmo se mide sobre el CILINDRO EN CURSO
-- (desde el último cylinder_change) y solo se amplía a 14 días si ese cilindro
-- todavía no da una muestra útil (>= 4 lecturas y >= 1 día). Así el ritmo no
-- arrastra instalaciones, pruebas de banco o hábitos de meses anteriores.
create or replace function public.update_consumo_diario()
returns void
language plpgsql
set search_path to 'public'
as $function$
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
$function$;;