-- Módulo de clínica dental · 006 funciones. Todas security definer + set search_path = '' (§4.2). Permisos en 007.
-- Las del personal verifican es_staff() por dentro; las del dueño, es_admin(). Nada se concede "por tener sesión" (§4.10).

-- ---------- funciones que llama el paciente (anon) ----------
-- Solicitud de cita desde la web. No crea al paciente ni la cita: el personal confirma la hora exacta (por WhatsApp).
create function luna_dental.solicitar_cita(p_nombre text, p_telefono text, p_servicios bigint[], p_dia date, p_franja text,
  p_menor boolean, p_representante text, p_consentimiento boolean) returns json
language plpgsql security definer set search_path = '' as $$
declare tel text := luna_dental.tel(p_telefono); cf luna_dental.config; hoy date := (now() at time zone 'America/Guayaquil')::date;
  ids bigint[]; sid bigint;
begin
  select * into cf from luna_dental.config where id = 1;
  if cardinality(coalesce(p_servicios, '{}')) > 10 then raise exception 'Elige entre 1 y 4 tratamientos de la lista.'; end if;
  if p_consentimiento is not true then raise exception 'Para enviar tu solicitud, acepta el tratamiento de tus datos.'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe tu nombre y apellido.'; end if;
  if tel = '' then raise exception 'Escribe un celular válido (09...).'; end if;
  if p_dia is null or p_dia < hoy or p_dia > hoy + cf.max_dias then raise exception 'Elige un día dentro de los próximos % días.', cf.max_dias; end if;
  if p_franja is null or p_franja not in ('manana', 'tarde', 'cualquiera') then raise exception 'Elige mañana o tarde.'; end if;
  if coalesce(p_menor, false) and length(trim(coalesce(p_representante, ''))) < 2 then
    raise exception 'Si el paciente es menor de edad, escribe el nombre de quien autoriza.'; end if;
  select array_agg(distinct s.id) into ids from luna_dental.servicios s where s.id = any (coalesce(p_servicios, '{}')) and s.activo;
  if ids is null or cardinality(ids) <> cardinality(array(select distinct x from unnest(p_servicios) x)) or cardinality(ids) > 4 then
    raise exception 'Elige entre 1 y 4 tratamientos de la lista.'; end if;
  perform pg_advisory_xact_lock(hashtext('luna_dental.solicitudes'));
  if (select count(*) from luna_dental.solicitudes where creado > now() - interval '1 hour') >= cf.max_solicitudes_hora then
    raise exception 'Hay muchas solicitudes en este momento. Intenta en un rato o escríbenos por WhatsApp.'; end if;
  if (select count(*) from luna_dental.solicitudes where telefono = tel and creado > now() - interval '1 day') >= cf.max_solicitudes_tel_dia then
    raise exception 'Ya recibimos tus solicitudes de hoy. Te escribiremos para confirmar.'; end if;
  insert into luna_dental.solicitudes (nombre, telefono, servicio_ids, dia, franja, para_menor, representante, consentimiento_en)
  values (trim(left(p_nombre, 80)), tel, ids, p_dia, p_franja, coalesce(p_menor, false), nullif(trim(left(coalesce(p_representante, ''), 80)), ''), now())
  returning id into sid;
  return json_build_object('ok', true, 'ref', sid);
end $$;

-- ---------- personal: doctores, tarifario ----------
create function luna_dental.doctores_lista() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(json_build_object('id', id, 'nombre', nombre, 'especialidad', especialidad, 'color', color, 'activo', activo) order by orden, id), '[]'::json) from luna_dental.doctores);
end $$;

create function luna_dental.doctor_guardar(p_id bigint, p_nombre text, p_especialidad text, p_color text, p_activo boolean) returns bigint
language plpgsql security definer set search_path = '' as $$
declare i bigint;
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre del doctor.'; end if;
  if p_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Color no válido.'; end if;
  if p_id is null then
    insert into luna_dental.doctores (nombre, especialidad, color, activo, orden) values (trim(p_nombre), nullif(trim(p_especialidad), ''), p_color, coalesce(p_activo, true),
      (select coalesce(max(orden), 0) + 1 from luna_dental.doctores)) returning id into i;
  else
    update luna_dental.doctores set nombre = trim(p_nombre), especialidad = nullif(trim(p_especialidad), ''), color = p_color, activo = coalesce(p_activo, true) where id = p_id returning id into i;
  end if;
  return i;
end $$;

