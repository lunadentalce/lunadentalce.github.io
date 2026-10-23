-- 012 · Permisos: recepción ve y edita la ficha completa del paciente; los presupuestos quedan para doctores y administración.
-- Reemplazos numerados de funciones anteriores (misma firma, así que conservan sus permisos):
--   es_clinico() (010): ahora es todo el personal (administración, doctor y recepción). Con eso recepción abre y escribe la historia clínica,
--     el odontograma y la evolución, y las lecturas siguen quedando en la auditoría con el usuario que las hizo.
--   presupuesto_guardar (010) y presupuesto_estado (006): solo es_presupuestos() (administración y doctor). Recepción puede VER los presupuestos
--     (presupuestos_lista y la ficha no cambian), pero no crearlos ni aceptarlos/rechazarlos.
-- Los accesos, el tarifario, los doctores y el horario siguen siendo solo del administrador.
-- Orden de instalación: después de 011. Todo calificado con el schema del cliente.

create or replace function luna_dental.es_clinico() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from luna_dental.staff where user_id = auth.uid() and rol in ('admin', 'doctor', 'recepcion')) $$;

create function luna_dental.es_presupuestos() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from luna_dental.staff where user_id = auth.uid() and rol in ('admin', 'doctor')) $$;
revoke all on function luna_dental.es_presupuestos() from public, anon, authenticated;

create or replace function luna_dental.presupuesto_guardar(p_paciente text, p_doctor bigint, p_descuento int, p_items json, p_seguimiento date, p_clienta bigint default null) returns json
language plpgsql security definer set search_path = '' as $$
declare it json; t luna_dental.tarifario; n int := 0; sub numeric := 0; pid bigint; tot numeric; cl bigint;
begin
  if not luna_dental.es_presupuestos() then raise exception 'No autorizado'; end if;
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
  if p_clienta is not null and not exists (select 1 from luna_dental.clientas where id = p_clienta) then raise exception 'Paciente no encontrado.'; end if;
  insert into luna_dental.presupuestos (paciente, doctor_id, descuento_pct, total, seguimiento, staff_id, clienta_id)
  values (trim(left(p_paciente, 80)), p_doctor, p_descuento, tot, p_seguimiento, auth.uid(), p_clienta) returning id into pid;
  for it in select * from json_array_elements(p_items) loop
    select * into t from luna_dental.tarifario where id = (it ->> 'tarifario_id')::bigint;
    insert into luna_dental.presupuesto_items (presupuesto_id, tarifario_id, descripcion, cant, precio) values (pid, t.id, t.nombre, (it ->> 'cant')::int, t.precio);
  end loop;
  return json_build_object('id', pid, 'total', tot);
end $$;

create or replace function luna_dental.presupuesto_estado(p_id bigint, p_estado text) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_presupuestos() then raise exception 'No autorizado'; end if;
  if p_estado not in ('aceptado', 'rechazado') then raise exception 'Estado no válido.'; end if;
  update luna_dental.presupuestos set estado = p_estado, decidido_en = now() where id = p_id and estado = 'enviado';
  if not found then raise exception 'Presupuesto no encontrado o ya decidido.'; end if;
end $$;
