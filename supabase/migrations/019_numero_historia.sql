-- 019 · Número de historia clínica de cada paciente (1, 2, 3…), para tener todo con numeración, también de quienes vuelven cada año.
-- Cada paciente recibe un número propio y único de la clínica (columna `historia`), que se ve en la ficha, en la lista y en las hojas impresas, y se puede buscar.
-- Los pacientes que ya existen se numeran por orden de registro; los nuevos toman el siguiente número solos. Administración y doctor pueden cambiarlo (por ejemplo,
-- para respetar la numeración de las historias en papel): no se repite entre pacientes, y cada cambio queda en la auditoría.
-- Reemplazos numerados: pacientes_buscar (devuelve `historia` y busca por número, también «HC-000123») y paciente_ficha (devuelve `historia`).
-- Orden de instalación: después de 018. Todo calificado con el schema del cliente.

alter table luna_dental.clientas add column historia int;
update luna_dental.clientas c set historia = n.k from (select id, row_number() over (order by creado, id) as k from luna_dental.clientas) n where n.id = c.id;
alter table luna_dental.clientas alter column historia set not null;
alter table luna_dental.clientas add constraint clientas_historia_unica unique (historia);
alter table luna_dental.clientas add constraint clientas_historia_rango check (historia between 1 and 999999);

-- Número automático: el siguiente al más alto. El candado evita que dos altas simultáneas tomen el mismo.
create function luna_dental._historia_auto() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.historia is null then
    perform pg_advisory_xact_lock(hashtext('historia_' || tg_table_schema));
    select coalesce(max(historia), 0) + 1 into new.historia from luna_dental.clientas;
  end if;
  return new;
end $$;
create trigger clientas_historia before insert on luna_dental.clientas for each row execute function luna_dental._historia_auto();

create function luna_dental.historia_asignar(p_id bigint, p_numero int) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_doctor_o_admin() then raise exception 'No autorizado'; end if;
  if p_numero is null or p_numero < 1 or p_numero > 999999 then raise exception 'El número de historia va de 1 a 999999.'; end if;
  update luna_dental.clientas set historia = p_numero where id = p_id;
  if not found then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('historia_asignar', p_id, 'historia ' || p_numero::text);
exception when unique_violation then raise exception 'Ese número de historia ya lo tiene otro paciente.';
end $$;
revoke all on function luna_dental.historia_asignar(bigint, int), luna_dental._historia_auto() from public, anon, authenticated;
grant execute on function luna_dental.historia_asignar(bigint, int) to authenticated;

