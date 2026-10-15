-- Módulo de citas · 003 funciones del personal (solo authenticated). Cada una verifica es_staff()/es_admin() por dentro.
-- El personal identifica a la clienta con 'ref' = lo que muestra el QR (qr_token) o su código. Nunca con el token de sesión de la clienta.

create function luna_dental.yo() returns json language sql stable security definer set search_path = '' as $$
  select json_build_object('nombre', nombre, 'rol', rol) from luna_dental.staff where user_id = auth.uid() $$;

create function luna_dental.agenda(p_desde date, p_hasta date) returns json language plpgsql stable security definer set search_path = '' as $$
declare r json; meta int := (select sellos_meta from luna_dental.config where id = 1);
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select coalesce(json_agg(json_build_object(
    'id', c.id, 'estado', c.estado,
    'dia', to_char(c.inicio at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
    'hora', to_char(c.inicio at time zone 'America/Guayaquil', 'HH24:MI'),
    'hora_fin', to_char(c.fin at time zone 'America/Guayaquil', 'HH24:MI'),
    'servicio_id', sv.id, 'servicio', sv.nombre, 'categoria', sv.categoria, 'duracion', sv.duracion_min,
    'nombre', cl.nombre, 'telefono', cl.telefono, 'codigo', cl.codigo, 'ref', cl.qr_token,
    'progreso', luna_dental.prog(cl.id, sv.id), 'gratis', sv.fidelidad and luna_dental.prog(cl.id, sv.id) >= meta,
    'sellada', exists (select 1 from luna_dental.sellos s where s.cita_id = c.id and not s.anulado), 'creado', c.creado
  ) order by c.inicio), '[]'::json) into r
  from luna_dental.citas c join luna_dental.clientas cl on cl.id = c.clienta_id join luna_dental.servicios sv on sv.id = c.servicio_id
  where c.inicio >= p_desde::timestamp at time zone 'America/Guayaquil' and c.inicio < (p_hasta + 1)::timestamp at time zone 'America/Guayaquil';
  return r;
end $$;

create function luna_dental.pendientes() returns json language plpgsql stable security definer set search_path = '' as $$
declare r json;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select coalesce(json_agg(json_build_object(
    'id', c.id, 'estado', c.estado,
    'dia', to_char(c.inicio at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
    'hora', to_char(c.inicio at time zone 'America/Guayaquil', 'HH24:MI'),
    'hora_fin', to_char(c.fin at time zone 'America/Guayaquil', 'HH24:MI'),
    'servicio', sv.nombre, 'nombre', cl.nombre, 'telefono', cl.telefono, 'codigo', cl.codigo, 'creado', c.creado
  ) order by c.inicio), '[]'::json) into r
  from luna_dental.citas c join luna_dental.clientas cl on cl.id = c.clienta_id join luna_dental.servicios sv on sv.id = c.servicio_id
  where c.estado = 'pendiente' and c.fin > now();
  return r;
end $$;

create function luna_dental.buscar(p_q text) returns json language plpgsql stable security definer set search_path = '' as $$
declare d text := ltrim(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '0'); r json;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select coalesce(json_agg(x), '[]'::json) into r from (
    select qr_token as ref, codigo, nombre, telefono from luna_dental.clientas
    where (length(trim(p_q)) >= 2 and nombre ilike '%' || trim(p_q) || '%')
       or (length(d) >= 4 and telefono like '%' || d || '%')
       or upper(codigo) = upper(trim(p_q))
    order by nombre limit 25) x;
  return r;
end $$;

create function luna_dental.ficha(p_ref text) returns json language plpgsql stable security definer set search_path = '' as $$
declare i bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  i := luna_dental.clienta_por_ref(p_ref);
  if i is null then raise exception 'No encontramos esa tarjeta.'; end if;
  return luna_dental.json_clienta(i, true);
end $$;

create function luna_dental.clientas_lista() returns json language plpgsql stable security definer set search_path = '' as $$
declare r json; meta int := (select sellos_meta from luna_dental.config where id = 1);
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select coalesce(json_agg(x order by x.ultima desc nulls last), '[]'::json) into r from (
    select c.qr_token as ref, c.codigo, c.nombre, c.telefono, c.creado,
      (select max(creado) from luna_dental.sellos s where s.clienta_id = c.id and not s.anulado) ultima,
      (select count(*) from luna_dental.sellos s where s.clienta_id = c.id and not s.anulado) sesiones,
      (select count(*) from luna_dental.servicios sv where sv.activo and sv.fidelidad and luna_dental.prog(c.id, sv.id) >= meta) gratis
    from luna_dental.clientas c) x;
  return r;
end $$;

create function luna_dental.registrar(p_nombre text, p_telefono text) returns json language plpgsql security definer set search_path = '' as $$
declare tel text := luna_dental.tel(p_telefono); cl luna_dental.clientas;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre.'; end if;
  if tel = '' then raise exception 'Escribe un celular válido (09...).'; end if;
  select * into cl from luna_dental.clientas where telefono = tel;
  if found then raise exception 'Ese celular ya tiene tarjeta (%).', cl.codigo; end if;
  insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), trim(left(p_nombre, 80)), tel) returning * into cl;
  return luna_dental.json_clienta(cl.id, true);
