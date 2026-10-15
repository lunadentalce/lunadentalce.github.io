-- Luna Dental · instalación completa del schema luna_dental (migraciones en un solo archivo, en orden).
-- Pégalo entero en Supabase › SQL Editor y pulsa Run. Solo toca el schema luna_dental; no cambia nada de public ni de otros clientes.
-- Antes: confirma que el schema luna_dental NO existe. Después: corre supabase/seed.sql.

-- ===== 001_esquema.sql =====
-- Módulo de citas y tarjeta de sellos · 001 esquema.
-- Se aplica con scripts/migraciones-modulo.py citas <schema>, que reemplaza luna_dental por el schema del cliente (ej.: dermabelle).
-- Reglas de CLAUDE.md §4: RLS en todas las tablas y SIN políticas (anon/authenticated nunca leen ni escriben tablas directo: todo pasa por funciones).
create schema if not exists luna_dental;

create table luna_dental.config (
  id int primary key default 1 check (id = 1),
  prefijo text not null default 'CL' check (prefijo ~ '^[A-Z]{2,4}$'),
  capacidad int not null default 1 check (capacidad between 1 and 10),          -- cabinas o puestos en paralelo
  paso_min int not null default 30 check (paso_min between 10 and 120),
  sellos_meta int not null default 5 check (sellos_meta between 2 and 20),
  anticipacion_min int not null default 60 check (anticipacion_min between 0 and 1440),
  max_dias int not null default 60 check (max_dias between 1 and 365),
  max_citas_activas int not null default 3 check (max_citas_activas between 1 and 10),   -- por clienta
  max_citas_hora int not null default 40 check (max_citas_hora between 1 and 500),       -- topes globales contra abuso
  max_registros_hora int not null default 20 check (max_registros_hora between 1 and 500)
);
insert into luna_dental.config default values;

create table luna_dental.horario (
  dia_semana int primary key check (dia_semana between 1 and 7),   -- 1 = lunes … 7 = domingo (isodow)
  abre time not null,
  cierra time not null,
  check (cierra > abre)
);

create table luna_dental.staff (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nombre text not null,
  rol text not null check (rol in ('admin', 'recepcion'))
);

create table luna_dental.servicios (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  categoria text not null default 'General',
  descripcion text,
  duracion_min int not null check (duracion_min between 15 and 240),
  precio text,
  fidelidad boolean not null default true,       -- suma sellos hacia la sesión gratis
  orden int not null default 0,
  activo boolean not null default true
);

create table luna_dental.clientas (
  id bigint generated always as identity primary key,
  token uuid not null unique default gen_random_uuid(),                                         -- sesión de la clienta: NUNCA se muestra en el QR
  qr_token text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16), -- lo que muestra el QR: solo sirve al personal (§4.7)
  codigo text not null unique,
  nombre text not null check (length(trim(nombre)) >= 2),
  telefono text not null unique check (telefono ~ '^593[0-9]{9}$'),                              -- normalizado 593XXXXXXXXX (§4.12)
  creado timestamptz not null default now()
);

create table luna_dental.citas (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  servicio_id bigint not null references luna_dental.servicios (id),
  inicio timestamptz not null,
  fin timestamptz not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'confirmada', 'atendida', 'cancelada', 'no_vino')),
  creado timestamptz not null default now(),
  check (fin > inicio)
);
create index citas_inicio_idx on luna_dental.citas (inicio);
create index citas_clienta_idx on luna_dental.citas (clienta_id, estado);

-- Sellos y canjes: movimientos que otorgan valor. Inmutables: se corrigen con anulación (§4.9).
create table luna_dental.sellos (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  servicio_id bigint not null references luna_dental.servicios (id),
  cita_id bigint references luna_dental.citas (id),
  tipo text not null check (tipo in ('sello', 'canje')),
  staff_id uuid not null references auth.users (id),
  anulado boolean not null default false,
  anulado_por uuid references auth.users (id),
  anulado_en timestamptz,
  creado timestamptz not null default now()
);
create unique index sellos_una_por_cita on luna_dental.sellos (cita_id) where cita_id is not null and not anulado;
create index sellos_clienta_idx on luna_dental.sellos (clienta_id, servicio_id);

