-- 015 · Proforma desde la sesión: también el equipo (recepción).
-- En la clínica se trabaja con dos tablets (la de la doctora y la del equipo para todos), así que recepción también pasa una sesión (o el carrito pendiente) a proforma.
-- Reemplazos numerados de sesion_a_presupuesto y plan_a_presupuesto (misma firma, conservan sus permisos): ahora basta ser parte del personal (es_clinico()).
-- NO cambia: crear un presupuesto suelto (presupuesto_guardar) y marcar «aceptó / rechazó» (presupuesto_estado) siguen siendo de administración y doctor (012).
-- Orden de instalación: después de 014. Todo calificado con el schema del cliente.

create or replace function luna_dental.plan_a_presupuesto(p_id bigint, p_doctor bigint, p_descuento int, p_seguimiento date) returns json language plpgsql security definer set search_path = '' as $$
declare c luna_dental.clientas; sub numeric; tot numeric; pid bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  select * into c from luna_dental.clientas where id = p_id;
  if not found then raise exception 'Paciente no encontrado.'; end if;
  if p_descuento is null or p_descuento < 0 or p_descuento > 50 then raise exception 'El descuento va de 0 a 50 %%.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  select coalesce(sum(precio), 0) into sub from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null;
  if not exists (select 1 from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null) then raise exception 'El plan está vacío.'; end if;
  tot := round(sub * (100 - p_descuento) / 100.0, 2);
  insert into luna_dental.presupuestos (paciente, doctor_id, descuento_pct, total, seguimiento, staff_id, clienta_id)
    values (c.nombre, p_doctor, p_descuento, tot, p_seguimiento, auth.uid(), p_id) returning id into pid;
  insert into luna_dental.presupuesto_items (presupuesto_id, tarifario_id, descripcion, cant, precio)
    select pid, o.tarifario_id, left(o.descripcion || ' (piezas ' || string_agg(o.diente::text, ', ' order by o.diente) || ')', 200), count(*)::int, o.precio
    from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null
    group by o.tarifario_id, o.descripcion, o.precio;
  update luna_dental.odontograma_plan set presupuesto_id = pid where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null;
  perform luna_dental._audit('plan_a_presupuesto', p_id, 'presupuesto ' || pid::text);
  return json_build_object('id', pid, 'total', tot);
end $$;

create or replace function luna_dental.sesion_a_presupuesto(p_sesion bigint, p_doctor bigint, p_descuento int, p_seguimiento date) returns json language plpgsql security definer set search_path = '' as $$
declare s luna_dental.odontograma_sesion; c luna_dental.clientas; sub numeric; tot numeric; pid bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  select * into s from luna_dental.odontograma_sesion where id = p_sesion;
  if not found then raise exception 'Sesión no encontrada.'; end if;
  select * into c from luna_dental.clientas where id = s.clienta_id;
  if p_descuento is null or p_descuento < 0 or p_descuento > 50 then raise exception 'El descuento va de 0 a 50 %%.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  if not exists (select 1 from luna_dental.odontograma_plan where sesion_id = p_sesion and quitado_en is null and presupuesto_id is null) then raise exception 'Esta sesión no tiene tratamientos por presupuestar.'; end if;
  select sum(precio) into sub from luna_dental.odontograma_plan where sesion_id = p_sesion and quitado_en is null and presupuesto_id is null;
  tot := round(sub * (100 - p_descuento) / 100.0, 2);
  insert into luna_dental.presupuestos (paciente, doctor_id, descuento_pct, total, seguimiento, staff_id, clienta_id)
    values (c.nombre, coalesce(p_doctor, s.doctor_id), p_descuento, tot, p_seguimiento, auth.uid(), s.clienta_id) returning id into pid;
  insert into luna_dental.presupuesto_items (presupuesto_id, tarifario_id, descripcion, cant, precio)
    select pid, o.tarifario_id, left(o.descripcion || ' (piezas ' || string_agg(o.diente::text, ', ' order by o.diente) || ')', 200), count(*)::int, o.precio
    from luna_dental.odontograma_plan o where o.sesion_id = p_sesion and o.quitado_en is null and o.presupuesto_id is null
    group by o.tarifario_id, o.descripcion, o.precio;
  update luna_dental.odontograma_plan set presupuesto_id = pid where sesion_id = p_sesion and quitado_en is null and presupuesto_id is null;
  perform luna_dental._audit('sesion_a_presupuesto', s.clienta_id, 'sesion ' || p_sesion::text || ' presupuesto ' || pid::text);
  return json_build_object('id', pid, 'total', tot);
end $$;

-- Permisos (los mismos de antes, repetidos para que el archivo se pueda revisar solo): solo usuarios con sesión; la función misma exige es_clinico().
revoke all on function luna_dental.plan_a_presupuesto(bigint, bigint, int, date), luna_dental.sesion_a_presupuesto(bigint, bigint, int, date) from public, anon, authenticated;
grant execute on function luna_dental.plan_a_presupuesto(bigint, bigint, int, date), luna_dental.sesion_a_presupuesto(bigint, bigint, int, date) to authenticated;
