-- Módulo de citas · 002 ayudas internas y funciones de la clienta (anon).
-- Todas: security definer + set search_path = '' (§4.2). Los permisos se fijan en 004.

-- ---------- ayudas internas (nadie las llama desde fuera) ----------
create function luna_dental.tel(p text) returns text language sql immutable set search_path = '' as $$
  select case when d ~ '^09[0-9]{8}$' then '593' || substr(d, 2) when d ~ '^593[0-9]{9}$' then d else '' end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x $$;

create function luna_dental.es_staff() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from luna_dental.staff where user_id = auth.uid()) $$;
create function luna_dental.es_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from luna_dental.staff where user_id = auth.uid() and rol = 'admin') $$;

create function luna_dental.codigo() returns text language plpgsql set search_path = '' as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; p text := (select prefijo from luna_dental.config where id = 1);
begin
  loop
    c := p || '-';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from luna_dental.clientas where codigo = c);
  end loop;
  return c;
end $$;

create function luna_dental.prog(p_cl bigint, p_sv bigint) returns int language sql stable security definer set search_path = '' as $$
  select greatest(0, count(*) filter (where tipo = 'sello') - count(*) filter (where tipo = 'canje') * (select sellos_meta from luna_dental.config where id = 1))::int
  from luna_dental.sellos where clienta_id = p_cl and servicio_id = p_sv and not anulado $$;

create function luna_dental.ocupadas(p_ini timestamptz, p_fin timestamptz, p_excluir bigint default null) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from luna_dental.citas where estado in ('pendiente', 'confirmada') and inicio < p_fin and fin > p_ini and id is distinct from p_excluir $$;

-- uuid desde texto sin reventar si viene basura
create function luna_dental.a_uuid(p text) returns uuid language plpgsql immutable set search_path = '' as $$
begin return p::uuid; exception when others then return null; end $$;

-- Resuelve a la clienta por lo que muestra el QR (qr_token, solo personal) o por su código. NUNCA por el token de sesión.
create function luna_dental.clienta_por_ref(p_ref text) returns bigint language sql stable security definer set search_path = '' as $$
  select id from luna_dental.clientas
  where qr_token = regexp_replace(trim(coalesce(p_ref, '')), '^.*[?&]t=', '') or upper(codigo) = upper(trim(coalesce(p_ref, ''))) limit 1 $$;

-- Ficha de la clienta. p_privado = true: vista del personal (teléfono, quién selló). false: la ve ella misma (lleva el qr).
create function luna_dental.json_clienta(p_id bigint, p_privado boolean) returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'nombre', c.nombre, 'codigo', c.codigo,
    'qr', case when not p_privado then c.qr_token end,
    'telefono', case when p_privado then c.telefono end,
    'desde', c.creado,
    'meta', (select sellos_meta from luna_dental.config where id = 1),
    'servicios', (select coalesce(json_agg(json_build_object(
        'id', sv.id, 'nombre', sv.nombre, 'categoria', sv.categoria,
        'progreso', luna_dental.prog(c.id, sv.id),
        'gratis', luna_dental.prog(c.id, sv.id) >= (select sellos_meta from luna_dental.config where id = 1),
        'sesiones', (select count(*) from luna_dental.sellos x where x.clienta_id = c.id and x.servicio_id = sv.id and not x.anulado)
      ) order by sv.orden), '[]'::json) from luna_dental.servicios sv where sv.activo and sv.fidelidad),
    'citas', (select coalesce(json_agg(json_build_object(
        'id', ct.id, 'servicio_id', ct.servicio_id, 'servicio', sv.nombre, 'estado', ct.estado,
        'dia', to_char(ct.inicio at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
        'hora', to_char(ct.inicio at time zone 'America/Guayaquil', 'HH24:MI'),
        'hora_fin', to_char(ct.fin at time zone 'America/Guayaquil', 'HH24:MI'),
        'cancelable', ct.inicio > now() + interval '6 hours'
      ) order by ct.inicio), '[]'::json)
      from luna_dental.citas ct join luna_dental.servicios sv on sv.id = ct.servicio_id
      where ct.clienta_id = c.id and ct.estado in ('pendiente', 'confirmada') and ct.fin > now()),
    'historial', (select coalesce(json_agg(h order by h.creado desc), '[]'::json) from (
      select s.id, s.tipo, s.anulado, s.creado, sv.nombre servicio,
        case when p_privado then (select nombre from luna_dental.staff where user_id = s.staff_id) end staff,
        (p_privado and s.staff_id = auth.uid() and now() - s.creado < interval '30 minutes') propio_reciente
      from luna_dental.sellos s join luna_dental.servicios sv on sv.id = s.servicio_id
      where s.clienta_id = c.id order by s.creado desc limit 20) h)
  ) from luna_dental.clientas c where c.id = p_id $$;