create function luna_dental._sellos_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Los sellos no se borran: se anulan.'; end if;
  if old.anulado or new.anulado is not true
     or (old.clienta_id, old.servicio_id, old.cita_id, old.tipo, old.staff_id, old.creado)
        is distinct from (new.clienta_id, new.servicio_id, new.cita_id, new.tipo, new.staff_id, new.creado) then
    raise exception 'Un sello solo se puede anular.';
  end if;
  return new;
end $$;
create trigger sellos_inmutable before update or delete on luna_dental.sellos for each row execute function luna_dental._sellos_inmutable();

-- Intentos fallidos de acceso con código + 4 dígitos (§4.8)
create table luna_dental.intentos (
  clave text primary key,
  n int not null default 0,
  desde timestamptz not null default now(),
  bloqueado_hasta timestamptz
);

alter table luna_dental.config enable row level security;
alter table luna_dental.horario enable row level security;
alter table luna_dental.staff enable row level security;
alter table luna_dental.servicios enable row level security;
alter table luna_dental.clientas enable row level security;
alter table luna_dental.citas enable row level security;
alter table luna_dental.sellos enable row level security;
alter table luna_dental.intentos enable row level security;
revoke all on all tables in schema luna_dental from public, anon, authenticated;

-- ===== 002_funciones_cliente.sql =====
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

-- ===== 003_funciones_personal.sql =====
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

-- ===== 004_permisos.sql =====
-- Módulo de citas · 004 permisos (§4.3): primero se revoca TODO a public/anon/authenticated y luego se concede solo lo necesario.
-- Postgres concede EXECUTE a PUBLIC por defecto en cada función nueva; por eso el revoke va explícito.
revoke all on all functions in schema luna_dental from public, anon, authenticated;
alter default privileges in schema luna_dental revoke execute on functions from public, anon, authenticated;
grant usage on schema luna_dental to anon, authenticated;

-- La clienta (sin sesión de Supabase): solo estas 8
grant execute on function
  luna_dental.ping(),
  luna_dental.servicios_lista(),
  luna_dental.disponibilidad(bigint, date),
  luna_dental.agendar(text, text, bigint, date, text),
  luna_dental.agendar_token(text, bigint, date, text),
  luna_dental.acceder(text, text),
  luna_dental.tarjeta(text),
  luna_dental.cancelar(text, bigint)
to anon, authenticated;

-- El personal (con sesión): las funciones comprueban es_staff()/es_admin() por dentro
grant execute on function
  luna_dental.yo(), luna_dental.agenda(date, date), luna_dental.pendientes(), luna_dental.buscar(text), luna_dental.ficha(text),
  luna_dental.clientas_lista(), luna_dental.registrar(text, text), luna_dental.cita_estado(bigint, text), luna_dental.mover_cita(bigint, date, text),
  luna_dental.cita_staff(text, text, bigint, date, text), luna_dental.sellar(text, bigint, bigint), luna_dental.canjear(text, bigint, bigint),
  luna_dental.anular(bigint), luna_dental.resumen(), luna_dental.config_admin(), luna_dental.config_guardar(int, int),
  luna_dental.servicio_guardar(bigint, text, text, text, int, text, boolean, boolean), luna_dental.horario_guardar(int, text, text),
  luna_dental.equipo_guardar(text, text, text), luna_dental.equipo_quitar(uuid)
to authenticated;
-- Ayudas internas (tel, es_staff, es_admin, codigo, prog, ocupadas, a_uuid, clienta_por_ref, json_clienta, _reservar): sin permiso para nadie.
-- Las llaman las funciones de arriba, que corren con los permisos de su dueño (security definer).

-- ===== 005_clinica_esquema.sql =====
-- Módulo de clínica dental · 005 esquema (se aplica DESPUÉS de las migraciones 001–004 del módulo citas).
-- Se instala con scripts/migraciones-modulo.py clinica <cliente>, que copia citas (001–004) y luego estas y reemplaza luna_dental.
-- Reglas de CLAUDE.md §4: RLS en todas las tablas y SIN políticas; todo pasa por funciones security definer.
-- NO guarda historia clínica ni diagnósticos: solo datos comerciales (agenda, caja, presupuestos). Los datos de salud son sensibles
-- (Ley Orgánica de Protección de Datos Personales) y se activan aparte, con consentimiento y almacenamiento definidos con la clínica.

alter table luna_dental.config
  add column max_solicitudes_hora int not null default 20 check (max_solicitudes_hora between 1 and 500),
  add column max_solicitudes_tel_dia int not null default 3 check (max_solicitudes_tel_dia between 1 and 20);

