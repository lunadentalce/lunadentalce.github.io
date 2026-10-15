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
