-- 021 · Agenda del personal sin restricción de horario: el personal (recepción, doctores, administración) puede agendar y mover citas a cualquier hora, también en la pausa
-- del almuerzo o pasada la hora de cierre. Lo único que se sigue cuidando es el cupo: no se agenda sobre el límite de sillones (config.capacidad, que edita la dueña en Ajustes).
-- La web pública (disponibilidad y agendar del módulo de citas) conserva el horario y la pausa. Reemplaza _validar_horario (009) y solicitud_agendar (006).
-- Orden de instalación: después de 020. Todo calificado con el schema del cliente.

create or replace function luna_dental._validar_horario(p_dia date, p_hora text, p_dur int) returns void language plpgsql stable set search_path = '' as $$
begin
  if p_dia is null or p_hora is null or p_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora no válida.'; end if;
end $$;

create or replace function luna_dental.solicitud_agendar(p_id bigint, p_servicio bigint, p_dia date, p_hora text, p_doctor bigint) returns json
language plpgsql security definer set search_path = '' as $$
declare s luna_dental.solicitudes; sv luna_dental.servicios; cl luna_dental.clientas; cid bigint; ini timestamptz; fin_ timestamptz;
  hoy date := (now() at time zone 'America/Guayaquil')::date;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  select * into s from luna_dental.solicitudes where id = p_id for update;
  if not found or s.estado <> 'nueva' then raise exception 'Solicitud no encontrada o ya atendida.'; end if;
  if not (p_servicio = any (s.servicio_ids)) then raise exception 'Elige uno de los tratamientos de la solicitud.'; end if;
  select * into sv from luna_dental.servicios where id = p_servicio and activo;
  if not found then raise exception 'Tratamiento no disponible.'; end if;
  if p_dia is null or p_dia < hoy then raise exception 'Elige un día desde hoy.'; end if;
  perform luna_dental._validar_horario(p_dia, p_hora, sv.duracion_min);
  ini := (p_dia + p_hora::time) at time zone 'America/Guayaquil'; fin_ := ini + make_interval(mins => sv.duracion_min);
  perform pg_advisory_xact_lock(hashtext('luna_dental.citas'));
  if luna_dental.ocupadas(ini, fin_) >= (select capacidad from luna_dental.config where id = 1) then raise exception 'Ese horario se acaba de llenar. Elige otro, por favor.'; end if;
  select * into cl from luna_dental.clientas where telefono = s.telefono;
  if not found then
    insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), s.nombre, s.telefono) returning * into cl;
  end if;
  insert into luna_dental.citas (clienta_id, servicio_id, inicio, fin, estado, doctor_id) values (cl.id, sv.id, ini, fin_, 'confirmada', p_doctor) returning id into cid;
  update luna_dental.solicitudes set estado = 'agendada', cita_id = cid, atendida_por = auth.uid() where id = p_id;
  return json_build_object('cita', cid, 'nombre', cl.nombre, 'telefono', cl.telefono);
end $$;