create table luna_dental.doctores (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  especialidad text,
  color text not null default '#B8933A' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  activo boolean not null default true,
  orden int not null default 0
);

alter table luna_dental.citas add column doctor_id bigint references luna_dental.doctores (id);
create index citas_doctor_idx on luna_dental.citas (doctor_id, inicio);

-- Tarifario: el precio de un presupuesto sale de aquí, nunca del navegador (§4.5)
create table luna_dental.tarifario (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  precio numeric(10, 2) not null check (precio >= 0),
  activo boolean not null default true,
  orden int not null default 0
);

-- Solicitudes de cita que llegan de la web: el personal las convierte en cita con hora exacta
create table luna_dental.solicitudes (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  telefono text not null check (telefono ~ '^593[0-9]{9}$'),
  servicio_ids bigint[] not null check (cardinality(servicio_ids) between 1 and 4),
  dia date not null,
  franja text not null check (franja in ('manana', 'tarde', 'cualquiera')),
  para_menor boolean not null default false,
  representante text,                                         -- quien autoriza si el paciente es menor de edad
  consentimiento_en timestamptz not null,                     -- cuándo aceptó el tratamiento de sus datos
  estado text not null default 'nueva' check (estado in ('nueva', 'agendada', 'descartada')),
  cita_id bigint references luna_dental.citas (id),
  atendida_por uuid references auth.users (id),
  creado timestamptz not null default now(),
  check (not para_menor or length(trim(coalesce(representante, ''))) >= 2)
);
create index solicitudes_estado_idx on luna_dental.solicitudes (estado, creado);
create index solicitudes_tel_idx on luna_dental.solicitudes (telefono, creado);

-- Caja: movimientos inmutables; se corrigen con anulación (§4.9)
create table luna_dental.caja (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  descripcion text not null check (length(trim(descripcion)) >= 2),
  importe numeric(10, 2) not null check (importe > 0 and importe <= 100000),
  tipo text not null check (tipo in ('ing', 'egr')),
  doctor_id bigint references luna_dental.doctores (id),
  staff_id uuid not null references auth.users (id),
  anulado boolean not null default false,
  anulado_por uuid references auth.users (id),
  anulado_en timestamptz,
  motivo_anulacion text
);
create index caja_creado_idx on luna_dental.caja (creado);

create function luna_dental._caja_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Los movimientos de caja no se borran: se anulan.'; end if;
  if old.anulado or new.anulado is not true
     or (old.creado, old.descripcion, old.importe, old.tipo, old.doctor_id, old.staff_id)
        is distinct from (new.creado, new.descripcion, new.importe, new.tipo, new.doctor_id, new.staff_id) then
    raise exception 'Un movimiento de caja solo se puede anular.';
  end if;
  return new;
end $$;
create trigger caja_inmutable before update or delete on luna_dental.caja for each row execute function luna_dental._caja_inmutable();

-- Presupuestos: el contenido no cambia después de guardarlo; solo avanza su estado y su seguimiento
create table luna_dental.presupuestos (
  id bigint generated always as identity primary key,
  paciente text not null check (length(trim(paciente)) >= 2),
  clienta_id bigint references luna_dental.clientas (id),
  doctor_id bigint references luna_dental.doctores (id),
  descuento_pct int not null default 0 check (descuento_pct between 0 and 50),
  total numeric(10, 2) not null check (total >= 0),
  estado text not null default 'enviado' check (estado in ('enviado', 'aceptado', 'rechazado')),
  seguimiento date,
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now(),
  decidido_en timestamptz
);
create index presupuestos_estado_idx on luna_dental.presupuestos (estado, creado);

create table luna_dental.presupuesto_items (
  id bigint generated always as identity primary key,
  presupuesto_id bigint not null references luna_dental.presupuestos (id),
  tarifario_id bigint not null references luna_dental.tarifario (id),
  descripcion text not null,
  cant int not null check (cant between 1 and 20),
  precio numeric(10, 2) not null check (precio >= 0)
);
create index presupuesto_items_idx on luna_dental.presupuesto_items (presupuesto_id);