end $$;

create function luna_dental.cita_estado(p_cita bigint, p_estado text) returns void language plpgsql security definer set search_path = '' as $$
declare c luna_dental.citas;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_estado not in ('pendiente', 'confirmada', 'atendida', 'cancelada', 'no_vino') then raise exception 'Estado no válido.'; end if;
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  select * into c from luna_dental.citas where id = p_cita for update;
  if not found then raise exception 'Cita no encontrada.'; end if;
  if p_estado in ('pendiente', 'confirmada') and c.estado not in ('pendiente', 'confirmada')
     and luna_dental.ocupadas(c.inicio, c.fin, c.id) >= (select capacidad from luna_dental.config where id = 1) then
    raise exception 'Ese horario ya está lleno. Muévela a otra hora.'; end if;
  update luna_dental.citas set estado = p_estado where id = p_cita;
end $$;

create function luna_dental.mover_cita(p_cita bigint, p_dia date, p_hora text) returns void language plpgsql security definer set search_path = '' as $$
declare c luna_dental.citas; ini timestamptz; dur interval;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_hora is null or p_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora no válida.'; end if;
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  select * into c from luna_dental.citas where id = p_cita for update;
  if not found then raise exception 'Cita no encontrada.'; end if;
  ini := (p_dia + p_hora::time) at time zone 'America/Guayaquil'; dur := c.fin - c.inicio;
  if luna_dental.ocupadas(ini, ini + dur, c.id) >= (select capacidad from luna_dental.config where id = 1) then raise exception 'Ese horario ya está lleno.'; end if;
  update luna_dental.citas set inicio = ini, fin = ini + dur, estado = case when estado in ('cancelada', 'no_vino') then 'confirmada' else estado end where id = p_cita;
end $$;

-- Cita creada por el personal (por teléfono o presencial): nace confirmada
create function luna_dental.cita_staff(p_nombre text, p_telefono text, p_servicio bigint, p_dia date, p_hora text) returns json
language plpgsql security definer set search_path = '' as $$
declare tel text := luna_dental.tel(p_telefono); cl luna_dental.clientas; cid bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if tel = '' then raise exception 'Escribe un celular válido (09...).'; end if;
  select * into cl from luna_dental.clientas where telefono = tel;
  if not found then
    if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre.'; end if;
    insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), trim(left(p_nombre, 80)), tel) returning * into cl;
  end if;
  cid := luna_dental._reservar(cl.id, p_servicio, p_dia, p_hora);
  update luna_dental.citas set estado = 'confirmada' where id = cid;
  return json_build_object('cita', cid, 'codigo', cl.codigo, 'nombre', cl.nombre);
end $$;