create function luna_dental.tarifario_lista() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(json_build_object('id', id, 'nombre', nombre, 'precio', precio, 'activo', activo) order by orden, id), '[]'::json) from luna_dental.tarifario);
end $$;

create function luna_dental.tarifario_guardar(p_id bigint, p_nombre text, p_precio numeric, p_activo boolean) returns bigint
language plpgsql security definer set search_path = '' as $$
declare i bigint;
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre del tratamiento.'; end if;
  if p_precio is null or p_precio < 0 or p_precio > 100000 then raise exception 'Precio no válido.'; end if;
  if p_id is null then
    insert into luna_dental.tarifario (nombre, precio, activo, orden) values (trim(p_nombre), round(p_precio, 2), coalesce(p_activo, true),
      (select coalesce(max(orden), 0) + 1 from luna_dental.tarifario)) returning id into i;
  else
    update luna_dental.tarifario set nombre = trim(p_nombre), precio = round(p_precio, 2), activo = coalesce(p_activo, true) where id = p_id returning id into i;
  end if;
  return i;
end $$;

-- ---------- personal: solicitudes y agenda ----------
create function luna_dental.solicitudes_lista(p_estado text default 'nueva') returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_estado not in ('nueva', 'agendada', 'descartada') then raise exception 'Estado no válido.'; end if;
  return (select coalesce(json_agg(json_build_object('id', s.id, 'nombre', s.nombre, 'telefono', s.telefono,
    'dia', to_char(s.dia, 'YYYY-MM-DD'), 'franja', s.franja, 'para_menor', s.para_menor, 'representante', s.representante,
    'servicios', (select json_agg(json_build_object('id', sv.id, 'nombre', sv.nombre) order by sv.orden) from luna_dental.servicios sv where sv.id = any (s.servicio_ids)),
    'creado', s.creado, 'estado', s.estado) order by s.creado), '[]'::json)
    from luna_dental.solicitudes s where s.estado = p_estado);
end $$;

create function luna_dental.solicitud_descartar(p_id bigint) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  update luna_dental.solicitudes set estado = 'descartada', atendida_por = auth.uid() where id = p_id and estado = 'nueva';
  if not found then raise exception 'Solicitud no encontrada o ya atendida.'; end if;
end $$;

-- Convierte una solicitud en cita confirmada con hora exacta y doctor
create function luna_dental.solicitud_agendar(p_id bigint, p_servicio bigint, p_dia date, p_hora text, p_doctor bigint) returns json
language plpgsql security definer set search_path = '' as $$
declare s luna_dental.solicitudes; cl luna_dental.clientas; cid bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  select * into s from luna_dental.solicitudes where id = p_id for update;
  if not found or s.estado <> 'nueva' then raise exception 'Solicitud no encontrada o ya atendida.'; end if;
  if not (p_servicio = any (s.servicio_ids)) then raise exception 'Elige uno de los tratamientos de la solicitud.'; end if;
  select * into cl from luna_dental.clientas where telefono = s.telefono;
  if not found then
    insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), s.nombre, s.telefono) returning * into cl;
  end if;
  cid := luna_dental._reservar(cl.id, p_servicio, p_dia, p_hora);
  update luna_dental.citas set estado = 'confirmada', doctor_id = p_doctor where id = cid;
  update luna_dental.solicitudes set estado = 'agendada', cita_id = cid, atendida_por = auth.uid() where id = p_id;
  return json_build_object('cita', cid, 'nombre', cl.nombre, 'telefono', cl.telefono);
end $$;