create function luna_dental._presupuesto_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_table_name = 'presupuesto_items' then raise exception 'Los renglones de un presupuesto no se editan ni se borran: se crea otro presupuesto.'; end if;
  if tg_op = 'DELETE' then raise exception 'Los presupuestos no se borran.'; end if;
  if (old.paciente, old.clienta_id, old.doctor_id, old.descuento_pct, old.total, old.staff_id, old.creado)
     is distinct from (new.paciente, new.clienta_id, new.doctor_id, new.descuento_pct, new.total, new.staff_id, new.creado) then
    raise exception 'El contenido de un presupuesto no se edita: se crea otro.'; end if;
  if old.estado <> 'enviado' and new.estado is distinct from old.estado then raise exception 'Un presupuesto ya decidido no cambia de estado.'; end if;
  return new;
end $$;
create trigger presupuestos_inmutable before update or delete on luna_dental.presupuestos for each row execute function luna_dental._presupuesto_inmutable();
create trigger presupuesto_items_inmutable before update or delete on luna_dental.presupuesto_items for each row execute function luna_dental._presupuesto_inmutable();

alter table luna_dental.doctores enable row level security;
alter table luna_dental.tarifario enable row level security;
alter table luna_dental.solicitudes enable row level security;
alter table luna_dental.caja enable row level security;
alter table luna_dental.presupuestos enable row level security;
alter table luna_dental.presupuesto_items enable row level security;
revoke all on all tables in schema luna_dental from public, anon, authenticated;

-- ===== 006_clinica_funciones.sql =====
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

-- ===== 007_clinica_permisos.sql =====
-- Módulo de clínica dental · 007 permisos (§4.3). Postgres concede EXECUTE a PUBLIC en cada función nueva: se revoca explícitamente en las de este módulo
-- (las del módulo citas ya quedaron resueltas en 004) y luego se concede solo lo necesario.
revoke all on function
  luna_dental.solicitar_cita(text, text, bigint[], date, text, boolean, text, boolean),
  luna_dental.doctores_lista(), luna_dental.doctor_guardar(bigint, text, text, text, boolean),
  luna_dental.tarifario_lista(), luna_dental.tarifario_guardar(bigint, text, numeric, boolean),
  luna_dental.solicitudes_lista(text), luna_dental.solicitud_descartar(bigint), luna_dental.solicitud_agendar(bigint, bigint, date, text, bigint),
  luna_dental.clinica_agenda(date, date), luna_dental.cita_doctor(bigint, bigint),
  luna_dental.caja_dia(date), luna_dental.caja_registrar(text, numeric, text, bigint), luna_dental.caja_anular(bigint, text),
  luna_dental.presupuesto_guardar(text, bigint, int, json, date), luna_dental.presupuestos_lista(text), luna_dental.presupuesto_estado(bigint, text),
  luna_dental.dueno_resumen(date, date), luna_dental._caja_inmutable(), luna_dental._presupuesto_inmutable()
from public, anon, authenticated;

-- El paciente (sin sesión): solo la solicitud de cita
grant execute on function luna_dental.solicitar_cita(text, text, bigint[], date, text, boolean, text, boolean) to anon, authenticated;

-- El personal (con sesión): cada función comprueba es_staff() / es_admin() por dentro
grant execute on function
  luna_dental.doctores_lista(), luna_dental.doctor_guardar(bigint, text, text, text, boolean),
  luna_dental.tarifario_lista(), luna_dental.tarifario_guardar(bigint, text, numeric, boolean),
  luna_dental.solicitudes_lista(text), luna_dental.solicitud_descartar(bigint), luna_dental.solicitud_agendar(bigint, bigint, date, text, bigint),
  luna_dental.clinica_agenda(date, date), luna_dental.cita_doctor(bigint, bigint),
  luna_dental.caja_dia(date), luna_dental.caja_registrar(text, numeric, text, bigint), luna_dental.caja_anular(bigint, text),
  luna_dental.presupuesto_guardar(text, bigint, int, json, date), luna_dental.presupuestos_lista(text), luna_dental.presupuesto_estado(bigint, text),
  luna_dental.dueno_resumen(date, date)
to authenticated;

-- ===== 008_pausa_horario.sql =====
-- Módulo de clínica dental · 008 pausa de almuerzo en el horario (reemplaza _reservar y disponibilidad del módulo citas, 002).
-- Cada día puede tener una pausa (pausa_ini–pausa_fin) en la que no se agenda: ni se ofrece en disponibilidad ni la acepta _reservar.
alter table luna_dental.horario add column pausa_ini time, add column pausa_fin time,
  add constraint horario_pausa_ok check ((pausa_ini is null and pausa_fin is null) or (pausa_ini is not null and pausa_fin > pausa_ini and pausa_ini >= abre and pausa_fin <= cierra));

