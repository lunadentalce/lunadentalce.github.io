-- 013 · Plan de tratamiento por diente (el «carrito» del odontograma).
-- Cada tratamiento que se agrega a un diente suma su precio al plan del paciente; el precio sale SIEMPRE del tarifario, calculado aquí (§4.5), y queda
-- congelado en el renglón. Del plan se pasa a un presupuesto (solo administración y doctor, igual que 012). El plan no es contabilidad: un renglón
-- se puede quitar mientras esté pendiente; al pasar a presupuesto queda ligado a él y ya no se toca.
-- Solo agrega: no cambia nada anterior. Orden de instalación: después de 012. Todo calificado con el schema del cliente.

create table luna_dental.odontograma_plan (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  diente int not null check (diente = any (array[11,12,13,14,15,16,17,18,21,22,23,24,25,26,27,28,31,32,33,34,35,36,37,38,41,42,43,44,45,46,47,48,
                                                 51,52,53,54,55,61,62,63,64,65,71,72,73,74,75,81,82,83,84,85])),
  tarifario_id bigint not null references luna_dental.tarifario (id),
  descripcion text not null,
  precio numeric(10, 2) not null check (precio >= 0),
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now(),
  quitado_en timestamptz,
  presupuesto_id bigint references luna_dental.presupuestos (id)
);
create index odontograma_plan_idx on luna_dental.odontograma_plan (clienta_id, id);
create index odontograma_plan_tar_idx on luna_dental.odontograma_plan (tarifario_id);
create index odontograma_plan_pres_idx on luna_dental.odontograma_plan (presupuesto_id);
alter table luna_dental.odontograma_plan enable row level security;   -- sin políticas: el navegador solo entra por las funciones

-- Plan pendiente del paciente (lo que aún no pasó a presupuesto ni se quitó) y su total.
create function luna_dental.plan_lista(p_id bigint) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  return json_build_object(
    'items', (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'tarifario_id', o.tarifario_id, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente, o.id), '[]'::json)
              from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null),
    'total', (select coalesce(sum(o.precio), 0) from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null));
end $$;

-- Agrega un tratamiento a un diente. Pide el consentimiento de tratamiento, igual que marcar el odontograma. Tope: 20 renglones pendientes.
create function luna_dental.plan_agregar(p_id bigint, p_diente int, p_tarifario bigint) returns bigint language plpgsql security definer set search_path = '' as $$
declare t luna_dental.tarifario; i bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  select * into t from luna_dental.tarifario where id = p_tarifario and activo;
  if not found then raise exception 'Tratamiento no válido.'; end if;
  if (select count(*) from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null) >= 20 then
    raise exception 'El plan ya tiene 20 tratamientos: pásalo a presupuesto antes de agregar más.'; end if;
  insert into luna_dental.odontograma_plan (clienta_id, diente, tarifario_id, descripcion, precio, staff_id) values (p_id, p_diente, t.id, t.nombre, t.precio, auth.uid()) returning id into i;
  perform luna_dental._audit('plan_agregar', p_id, p_diente::text || ' ' || t.nombre);
  return i;
exception when check_violation then raise exception 'Diente no válido.';
end $$;

-- Quita un renglón que aún está pendiente (no se borra: queda con la fecha en que se quitó).
create function luna_dental.plan_quitar(p_item bigint) returns void language plpgsql security definer set search_path = '' as $$
declare c bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  update luna_dental.odontograma_plan set quitado_en = now() where id = p_item and quitado_en is null and presupuesto_id is null returning clienta_id into c;
  if not found then raise exception 'Ese tratamiento ya no está pendiente.'; end if;
  perform luna_dental._audit('plan_quitar', c, p_item::text);
end $$;

-- Convierte el plan pendiente en un presupuesto del paciente (un renglón por tratamiento, con las piezas en la descripción). Solo administración y doctor.
create function luna_dental.plan_a_presupuesto(p_id bigint, p_doctor bigint, p_descuento int, p_seguimiento date) returns json language plpgsql security definer set search_path = '' as $$
declare c luna_dental.clientas; sub numeric; tot numeric; pid bigint;
begin
  if not luna_dental.es_presupuestos() then raise exception 'No autorizado'; end if;
  select * into c from luna_dental.clientas where id = p_id;
  if not found then raise exception 'Paciente no encontrado.'; end if;
  if p_descuento is null or p_descuento < 0 or p_descuento > 50 then raise exception 'El descuento va de 0 a 50 %%.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor and activo) then raise exception 'Doctor no válido.'; end if;
  select coalesce(sum(precio), 0) into sub from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null;
  if not exists (select 1 from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null) then raise exception 'El plan está vacío.'; end if;
  tot := round(sub * (100 - p_descuento) / 100.0, 2);
  insert into luna_dental.presupuestos (paciente, doctor_id, descuento_pct, total, seguimiento, staff_id, clienta_id)
    values (c.nombre, p_doctor, p_descuento, tot, p_seguimiento, auth.uid(), p_id) returning id into pid;
  insert into luna_dental.presupuesto_items (presupuesto_id, tarifario_id, descripcion, cant, precio)
    select pid, o.tarifario_id, left(o.descripcion || ' (piezas ' || string_agg(o.diente::text, ', ' order by o.diente) || ')', 200), count(*)::int, o.precio
    from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null
    group by o.tarifario_id, o.descripcion, o.precio;
  update luna_dental.odontograma_plan set presupuesto_id = pid where clienta_id = p_id and quitado_en is null and presupuesto_id is null;
  perform luna_dental._audit('plan_a_presupuesto', p_id, 'presupuesto ' || pid::text);
  return json_build_object('id', pid, 'total', tot);
end $$;

revoke all on function luna_dental.plan_lista(bigint), luna_dental.plan_agregar(bigint, int, bigint), luna_dental.plan_quitar(bigint), luna_dental.plan_a_presupuesto(bigint, bigint, int, date) from public, anon, authenticated;
grant execute on function luna_dental.plan_lista(bigint), luna_dental.plan_agregar(bigint, int, bigint), luna_dental.plan_quitar(bigint), luna_dental.plan_a_presupuesto(bigint, bigint, int, date) to authenticated;