create function luna_dental.sellar(p_ref text, p_servicio bigint, p_cita bigint default null) returns json language plpgsql security definer set search_path = '' as $$
declare i bigint; cl luna_dental.clientas; sv luna_dental.servicios; meta int := (select sellos_meta from luna_dental.config where id = 1);
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  i := luna_dental.clienta_por_ref(p_ref);
  if i is null then raise exception 'No encontramos esa tarjeta.'; end if;
  select * into cl from luna_dental.clientas where id = i for update;
  select * into sv from luna_dental.servicios where id = p_servicio;
  if not found or not sv.fidelidad then raise exception 'Este servicio no suma sellos.'; end if;
  if luna_dental.prog(cl.id, sv.id) >= meta then raise exception 'Esta sesión es GRATIS. Usa «Canjear gratis».'; end if;
  if p_cita is not null then
    if not exists (select 1 from luna_dental.citas where id = p_cita and clienta_id = cl.id) then raise exception 'Esa cita no es de esta clienta.'; end if;
    if exists (select 1 from luna_dental.sellos where cita_id = p_cita and not anulado) then raise exception 'Esa cita ya fue sellada.'; end if;
    update luna_dental.citas set estado = 'atendida' where id = p_cita;
  end if;
  insert into luna_dental.sellos (clienta_id, servicio_id, cita_id, tipo, staff_id) values (cl.id, sv.id, p_cita, 'sello', auth.uid());
  return json_build_object('nombre', cl.nombre, 'servicio', sv.nombre, 'progreso', luna_dental.prog(cl.id, sv.id), 'meta', meta, 'gratis', luna_dental.prog(cl.id, sv.id) >= meta);
end $$;

create function luna_dental.canjear(p_ref text, p_servicio bigint, p_cita bigint default null) returns json language plpgsql security definer set search_path = '' as $$
declare i bigint; cl luna_dental.clientas; sv luna_dental.servicios; meta int := (select sellos_meta from luna_dental.config where id = 1);
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  i := luna_dental.clienta_por_ref(p_ref);
  if i is null then raise exception 'No encontramos esa tarjeta.'; end if;
  select * into cl from luna_dental.clientas where id = i for update;
  select * into sv from luna_dental.servicios where id = p_servicio;
  if not found then raise exception 'Servicio no encontrado.'; end if;
  if luna_dental.prog(cl.id, sv.id) < meta then raise exception 'Aún no completa % sesiones de este servicio.', meta; end if;
  if p_cita is not null then
    if not exists (select 1 from luna_dental.citas where id = p_cita and clienta_id = cl.id) then raise exception 'Esa cita no es de esta clienta.'; end if;
    if exists (select 1 from luna_dental.sellos where cita_id = p_cita and not anulado) then raise exception 'Esa cita ya fue sellada.'; end if;
    update luna_dental.citas set estado = 'atendida' where id = p_cita;
  end if;
  insert into luna_dental.sellos (clienta_id, servicio_id, cita_id, tipo, staff_id) values (cl.id, sv.id, p_cita, 'canje', auth.uid());
  return json_build_object('nombre', cl.nombre, 'servicio', sv.nombre, 'progreso', luna_dental.prog(cl.id, sv.id), 'meta', meta);
end $$;

create function luna_dental.anular(p_sello bigint) returns void language plpgsql security definer set search_path = '' as $$
declare s luna_dental.sellos;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select * into s from luna_dental.sellos where id = p_sello for update;
  if not found or s.anulado then raise exception 'Ese sello ya está anulado.'; end if;
  if not luna_dental.es_admin() and (s.staff_id is distinct from auth.uid() or now() - s.creado > interval '30 minutes') then
    raise exception 'Solo puedes anular tus sellos de los últimos 30 minutos.'; end if;
  update luna_dental.sellos set anulado = true, anulado_por = auth.uid(), anulado_en = now() where id = p_sello;
  if s.cita_id is not null then update luna_dental.citas set estado = 'confirmada' where id = s.cita_id and estado = 'atendida'; end if;
end $$;