create or replace function luna_dental._reservar(p_cl bigint, p_servicio bigint, p_dia date, p_hora text) returns bigint
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
  if h.pausa_ini is not null and m_ini < extract(hour from h.pausa_fin)::int * 60 + extract(minute from h.pausa_fin)::int
     and m_ini + s.duracion_min > extract(hour from h.pausa_ini)::int * 60 + extract(minute from h.pausa_ini)::int then
    raise exception 'Ese horario no está disponible (hora de almuerzo).'; end if;
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

create or replace function luna_dental.disponibilidad(p_servicio bigint, p_dia date) returns json language plpgsql stable security definer set search_path = '' as $$
declare s luna_dental.servicios; h luna_dental.horario; cf luna_dental.config; r json; hoy date := (now() at time zone 'America/Guayaquil')::date;
begin
  select * into cf from luna_dental.config where id = 1;
  select * into s from luna_dental.servicios where id = p_servicio and activo;
  if s.id is null or p_dia is null or p_dia < hoy or p_dia > hoy + cf.max_dias then return '[]'::json; end if;
  select * into h from luna_dental.horario where dia_semana = extract(isodow from p_dia)::int;
  if h.dia_semana is null then return '[]'::json; end if;
  select coalesce(json_agg(json_build_object('hora', to_char(t, 'HH24:MI'), 'libre', libre) order by t), '[]'::json) into r from (
    select t, (t at time zone 'America/Guayaquil') > now() + make_interval(mins => cf.anticipacion_min)
      and not (h.pausa_ini is not null and t::time < h.pausa_fin and (t + make_interval(mins => s.duracion_min))::time > h.pausa_ini)
      and luna_dental.ocupadas(t at time zone 'America/Guayaquil', (t at time zone 'America/Guayaquil') + make_interval(mins => s.duracion_min)) < cf.capacidad as libre
    from generate_series(p_dia + h.abre, p_dia + h.cierra - make_interval(mins => s.duracion_min), make_interval(mins => cf.paso_min)) t) x;
  return r;
end $$;

-- La pausa se edita con esta función (solo admin); sin pausa: horas vacías.
create function luna_dental.horario_pausa_guardar(p_dia int, p_ini text, p_fin text) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_dia not between 1 and 7 then raise exception 'Día no válido.'; end if;
  if nullif(p_ini, '') is null or nullif(p_fin, '') is null then update luna_dental.horario set pausa_ini = null, pausa_fin = null where dia_semana = p_dia; return; end if;
  update luna_dental.horario set pausa_ini = p_ini::time, pausa_fin = p_fin::time where dia_semana = p_dia;
  if not found then raise exception 'Primero define el horario de ese día.'; end if;
end $$;
revoke all on function luna_dental.horario_pausa_guardar(int, text, text) from public, anon, authenticated;
grant execute on function luna_dental.horario_pausa_guardar(int, text, text) to authenticated;

-- ===== 009_control_dueno.sql =====
-- Módulo de clínica dental · 009 control de la dueña: citas creadas por el personal, mover citas con validación de horario y pausa en la configuración.
-- Reemplaza mover_cita (003) y config_admin (003) con las mismas reglas y más validaciones.

-- Ayuda interna: el día debe atenderse, la cita debe caber en el horario y no cruzar la pausa de almuerzo.
create function luna_dental._validar_horario(p_dia date, p_hora text, p_dur int) returns void language plpgsql stable set search_path = '' as $$
declare h luna_dental.horario; m_ini int; m_abre int; m_cierra int;
begin
  if p_dia is null or p_hora is null or p_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora no válida.'; end if;
  select * into h from luna_dental.horario where dia_semana = extract(isodow from p_dia)::int;
  if not found then raise exception 'Ese día no atendemos.'; end if;
  m_ini := substr(p_hora, 1, 2)::int * 60 + substr(p_hora, 4, 2)::int;
  m_abre := extract(hour from h.abre)::int * 60 + extract(minute from h.abre)::int;
  m_cierra := extract(hour from h.cierra)::int * 60 + extract(minute from h.cierra)::int;
  if m_ini < m_abre or m_ini + p_dur > m_cierra then raise exception 'Ese horario está fuera del horario de atención.'; end if;
  if h.pausa_ini is not null and m_ini < extract(hour from h.pausa_fin)::int * 60 + extract(minute from h.pausa_fin)::int
     and m_ini + p_dur > extract(hour from h.pausa_ini)::int * 60 + extract(minute from h.pausa_ini)::int then
    raise exception 'Ese horario no está disponible (hora de almuerzo).'; end if;