create function luna_dental.clinica_agenda(p_desde date, p_hasta date) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 62 then raise exception 'Rango de fechas no válido.'; end if;
  return (select coalesce(json_agg(json_build_object(
    'id', c.id, 'estado', c.estado,
    'dia', to_char(c.inicio at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
    'hora', to_char(c.inicio at time zone 'America/Guayaquil', 'HH24:MI'),
    'duracion', (extract(epoch from (c.fin - c.inicio)) / 60)::int,
    'servicio', sv.nombre, 'nombre', cl.nombre, 'telefono', cl.telefono,
    'doctor_id', c.doctor_id) order by c.inicio), '[]'::json)
    from luna_dental.citas c join luna_dental.clientas cl on cl.id = c.clienta_id join luna_dental.servicios sv on sv.id = c.servicio_id
    where c.inicio >= p_desde::timestamp at time zone 'America/Guayaquil' and c.inicio < (p_hasta + 1)::timestamp at time zone 'America/Guayaquil'
      and c.estado <> 'cancelada');
end $$;

create function luna_dental.cita_doctor(p_cita bigint, p_doctor bigint) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  update luna_dental.citas set doctor_id = p_doctor where id = p_cita;
  if not found then raise exception 'Cita no encontrada.'; end if;
end $$;

-- ---------- personal: caja ----------
create function luna_dental.caja_dia(p_dia date) returns json language plpgsql stable security definer set search_path = '' as $$
declare d0 timestamptz; r json;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_dia is null then raise exception 'Fecha no válida.'; end if;
  d0 := p_dia::timestamp at time zone 'America/Guayaquil';
  select json_build_object(
    'items', (select coalesce(json_agg(json_build_object('id', m.id, 'hora', to_char(m.creado at time zone 'America/Guayaquil', 'HH24:MI'), 'descripcion', m.descripcion,
      'importe', m.importe, 'tipo', m.tipo, 'doctor_id', m.doctor_id, 'anulado', m.anulado, 'motivo', m.motivo_anulacion) order by m.creado), '[]'::json)
      from luna_dental.caja m where m.creado >= d0 and m.creado < d0 + interval '1 day'),
    'ingresos', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= d0 and creado < d0 + interval '1 day' and tipo = 'ing' and not anulado),
    'egresos', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= d0 and creado < d0 + interval '1 day' and tipo = 'egr' and not anulado)) into r;
  return r;
end $$;