create function luna_dental.resumen() returns json language plpgsql stable security definer set search_path = '' as $$
declare hoy date := (now() at time zone 'America/Guayaquil')::date; d0 timestamptz; d1 timestamptz; m0 timestamptz;
  cf luna_dental.config; h luna_dental.horario; abiertos int; r json;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  d0 := hoy::timestamp at time zone 'America/Guayaquil'; d1 := d0 + interval '1 day';
  m0 := date_trunc('month', hoy)::timestamp at time zone 'America/Guayaquil';
  select * into cf from luna_dental.config where id = 1;
  select * into h from luna_dental.horario where dia_semana = extract(isodow from hoy)::int;
  abiertos := coalesce(extract(epoch from (h.cierra - h.abre)) / 60, 0)::int * cf.capacidad;
  select json_build_object(
    'hoy', json_build_object(
      'citas', (select count(*) from luna_dental.citas where inicio >= d0 and inicio < d1 and estado in ('pendiente', 'confirmada', 'atendida')),
      'atendidas', (select count(*) from luna_dental.citas where inicio >= d0 and inicio < d1 and estado = 'atendida'),
      'sellos', (select count(*) from luna_dental.sellos where creado >= d0 and tipo = 'sello' and not anulado),
      'canjes', (select count(*) from luna_dental.sellos where creado >= d0 and tipo = 'canje' and not anulado),
      'ocupacion', case when abiertos > 0 then round(100.0 * (select coalesce(sum(extract(epoch from (fin - inicio)) / 60), 0)
          from luna_dental.citas where inicio >= d0 and inicio < d1 and estado in ('pendiente', 'confirmada', 'atendida')) / abiertos) else 0 end),
    'por_confirmar', (select count(*) from luna_dental.citas where estado = 'pendiente' and fin > now()),
    'mes', json_build_object(
      'atendidas', (select count(*) from luna_dental.citas where inicio >= m0 and estado = 'atendida'),
      'no_vino', (select count(*) from luna_dental.citas where inicio >= m0 and estado = 'no_vino'),
      'canceladas', (select count(*) from luna_dental.citas where inicio >= m0 and estado = 'cancelada'),
      'sellos', (select count(*) from luna_dental.sellos where creado >= m0 and tipo = 'sello' and not anulado),
      'canjes', (select count(*) from luna_dental.sellos where creado >= m0 and tipo = 'canje' and not anulado),
      'nuevas', (select count(*) from luna_dental.clientas where creado >= m0)),
    'clientas', (select count(*) from luna_dental.clientas),
    'top', (select coalesce(json_agg(t), '[]'::json) from (
      select sv.nombre, count(*) n from luna_dental.citas c join luna_dental.servicios sv on sv.id = c.servicio_id
      where c.inicio >= m0 and c.estado in ('confirmada', 'atendida', 'pendiente') group by sv.nombre order by n desc limit 6) t),
    'semana', (select coalesce(json_agg(json_build_object('dia', to_char(d, 'YYYY-MM-DD'),
        'n', (select count(*) from luna_dental.citas c where c.estado in ('pendiente', 'confirmada', 'atendida')
              and c.inicio >= d::timestamp at time zone 'America/Guayaquil' and c.inicio < (d + 1)::timestamp at time zone 'America/Guayaquil')) order by d), '[]'::json)
      from generate_series(0, 6) k, lateral (select hoy + k as d) x),
    'gratis_listas', (select count(*) from luna_dental.clientas c cross join luna_dental.servicios sv
      where sv.activo and sv.fidelidad and luna_dental.prog(c.id, sv.id) >= cf.sellos_meta)
  ) into r;
  return r;
end $$;