end $$;

create or replace function luna_dental.mover_cita(p_cita bigint, p_dia date, p_hora text) returns void language plpgsql security definer set search_path = '' as $$
declare c luna_dental.citas; ini timestamptz; dur interval;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_hora is null or p_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora no válida.'; end if;
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  select * into c from luna_dental.citas where id = p_cita for update;
  if not found then raise exception 'Cita no encontrada.'; end if;
  dur := c.fin - c.inicio;
  perform luna_dental._validar_horario(p_dia, p_hora, (extract(epoch from dur) / 60)::int);
  ini := (p_dia + p_hora::time) at time zone 'America/Guayaquil';
  if luna_dental.ocupadas(ini, ini + dur, c.id) >= (select capacidad from luna_dental.config where id = 1) then raise exception 'Ese horario ya está lleno.'; end if;
  update luna_dental.citas set inicio = ini, fin = ini + dur, estado = case when estado in ('cancelada', 'no_vino') then 'confirmada' else estado end where id = p_cita;
end $$;

create or replace function luna_dental.config_admin() returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  return json_build_object(
    'config', (select row_to_json(c) from luna_dental.config c),
    'servicios', (select coalesce(json_agg(s order by s.orden), '[]'::json) from luna_dental.servicios s),
    'horario', (select json_agg(json_build_object('dia', d, 'abre', to_char(h.abre, 'HH24:MI'), 'cierra', to_char(h.cierra, 'HH24:MI'), 'pausa_ini', to_char(h.pausa_ini, 'HH24:MI'), 'pausa_fin', to_char(h.pausa_fin, 'HH24:MI')) order by d)
      from generate_series(1, 7) d left join luna_dental.horario h on h.dia_semana = d),
    'equipo', case when luna_dental.es_admin() then (select coalesce(json_agg(json_build_object('user_id', s.user_id, 'nombre', s.nombre, 'rol', s.rol, 'email', u.email, 'yo', s.user_id = auth.uid()) order by s.nombre), '[]'::json)
      from luna_dental.staff s join auth.users u on u.id = s.user_id) end);
end $$;

-- Cita creada por el personal (llamada, presencial): nace confirmada, con doctor. Valida horario, pausa y cupo.
create function luna_dental.cita_nueva(p_nombre text, p_telefono text, p_servicio bigint, p_dia date, p_hora text, p_doctor bigint) returns json
language plpgsql security definer set search_path = '' as $$
declare tel text := luna_dental.tel(p_telefono); s luna_dental.servicios; cl luna_dental.clientas; ini timestamptz; fin_ timestamptz; cid bigint;
  hoy date := (now() at time zone 'America/Guayaquil')::date;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if tel = '' then raise exception 'Escribe un celular válido (09...).'; end if;
  select * into s from luna_dental.servicios where id = p_servicio and activo;
  if not found then raise exception 'Tratamiento no disponible.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  if p_dia is null or p_dia < hoy then raise exception 'Elige un día desde hoy.'; end if;
  perform luna_dental._validar_horario(p_dia, p_hora, s.duracion_min);
  ini := (p_dia + p_hora::time) at time zone 'America/Guayaquil'; fin_ := ini + make_interval(mins => s.duracion_min);
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  if luna_dental.ocupadas(ini, fin_) >= (select capacidad from luna_dental.config where id = 1) then raise exception 'Ese horario ya está lleno.'; end if;
  select * into cl from luna_dental.clientas where telefono = tel;
  if not found then
    if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre del paciente.'; end if;
    insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), trim(left(p_nombre, 80)), tel) returning * into cl;
  end if;
  insert into luna_dental.citas (clienta_id, servicio_id, inicio, fin, estado, doctor_id) values (cl.id, s.id, ini, fin_, 'confirmada', p_doctor) returning id into cid;
  return json_build_object('cita', cid, 'nombre', cl.nombre, 'telefono', cl.telefono);
end $$;

revoke all on function luna_dental._validar_horario(date, text, int), luna_dental.cita_nueva(text, text, bigint, date, text, bigint) from public, anon, authenticated;
grant execute on function luna_dental.cita_nueva(text, text, bigint, date, text, bigint) to authenticated;