create or replace function luna_dental.pacientes_buscar(p_q text) returns json language plpgsql stable security definer set search_path = '' as $$
declare q text := replace(replace(replace(trim(coalesce(p_q, '')), '\', '\\'), '%', '\%'), '_', '\_');
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(x order by x.ultima desc nulls last, x.nombre), '[]'::json) from (
    select c.id, c.historia, c.nombre, c.telefono, d.cedula,
      (select count(*) from luna_dental.citas ci where ci.clienta_id = c.id and ci.estado <> 'cancelada') as citas,
      (select to_char(max(ci.inicio at time zone 'America/Guayaquil'), 'YYYY-MM-DD') from luna_dental.citas ci where ci.clienta_id = c.id and ci.inicio <= now()) as ultima,
      (select to_char(min(ci.inicio at time zone 'America/Guayaquil'), 'YYYY-MM-DD') from luna_dental.citas ci where ci.clienta_id = c.id and ci.inicio > now() and ci.estado in ('pendiente', 'confirmada')) as proxima
    from luna_dental.clientas c left join luna_dental.paciente_datos d on d.clienta_id = c.id
    where length(q) < 2 or c.nombre ilike '%' || q || '%' or c.telefono like '%' || q || '%' or d.cedula ilike '%' || q || '%'
       or case when q ~* '^(hc-?)?[0-9]{1,6}$' then c.historia = (regexp_replace(q, '^(hc-?)?', '', 'i'))::int else false end
    order by c.creado desc limit 40) x);
end $$;

create or replace function luna_dental.paciente_ficha(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
declare c luna_dental.clientas; clin boolean := luna_dental.es_clinico(); r json;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select * into c from luna_dental.clientas where id = p_id;
  if not found then raise exception 'Paciente no encontrado.'; end if;
  if clin then perform luna_dental._audit('ver_ficha', p_id, null); end if;
  select json_build_object(
    'id', c.id, 'historia', c.historia, 'nombre', c.nombre, 'telefono', c.telefono, 'creado', to_char(c.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
    'datos', (select row_to_json(d) from (select cedula, to_char(nacimiento, 'YYYY-MM-DD') as nacimiento, email, direccion, contacto_nombre, contacto_tel, representante from luna_dental.paciente_datos where clienta_id = p_id) d),
    'citas', (select coalesce(json_agg(json_build_object('id', ci.id, 'dia', to_char(ci.inicio at time zone 'America/Guayaquil', 'YYYY-MM-DD'), 'hora', to_char(ci.inicio at time zone 'America/Guayaquil', 'HH24:MI'),
        'duracion', (extract(epoch from (ci.fin - ci.inicio)) / 60)::int, 'servicio', sv.nombre, 'estado', ci.estado, 'doctor', dc.nombre) order by ci.inicio desc), '[]'::json)
      from luna_dental.citas ci join luna_dental.servicios sv on sv.id = ci.servicio_id left join luna_dental.doctores dc on dc.id = ci.doctor_id where ci.clienta_id = p_id),
    'cobros', (select coalesce(json_agg(json_build_object('id', m.id, 'dia', to_char(m.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'), 'descripcion', m.descripcion, 'importe', m.importe, 'tipo', m.tipo, 'anulado', m.anulado) order by m.creado desc), '[]'::json)
      from luna_dental.caja m where m.clienta_id = p_id),
    'presupuestos', (select coalesce(json_agg(json_build_object('id', p.id, 'dia', to_char(p.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'), 'total', p.total, 'estado', p.estado, 'descuento', p.descuento_pct,
        'items', (select json_agg(json_build_object('descripcion', i.descripcion, 'cant', i.cant, 'precio', i.precio) order by i.id) from luna_dental.presupuesto_items i where i.presupuesto_id = p.id)) order by p.creado desc), '[]'::json)
      from luna_dental.presupuestos p where p.clienta_id = p_id),
    'consentimientos', (select coalesce(json_agg(json_build_object('tipo', t.tipo, 'otorgado', t.otorgado, 'quien', t.quien, 'dia', to_char(t.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'))), '[]'::json)
      from (select distinct on (tipo) tipo, otorgado, quien, creado from luna_dental.consentimientos where clienta_id = p_id order by tipo, id desc) t),
    'acceso_clinico', clin,
    'clinico', case when clin then (select row_to_json(v) from (select alergias, medicamentos, antecedentes_medicos, antecedentes_odonto, habitos, observaciones,
        to_char(creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI') as actualizado from luna_dental.clinico_versiones where clienta_id = p_id order by id desc limit 1) v) end,
    'odontograma', case when clin then (select coalesce(json_agg(json_build_object('diente', o.diente, 'estado', o.estado, 'nota', o.nota, 'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'))), '[]'::json)
      from (select distinct on (diente) diente, estado, nota, creado from luna_dental.odontograma_mov where clienta_id = p_id order by diente, id desc) o) end,
    'evoluciones', case when clin then (select coalesce(json_agg(json_build_object('id', e.id, 'dia', to_char(e.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI'), 'motivo', e.motivo, 'diagnostico', e.diagnostico,
        'procedimiento', e.procedimiento, 'indicaciones', e.indicaciones, 'doctor', dc.nombre, 'autor', s.nombre, 'corrige_id', e.corrige_id, 'cita_id', e.cita_id) order by e.id desc), '[]'::json)
      from luna_dental.evoluciones e left join luna_dental.doctores dc on dc.id = e.doctor_id left join luna_dental.staff s on s.user_id = e.staff_id where e.clienta_id = p_id) end
  ) into r;
  return r;
end $$;