-- ---------- administración (solo rol admin) ----------
create function luna_dental.config_admin() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  return json_build_object(
    'config', (select row_to_json(c) from luna_dental.config c),
    'servicios', (select coalesce(json_agg(s order by s.orden), '[]'::json) from luna_dental.servicios s),
    'horario', (select json_agg(json_build_object('dia', d, 'abre', to_char(h.abre, 'HH24:MI'), 'cierra', to_char(h.cierra, 'HH24:MI')) order by d)
      from generate_series(1, 7) d left join luna_dental.horario h on h.dia_semana = d),
    'equipo', case when luna_dental.es_admin() then (select coalesce(json_agg(json_build_object('user_id', s.user_id, 'nombre', s.nombre, 'rol', s.rol, 'email', u.email, 'yo', s.user_id = auth.uid()) order by s.nombre), '[]'::json)
      from luna_dental.staff s join auth.users u on u.id = s.user_id) end);
end $$;

create function luna_dental.config_guardar(p_capacidad int, p_meta int) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_capacidad < 1 or p_capacidad > 10 then raise exception 'Cabinas entre 1 y 10.'; end if;
  if p_meta < 2 or p_meta > 20 then raise exception 'Sellos entre 2 y 20.'; end if;
  update luna_dental.config set capacidad = p_capacidad, sellos_meta = p_meta where id = 1;
end $$;

create function luna_dental.servicio_guardar(p_id bigint, p_nombre text, p_categoria text, p_descripcion text, p_duracion int, p_precio text, p_fidelidad boolean, p_activo boolean) returns bigint
language plpgsql security definer set search_path = '' as $$
declare i bigint;
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre del servicio.'; end if;
  if p_duracion is null or p_duracion < 15 or p_duracion > 240 then raise exception 'Duración entre 15 y 240 min.'; end if;
  if p_id is null then
    insert into luna_dental.servicios (nombre, categoria, descripcion, duracion_min, precio, fidelidad, activo, orden)
    values (trim(p_nombre), coalesce(nullif(trim(p_categoria), ''), 'General'), nullif(trim(p_descripcion), ''), p_duracion,
      nullif(trim(p_precio), ''), coalesce(p_fidelidad, true), coalesce(p_activo, true), (select coalesce(max(orden), 0) + 1 from luna_dental.servicios)) returning id into i;
  else
    update luna_dental.servicios set nombre = trim(p_nombre), categoria = coalesce(nullif(trim(p_categoria), ''), 'General'),
      descripcion = nullif(trim(p_descripcion), ''), duracion_min = p_duracion, precio = nullif(trim(p_precio), ''),
      fidelidad = coalesce(p_fidelidad, true), activo = coalesce(p_activo, true) where id = p_id returning id into i;
  end if;
  return i;
end $$;

create function luna_dental.horario_guardar(p_dia int, p_abre text, p_cierra text) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_dia not between 1 and 7 then raise exception 'Día no válido.'; end if;
  if nullif(p_abre, '') is null or nullif(p_cierra, '') is null then delete from luna_dental.horario where dia_semana = p_dia; return; end if;
  if p_cierra::time <= p_abre::time then raise exception 'La hora de cierre debe ser después de la de apertura.'; end if;
  insert into luna_dental.horario values (p_dia, p_abre::time, p_cierra::time)
    on conflict (dia_semana) do update set abre = excluded.abre, cierra = excluded.cierra;
end $$;

-- El usuario se crea ANTES en Supabase › Authentication › Add user (con los registros públicos desactivados, §4.10)
create function luna_dental.equipo_guardar(p_email text, p_nombre text, p_rol text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_rol not in ('admin', 'recepcion') then raise exception 'Rol no válido.'; end if;
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then raise exception 'Ese correo no tiene usuario. Créalo primero en Supabase › Authentication › Add user.'; end if;
  insert into luna_dental.staff (user_id, nombre, rol) values (u, coalesce(nullif(trim(p_nombre), ''), split_part(p_email, '@', 1)), p_rol)
    on conflict (user_id) do update set nombre = excluded.nombre, rol = excluded.rol;
end $$;

create function luna_dental.equipo_quitar(p_user uuid) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_user = auth.uid() then raise exception 'No puedes quitarte tu propio acceso.'; end if;
  delete from luna_dental.staff where user_id = p_user;
end $$;
