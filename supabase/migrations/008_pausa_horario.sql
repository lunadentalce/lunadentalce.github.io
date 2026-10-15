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