-- Valida y crea la cita (todas las reglas en un solo lugar). Solo la llaman agendar y agendar_token.
create function luna_dental._reservar(p_cl bigint, p_servicio bigint, p_dia date, p_hora text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare cf luna_dental.config; s luna_dental.servicios; h luna_dental.horario; ini timestamptz; fin_ timestamptz; hh time;
  hoy date := (now() at time zone 'America/Guayaquil')::date; cid bigint; m_ini int; m_abre int; m_cierra int;
begin
  select * into cf from luna_dental.config where id = 1;
  select * into s from luna_dental.servicios where id = p_servicio and activo;
  if not found then raise exception 'Servicio no disponible.'; end if;
  if p_dia is null or p_dia < hoy or p_dia > hoy + cf.max_dias then raise exception 'Elige una fecha dentro de los próximos % días.', cf.max_dias; end if;
  if p_hora is null or p_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora no válida.'; end if;
  hh := p_hora::time;
  select * into h from luna_dental.horario where dia_semana = extract(isodow from p_dia)::int;
  if not found then raise exception 'Ese día no atendemos.'; end if;
  m_ini := extract(hour from hh)::int * 60 + extract(minute from hh)::int;
  m_abre := extract(hour from h.abre)::int * 60 + extract(minute from h.abre)::int;
  m_cierra := extract(hour from h.cierra)::int * 60 + extract(minute from h.cierra)::int;
  if m_ini < m_abre or m_ini + s.duracion_min > m_cierra or (m_ini - m_abre) % cf.paso_min <> 0 then raise exception 'Ese horario no está disponible.'; end if;
  ini := (p_dia + hh) at time zone 'America/Guayaquil';
  fin_ := ini + make_interval(mins => s.duracion_min);
  if ini < now() + make_interval(mins => cf.anticipacion_min) then raise exception 'Elige un horario con al menos % minutos de anticipación.', cf.anticipacion_min; end if;
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  if (select count(*) from luna_dental.citas where clienta_id = p_cl and estado in ('pendiente', 'confirmada') and fin > now()) >= cf.max_citas_activas then
    raise exception 'Ya tienes % citas por atender. Cancela una o espera a que se confirmen.', cf.max_citas_activas; end if;
  if (select count(*) from luna_dental.citas where creado > now() - interval '1 hour') >= cf.max_citas_hora then
    raise exception 'Hay muchas solicitudes en este momento. Intenta en un rato o escríbenos por WhatsApp.'; end if;
  if luna_dental.ocupadas(ini, fin_) >= cf.capacidad then raise exception 'Ese horario se acaba de llenar. Elige otro, por favor.'; end if;
  insert into luna_dental.citas (clienta_id, servicio_id, inicio, fin) values (p_cl, s.id, ini, fin_) returning id into cid;
  return cid;
end $$;

-- ---------- funciones que llama la clienta ----------
create function luna_dental.servicios_lista() returns json language sql stable security definer set search_path = '' as $$
  select coalesce(json_agg(json_build_object('id', id, 'nombre', nombre, 'categoria', categoria, 'descripcion', descripcion,
    'duracion_min', duracion_min, 'precio', precio) order by orden), '[]'::json) from luna_dental.servicios where activo $$;

create function luna_dental.disponibilidad(p_servicio bigint, p_dia date) returns json language plpgsql stable security definer set search_path = '' as $$
declare s luna_dental.servicios; h luna_dental.horario; cf luna_dental.config; r json; hoy date := (now() at time zone 'America/Guayaquil')::date;
begin
  select * into cf from luna_dental.config where id = 1;
  select * into s from luna_dental.servicios where id = p_servicio and activo;
  if s.id is null or p_dia is null or p_dia < hoy or p_dia > hoy + cf.max_dias then return '[]'::json; end if;
  select * into h from luna_dental.horario where dia_semana = extract(isodow from p_dia)::int;
  if h.dia_semana is null then return '[]'::json; end if;
  select coalesce(json_agg(json_build_object('hora', to_char(t, 'HH24:MI'), 'libre', libre) order by t), '[]'::json) into r from (
    select t, (t at time zone 'America/Guayaquil') > now() + make_interval(mins => cf.anticipacion_min)
      and luna_dental.ocupadas(t at time zone 'America/Guayaquil', (t at time zone 'America/Guayaquil') + make_interval(mins => s.duracion_min)) < cf.capacidad as libre
    from generate_series(p_dia + h.abre, p_dia + h.cierra - make_interval(mins => s.duracion_min), make_interval(mins => cf.paso_min)) t) x;
  return r;
end $$;

-- Agenda sin tarjeta. NO devuelve token ni código: quien conozca un teléfono no puede apropiarse de la cuenta ajena.
-- El código de la tarjeta se entrega por WhatsApp al confirmar la cita (el personal lo ve en el panel).
create function luna_dental.agendar(p_nombre text, p_telefono text, p_servicio bigint, p_dia date, p_hora text) returns json
language plpgsql security definer set search_path = '' as $$
declare tel text := luna_dental.tel(p_telefono); cl luna_dental.clientas; cid bigint;
begin
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe tu nombre y apellido.'; end if;
  if tel = '' then raise exception 'Escribe un celular válido (09...).'; end if;
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  select * into cl from luna_dental.clientas where telefono = tel;
  if not found then
    if (select count(*) from luna_dental.clientas where creado > now() - interval '1 hour') >= (select max_registros_hora from luna_dental.config where id = 1) then
      raise exception 'Hay muchas solicitudes en este momento. Intenta en un rato o escríbenos por WhatsApp.'; end if;
    insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), trim(left(p_nombre, 80)), tel) returning * into cl;
  end if;
  cid := luna_dental._reservar(cl.id, p_servicio, p_dia, p_hora);
  return json_build_object('ok', true, 'cita', cid, 'estado', 'pendiente');