create function luna_dental.caja_registrar(p_descripcion text, p_importe numeric, p_tipo text, p_doctor bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare i bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if length(trim(coalesce(p_descripcion, ''))) < 2 then raise exception 'Escribe una descripción.'; end if;
  if p_importe is null or p_importe <= 0 or p_importe > 100000 then raise exception 'Importe no válido.'; end if;
  if p_tipo not in ('ing', 'egr') then raise exception 'Tipo no válido.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  insert into luna_dental.caja (descripcion, importe, tipo, doctor_id, staff_id) values (trim(left(p_descripcion, 80)), round(p_importe, 2), p_tipo, p_doctor, auth.uid()) returning id into i;
  return i;
end $$;

create function luna_dental.caja_anular(p_id bigint, p_motivo text) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo de la anulación.'; end if;
  update luna_dental.caja set anulado = true, anulado_por = auth.uid(), anulado_en = now(), motivo_anulacion = trim(left(p_motivo, 120)) where id = p_id and not anulado;
  if not found then raise exception 'Movimiento no encontrado o ya anulado.'; end if;
end $$;

-- ---------- personal: presupuestos ----------
-- p_items = [{"tarifario_id": 3, "cant": 2}, …]. El precio sale del tarifario y el total se calcula aquí.
create function luna_dental.presupuesto_guardar(p_paciente text, p_doctor bigint, p_descuento int, p_items json, p_seguimiento date) returns json
language plpgsql security definer set search_path = '' as $$
declare it json; t luna_dental.tarifario; n int := 0; sub numeric := 0; pid bigint; tot numeric; cl bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if length(trim(coalesce(p_paciente, ''))) < 2 then raise exception 'Escribe el nombre del paciente.'; end if;
  if p_descuento is null or p_descuento < 0 or p_descuento > 50 then raise exception 'El descuento va de 0 a 50 %%.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  if p_items is null or json_typeof(p_items) <> 'array' or json_array_length(p_items) not between 1 and 20 then raise exception 'Agrega de 1 a 20 tratamientos.'; end if;
  for it in select * from json_array_elements(p_items) loop
    select * into t from luna_dental.tarifario where id = (it ->> 'tarifario_id')::bigint and activo;
    if not found then raise exception 'Tratamiento no válido.'; end if;
    if (it ->> 'cant')::int not between 1 and 20 then raise exception 'Cantidad entre 1 y 20.'; end if;
    sub := sub + t.precio * (it ->> 'cant')::int; n := n + 1;
  end loop;
  tot := round(sub * (100 - p_descuento) / 100.0, 2);
  insert into luna_dental.presupuestos (paciente, doctor_id, descuento_pct, total, seguimiento, staff_id)
  values (trim(left(p_paciente, 80)), p_doctor, p_descuento, tot, p_seguimiento, auth.uid()) returning id into pid;
  for it in select * from json_array_elements(p_items) loop
    select * into t from luna_dental.tarifario where id = (it ->> 'tarifario_id')::bigint;
    insert into luna_dental.presupuesto_items (presupuesto_id, tarifario_id, descripcion, cant, precio) values (pid, t.id, t.nombre, (it ->> 'cant')::int, t.precio);
  end loop;
  return json_build_object('id', pid, 'total', tot);
end $$;

create function luna_dental.presupuestos_lista(p_estado text default null) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_estado is not null and p_estado not in ('enviado', 'aceptado', 'rechazado') then raise exception 'Estado no válido.'; end if;
  return (select coalesce(json_agg(json_build_object('id', p.id, 'paciente', p.paciente, 'doctor_id', p.doctor_id, 'descuento', p.descuento_pct, 'total', p.total,
    'estado', p.estado, 'seguimiento', to_char(p.seguimiento, 'YYYY-MM-DD'), 'creado', to_char(p.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
    'items', (select json_agg(json_build_object('descripcion', i.descripcion, 'cant', i.cant, 'precio', i.precio) order by i.id) from luna_dental.presupuesto_items i where i.presupuesto_id = p.id)
    ) order by p.creado desc), '[]'::json)
    from (select * from luna_dental.presupuestos where p_estado is null or estado = p_estado order by creado desc limit 100) p);
end $$;

create function luna_dental.presupuesto_estado(p_id bigint, p_estado text) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_estado not in ('aceptado', 'rechazado') then raise exception 'Estado no válido.'; end if;
  update luna_dental.presupuestos set estado = p_estado, decidido_en = now() where id = p_id and estado = 'enviado';
  if not found then raise exception 'Presupuesto no encontrado o ya decidido.'; end if;
end $$;

-- ---------- dueño (solo rol admin): resumen de un periodo y del periodo anterior de igual duración ----------
create function luna_dental.dueno_resumen(p_desde date, p_hasta date) returns json language plpgsql stable security definer set search_path = '' as $$
declare t0 timestamptz; t1 timestamptz; dias int; a0 timestamptz; a1 timestamptz; hoy date := (now() at time zone 'America/Guayaquil')::date; r json;
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 365 then raise exception 'Rango de fechas no válido (máximo 1 año).'; end if;
  dias := p_hasta - p_desde + 1;
  t0 := p_desde::timestamp at time zone 'America/Guayaquil'; t1 := (p_hasta + 1)::timestamp at time zone 'America/Guayaquil';
  a0 := (p_desde - dias)::timestamp at time zone 'America/Guayaquil'; a1 := t0;
  select json_build_object(
    'desde', p_desde, 'hasta', p_hasta, 'dias', dias,
    'citas', json_build_object(
      'total', (select count(*) from luna_dental.citas where inicio >= t0 and inicio < t1 and estado <> 'cancelada'),
      'atendidas', (select count(*) from luna_dental.citas where inicio >= t0 and inicio < t1 and estado = 'atendida'),
      'no_vino', (select count(*) from luna_dental.citas where inicio >= t0 and inicio < t1 and estado = 'no_vino'),
      'canceladas', (select count(*) from luna_dental.citas where inicio >= t0 and inicio < t1 and estado = 'cancelada'),
      'por_doctor', (select coalesce(json_agg(x order by x.citas desc), '[]'::json) from (
        select coalesce(d.nombre, 'Sin asignar') as doctor, coalesce(d.color, '#8E8F94') as color, count(*) as citas, count(*) filter (where c.estado = 'atendida') as atendidas
        from luna_dental.citas c left join luna_dental.doctores d on d.id = c.doctor_id where c.inicio >= t0 and c.inicio < t1 and c.estado <> 'cancelada' group by d.nombre, d.color) x),
      'por_tratamiento', (select coalesce(json_agg(x order by x.n desc), '[]'::json) from (
        select sv.nombre, count(*) n from luna_dental.citas c join luna_dental.servicios sv on sv.id = c.servicio_id
        where c.inicio >= t0 and c.inicio < t1 and c.estado <> 'cancelada' group by sv.nombre order by n desc limit 8) x),
      'por_dia_semana', (select coalesce(json_agg(json_build_object('dia', k, 'n', (select count(*) from luna_dental.citas c where c.inicio >= t0 and c.inicio < t1 and c.estado <> 'cancelada'
        and extract(isodow from c.inicio at time zone 'America/Guayaquil') = k)) order by k), '[]'::json) from generate_series(1, 7) k),
      'por_franja', json_build_object(
        'manana', (select count(*) from luna_dental.citas where inicio >= t0 and inicio < t1 and estado <> 'cancelada' and extract(hour from inicio at time zone 'America/Guayaquil') < 13),
        'tarde', (select count(*) from luna_dental.citas where inicio >= t0 and inicio < t1 and estado <> 'cancelada' and extract(hour from inicio at time zone 'America/Guayaquil') >= 13))),
    'solicitudes', json_build_object(
      'recibidas', (select count(*) from luna_dental.solicitudes where creado >= t0 and creado < t1),
      'agendadas', (select count(*) from luna_dental.solicitudes where creado >= t0 and creado < t1 and estado = 'agendada'),
      'descartadas', (select count(*) from luna_dental.solicitudes where creado >= t0 and creado < t1 and estado = 'descartada'),
      'pendientes', (select count(*) from luna_dental.solicitudes where estado = 'nueva')),
    'caja', json_build_object(
      'ingresos', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= t0 and creado < t1 and tipo = 'ing' and not anulado),
      'egresos', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= t0 and creado < t1 and tipo = 'egr' and not anulado),
      'cobros', (select count(*) from luna_dental.caja where creado >= t0 and creado < t1 and tipo = 'ing' and not anulado),
      'anulados', (select count(*) from luna_dental.caja where creado >= t0 and creado < t1 and anulado),
      'serie', (select coalesce(json_agg(json_build_object('dia', to_char(d, 'YYYY-MM-DD'),
          'ing', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= d::timestamp at time zone 'America/Guayaquil' and creado < (d + 1)::timestamp at time zone 'America/Guayaquil' and tipo = 'ing' and not anulado),
          'egr', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= d::timestamp at time zone 'America/Guayaquil' and creado < (d + 1)::timestamp at time zone 'America/Guayaquil' and tipo = 'egr' and not anulado)) order by d), '[]'::json)
        from generate_series(0, dias - 1) k, lateral (select p_desde + k as d) x),
      'por_doctor', (select coalesce(json_agg(x order by x.ingresos desc), '[]'::json) from (
        select coalesce(d.nombre, 'Sin asignar') as doctor, coalesce(d.color, '#8E8F94') as color, sum(m.importe) as ingresos
        from luna_dental.caja m left join luna_dental.doctores d on d.id = m.doctor_id
        where m.creado >= t0 and m.creado < t1 and m.tipo = 'ing' and not m.anulado group by d.nombre, d.color) x)),
    'presupuestos', json_build_object(
      'enviados', (select count(*) from luna_dental.presupuestos where creado >= t0 and creado < t1),
      'aceptados', (select count(*) from luna_dental.presupuestos where creado >= t0 and creado < t1 and estado = 'aceptado'),
      'rechazados', (select count(*) from luna_dental.presupuestos where creado >= t0 and creado < t1 and estado = 'rechazado'),
      'monto_enviado', (select coalesce(sum(total), 0) from luna_dental.presupuestos where creado >= t0 and creado < t1),
      'monto_aceptado', (select coalesce(sum(total), 0) from luna_dental.presupuestos where creado >= t0 and creado < t1 and estado = 'aceptado'),
      'seguimientos', (select coalesce(json_agg(x order by x.seguimiento), '[]'::json) from (
        select id, paciente, total, to_char(seguimiento, 'YYYY-MM-DD') as seguimiento, hoy - seguimiento as dias_vencido
        from luna_dental.presupuestos where estado = 'enviado' and seguimiento is not null and seguimiento <= hoy order by seguimiento limit 10) x)),
    'pacientes', json_build_object(
      'nuevos', (select count(*) from luna_dental.clientas where creado >= t0 and creado < t1),
      'total', (select count(*) from luna_dental.clientas)),
    'anterior', json_build_object(
      'citas_atendidas', (select count(*) from luna_dental.citas where inicio >= a0 and inicio < a1 and estado = 'atendida'),
      'ingresos', (select coalesce(sum(importe), 0) from luna_dental.caja where creado >= a0 and creado < a1 and tipo = 'ing' and not anulado),
      'nuevos', (select count(*) from luna_dental.clientas where creado >= a0 and creado < a1),
      'solicitudes', (select count(*) from luna_dental.solicitudes where creado >= a0 and creado < a1),
      'monto_aceptado', (select coalesce(sum(total), 0) from luna_dental.presupuestos where creado >= a0 and creado < a1 and estado = 'aceptado'))
  ) into r;
  return r;
end $$;
