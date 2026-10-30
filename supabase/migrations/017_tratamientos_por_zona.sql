-- 017 · Tratamientos de toda la boca o de una arcada (profilaxis, fluorización, blanqueamiento…) en la sesión de la visita.
-- Un renglón del plan ya no tiene que ser de un diente: puede ser de «toda la boca», «arcada superior» o «arcada inferior» (columna `zona`). Es uno u otro:
-- o hay diente o hay zona. El precio sigue saliendo del tarifario, una sola vez por renglón. En la proforma la línea dice, por ejemplo, «Profilaxis (toda la boca)».
-- Reemplazos numerados: plan_agregar (nueva firma con p_zona), plan_lista y sesiones_lista (devuelven la zona), plan_a_presupuesto y sesion_a_presupuesto (describen piezas y/o zonas).
-- Las dos de proforma siguen con la regla de la 015: basta ser parte del personal (es_clinico()).
-- Orden de instalación: después de 016. Todo calificado con el schema del cliente.

alter table luna_dental.odontograma_plan alter column diente drop not null;
alter table luna_dental.odontograma_plan add column zona text check (zona in ('boca', 'superior', 'inferior'));
alter table luna_dental.odontograma_plan add constraint odontograma_plan_diente_o_zona check ((diente is not null and zona is null) or (diente is null and zona is not null));

drop function luna_dental.plan_agregar(bigint, int, bigint);
create function luna_dental.plan_agregar(p_id bigint, p_diente int, p_tarifario bigint, p_zona text default null) returns bigint language plpgsql security definer set search_path = '' as $$
declare t luna_dental.tarifario; i bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if p_diente is null and p_zona is null then raise exception 'Elige un diente o una zona (toda la boca, arcada superior o inferior).'; end if;
  if p_diente is not null and p_zona is not null then raise exception 'Elige un diente o una zona, no los dos.'; end if;
  if p_zona is not null and p_zona not in ('boca', 'superior', 'inferior') then raise exception 'Zona no válida.'; end if;
  select * into t from luna_dental.tarifario where id = p_tarifario and activo;
  if not found then raise exception 'Tratamiento no válido.'; end if;
  if (select count(*) from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null) >= 20 then
    raise exception 'El plan ya tiene 20 tratamientos: guarda la sesión antes de agregar más.'; end if;
  insert into luna_dental.odontograma_plan (clienta_id, diente, zona, tarifario_id, descripcion, precio, staff_id) values (p_id, p_diente, p_zona, t.id, t.nombre, t.precio, auth.uid()) returning id into i;
  perform luna_dental._audit('plan_agregar', p_id, coalesce(p_diente::text, p_zona) || ' ' || t.nombre);
  return i;
exception when check_violation then raise exception 'Diente no válido.';
end $$;
revoke all on function luna_dental.plan_agregar(bigint, int, bigint, text) from public, anon, authenticated;
grant execute on function luna_dental.plan_agregar(bigint, int, bigint, text) to authenticated;

create or replace function luna_dental.plan_lista(p_id bigint) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  return json_build_object(
    'items', (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'zona', o.zona, 'tarifario_id', o.tarifario_id, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente nulls first, o.id), '[]'::json)
              from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null),
    'total', (select coalesce(sum(o.precio), 0) from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null),
    'marcas_nuevas', (select count(*) from luna_dental.odontograma_mov m where m.clienta_id = p_id
                       and m.id > coalesce((select max(s.mov_hasta) from luna_dental.odontograma_sesion s where s.clienta_id = p_id), 0)),
    'marcas', (select coalesce(json_agg(json_build_object('diente', m.diente, 'superficie', m.superficie, 'capa', m.capa, 'estado', m.estado, 'nota', m.nota) order by m.id), '[]'::json)
                from luna_dental.odontograma_mov m where m.clienta_id = p_id
                 and m.id > coalesce((select max(s.mov_hasta) from luna_dental.odontograma_sesion s where s.clienta_id = p_id), 0)));
end $$;

create or replace function luna_dental.sesiones_lista(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('ver_sesiones', p_id, null);
  return (select coalesce(json_agg(x order by x.id desc), '[]'::json) from (
    select s.id, to_char(s.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI') as dia, s.total, s.nota, s.cita_id, s.doctor_id, dc.nombre as doctor, st.nombre as autor,
      (select coalesce(json_agg(json_build_object('diente', o.diente, 'zona', o.zona, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente nulls first, o.id), '[]'::json)
         from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null) as items,
      (select coalesce(json_agg(json_build_object('diente', m.diente, 'superficie', m.superficie, 'capa', m.capa, 'estado', m.estado, 'nota', m.nota) order by m.id), '[]'::json)
         from luna_dental.odontograma_mov m where m.clienta_id = s.clienta_id and m.id <= s.mov_hasta
          and m.id > coalesce((select max(p.mov_hasta) from luna_dental.odontograma_sesion p where p.clienta_id = s.clienta_id and p.id < s.id), 0)) as marcas,
      exists (select 1 from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null and o.presupuesto_id is not null) as presupuestada,
      exists (select 1 from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null and o.presupuesto_id is null) as pendiente_proforma
    from luna_dental.odontograma_sesion s left join luna_dental.doctores dc on dc.id = s.doctor_id left join luna_dental.staff st on st.user_id = s.staff_id
    where s.clienta_id = p_id order by s.id desc limit 100) x);
end $$;

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
    select pid, o.tarifario_id, left(o.descripcion || ' (' || concat_ws('; ', case when count(o.diente) > 0 then 'piezas ' || string_agg(o.diente::text, ', ' order by o.diente) end, case when count(o.zona) > 0 then string_agg(case o.zona when 'boca' then 'toda la boca' when 'superior' then 'arcada superior' else 'arcada inferior' end, ', ' order by o.zona) end) || ')', 200), count(*)::int, o.precio
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
    select pid, o.tarifario_id, left(o.descripcion || ' (' || concat_ws('; ', case when count(o.diente) > 0 then 'piezas ' || string_agg(o.diente::text, ', ' order by o.diente) end, case when count(o.zona) > 0 then string_agg(case o.zona when 'boca' then 'toda la boca' when 'superior' then 'arcada superior' else 'arcada inferior' end, ', ' order by o.zona) end) || ')', 200), count(*)::int, o.precio
    from luna_dental.odontograma_plan o where o.sesion_id = p_sesion and o.quitado_en is null and o.presupuesto_id is null
    group by o.tarifario_id, o.descripcion, o.precio;
  update luna_dental.odontograma_plan set presupuesto_id = pid where sesion_id = p_sesion and quitado_en is null and presupuesto_id is null;
  perform luna_dental._audit('sesion_a_presupuesto', s.clienta_id, 'sesion ' || p_sesion::text || ' presupuesto ' || pid::text);
  return json_build_object('id', pid, 'total', tot);
end $$;