end $$;

-- Agenda con la sesión de una clienta que ya entró a su tarjeta
create function luna_dental.agendar_token(p_token text, p_servicio bigint, p_dia date, p_hora text) returns json
language plpgsql security definer set search_path = '' as $$
declare cl luna_dental.clientas; cid bigint;
begin
  select * into cl from luna_dental.clientas where token = luna_dental.a_uuid(p_token);
  if not found then raise exception 'No encontramos tu tarjeta.'; end if;
  cid := luna_dental._reservar(cl.id, p_servicio, p_dia, p_hora);
  return json_build_object('ok', true, 'cita', cid, 'estado', 'pendiente');
end $$;

-- Acceso con código + 4 últimos dígitos. 5 fallos por código = bloqueo 30 min; tope global de fallos contra barridos (§4.8).
-- Devuelve {ok:false} en vez de lanzar error: un error deshace la transacción y se perdería el conteo del intento.
create function luna_dental.acceder(p_codigo text, p_ultimos4 text) returns json language plpgsql security definer set search_path = '' as $$
declare k text := 'cod:' || upper(trim(coalesce(p_codigo, ''))); g text := 'global'; tk uuid; i luna_dental.intentos; ult text := regexp_replace(coalesce(p_ultimos4, ''), '\D', '', 'g');
begin
  perform pg_advisory_xact_lock(hashtext('luna_dental.intentos'));
  if exists (select 1 from luna_dental.intentos where clave in (k, g) and bloqueado_hasta > now()) then
    return json_build_object('ok', false, 'bloqueado', true, 'mensaje', 'Demasiados intentos. Prueba de nuevo en un rato o escríbenos por WhatsApp.');
  end if;
  select token into tk from luna_dental.clientas where upper(codigo) = upper(trim(coalesce(p_codigo, ''))) and length(ult) = 4 and right(telefono, 4) = ult;
  if tk is not null then
    delete from luna_dental.intentos where clave = k;
    return json_build_object('ok', true, 'token', tk);
  end if;
  -- fallo: contar por código (ventana 15 min, bloqueo 30 min a los 5) y global (ventana 10 min, bloqueo 10 min a los 60)
  insert into luna_dental.intentos (clave, n, desde) values (k, 1, now())
    on conflict (clave) do update set n = case when luna_dental.intentos.desde < now() - interval '15 minutes' then 1 else luna_dental.intentos.n + 1 end,
      desde = case when luna_dental.intentos.desde < now() - interval '15 minutes' then now() else luna_dental.intentos.desde end
    returning * into i;
  if i.n >= 5 then update luna_dental.intentos set bloqueado_hasta = now() + interval '30 minutes', n = 0 where clave = k; end if;
  insert into luna_dental.intentos (clave, n, desde) values (g, 1, now())
    on conflict (clave) do update set n = case when luna_dental.intentos.desde < now() - interval '10 minutes' then 1 else luna_dental.intentos.n + 1 end,
      desde = case when luna_dental.intentos.desde < now() - interval '10 minutes' then now() else luna_dental.intentos.desde end
    returning * into i;
  if i.n >= 60 then update luna_dental.intentos set bloqueado_hasta = now() + interval '10 minutes', n = 0 where clave = g; end if;
  delete from luna_dental.intentos where desde < now() - interval '1 day' and coalesce(bloqueado_hasta, now()) < now();
  return json_build_object('ok', false, 'mensaje', 'Código o últimos 4 dígitos incorrectos.');
end $$;

create function luna_dental.tarjeta(p_token text) returns json language plpgsql stable security definer set search_path = '' as $$
declare i bigint;
begin
  select id into i from luna_dental.clientas where token = luna_dental.a_uuid(p_token);
  if i is null then raise exception 'No encontramos tu tarjeta.'; end if;
  return luna_dental.json_clienta(i, false);
end $$;

create function luna_dental.cancelar(p_token text, p_cita bigint) returns void language plpgsql security definer set search_path = '' as $$
declare c luna_dental.citas;
begin
  select ct.* into c from luna_dental.citas ct join luna_dental.clientas cl on cl.id = ct.clienta_id
  where ct.id = p_cita and cl.token = luna_dental.a_uuid(p_token) for update of ct;
  if not found then raise exception 'Cita no encontrada.'; end if;
  if c.estado not in ('pendiente', 'confirmada') then raise exception 'Esta cita ya no se puede cancelar.'; end if;
  if c.inicio < now() + interval '6 hours' then raise exception 'Faltan menos de 6 horas. Escríbenos por WhatsApp.'; end if;
  update luna_dental.citas set estado = 'cancelada' where id = p_cita;
end $$;

create function luna_dental.ping() returns boolean language sql set search_path = '' as $$ select true $$;
