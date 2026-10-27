-- 014 · Sesiones del odontograma: cada visita queda guardada como una sola sesión (no diente por diente).
-- Una sesión junta, en un solo registro que no se edita: la fecha, el doctor, la cita (opcional), una nota, los tratamientos realizados con su precio del tarifario
-- (el «carrito» de 013), el total y el punto del historial de marcas del odontograma hasta ese momento. Con eso se puede ver después qué se hizo en cada visita
-- y cómo estaba el odontograma ese día. De una sesión se genera la proforma (presupuesto) con un botón, solo administración y doctor (012).
-- Reemplazos numerados (misma firma): plan_lista, plan_agregar, plan_quitar y plan_a_presupuesto de 013 ahora trabajan solo con lo que NO está en una sesión guardada.
-- Orden de instalación: después de 013. Todo calificado con el schema del cliente.

create table luna_dental.odontograma_sesion (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  cita_id bigint references luna_dental.citas (id),
  doctor_id bigint references luna_dental.doctores (id),
  nota text check (length(nota) <= 300),
  mov_hasta bigint not null default 0,          -- último id de odontograma_mov del paciente al guardar: sirve para reconstruir el odontograma de ese día
  total numeric(10, 2) not null check (total >= 0),
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now()
);
create index odontograma_sesion_idx on luna_dental.odontograma_sesion (clienta_id, id);
create index odontograma_sesion_cita_idx on luna_dental.odontograma_sesion (cita_id);
create index odontograma_sesion_doc_idx on luna_dental.odontograma_sesion (doctor_id);
create trigger odontograma_sesion_inmutable before update or delete on luna_dental.odontograma_sesion for each row execute function luna_dental._solo_agregar();
alter table luna_dental.odontograma_sesion enable row level security;   -- sin políticas: solo entra por funciones

alter table luna_dental.odontograma_plan add column sesion_id bigint references luna_dental.odontograma_sesion (id);
create index odontograma_plan_ses_idx on luna_dental.odontograma_plan (sesion_id);

-- ---------- el carrito (013) pasa a ser solo lo pendiente de la sesión en curso ----------
create or replace function luna_dental.plan_lista(p_id bigint) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  return json_build_object(
    'items', (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'tarifario_id', o.tarifario_id, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente, o.id), '[]'::json)
              from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null),
    'total', (select coalesce(sum(o.precio), 0) from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null),
    'marcas_nuevas', (select count(*) from luna_dental.odontograma_mov m where m.clienta_id = p_id
                       and m.id > coalesce((select max(s.mov_hasta) from luna_dental.odontograma_sesion s where s.clienta_id = p_id), 0)));
end $$;

create or replace function luna_dental.plan_agregar(p_id bigint, p_diente int, p_tarifario bigint) returns bigint language plpgsql security definer set search_path = '' as $$
declare t luna_dental.tarifario; i bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  select * into t from luna_dental.tarifario where id = p_tarifario and activo;
  if not found then raise exception 'Tratamiento no válido.'; end if;
  if (select count(*) from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null) >= 20 then
    raise exception 'El plan ya tiene 20 tratamientos: guarda la sesión antes de agregar más.'; end if;
  insert into luna_dental.odontograma_plan (clienta_id, diente, tarifario_id, descripcion, precio, staff_id) values (p_id, p_diente, t.id, t.nombre, t.precio, auth.uid()) returning id into i;
  perform luna_dental._audit('plan_agregar', p_id, p_diente::text || ' ' || t.nombre);
  return i;
exception when check_violation then raise exception 'Diente no válido.';
end $$;

create or replace function luna_dental.plan_quitar(p_item bigint) returns void language plpgsql security definer set search_path = '' as $$
declare c bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  update luna_dental.odontograma_plan set quitado_en = now() where id = p_item and quitado_en is null and presupuesto_id is null and sesion_id is null returning clienta_id into c;
  if not found then raise exception 'Ese tratamiento ya no está pendiente.'; end if;
  perform luna_dental._audit('plan_quitar', c, p_item::text);
end $$;

create or replace function luna_dental.plan_a_presupuesto(p_id bigint, p_doctor bigint, p_descuento int, p_seguimiento date) returns json language plpgsql security definer set search_path = '' as $$
declare c luna_dental.clientas; sub numeric; tot numeric; pid bigint;
begin
  if not luna_dental.es_presupuestos() then raise exception 'No autorizado'; end if;
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

-- ---------- sesiones ----------
-- Guarda la sesión: junta el carrito pendiente y las marcas nuevas del odontograma. Pide el consentimiento de tratamiento. Necesita algo que guardar.
create function luna_dental.sesion_guardar(p_id bigint, p_cita bigint, p_doctor bigint, p_nota text) returns json language plpgsql security definer set search_path = '' as $$
declare sid bigint; tot numeric; n int; hasta bigint; previo bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  if p_cita is not null and not exists (select 1 from luna_dental.citas where id = p_cita and clienta_id = p_id) then raise exception 'Esa cita no es de este paciente.'; end if;
  select count(*), coalesce(sum(precio), 0) into n, tot from luna_dental.odontograma_plan where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null;
  select coalesce(max(id), 0) into hasta from luna_dental.odontograma_mov where clienta_id = p_id;
  select coalesce(max(mov_hasta), 0) into previo from luna_dental.odontograma_sesion where clienta_id = p_id;
  if n = 0 and hasta <= previo then raise exception 'No hay nada que guardar: marca el odontograma o agrega tratamientos.'; end if;
  insert into luna_dental.odontograma_sesion (clienta_id, cita_id, doctor_id, nota, mov_hasta, total, staff_id)
    values (p_id, p_cita, p_doctor, nullif(trim(left(p_nota, 300)), ''), hasta, tot, auth.uid()) returning id into sid;
  update luna_dental.odontograma_plan set sesion_id = sid where clienta_id = p_id and quitado_en is null and presupuesto_id is null and sesion_id is null;
  perform luna_dental._audit('sesion_guardar', p_id, 'sesion ' || sid::text);
  return json_build_object('id', sid, 'total', tot);
end $$;

-- Historial de sesiones del paciente (la más reciente primero): lo hecho, las marcas de esa visita y si ya tiene proforma.
create function luna_dental.sesiones_lista(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('ver_sesiones', p_id, null);
  return (select coalesce(json_agg(x order by x.id desc), '[]'::json) from (
    select s.id, to_char(s.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI') as dia, s.total, s.nota, s.cita_id, s.doctor_id, dc.nombre as doctor, st.nombre as autor,
      (select coalesce(json_agg(json_build_object('diente', o.diente, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente, o.id), '[]'::json)
         from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null) as items,
      (select coalesce(json_agg(json_build_object('diente', m.diente, 'superficie', m.superficie, 'estado', m.estado, 'nota', m.nota) order by m.id), '[]'::json)
         from luna_dental.odontograma_mov m where m.clienta_id = s.clienta_id and m.id <= s.mov_hasta
          and m.id > coalesce((select max(p.mov_hasta) from luna_dental.odontograma_sesion p where p.clienta_id = s.clienta_id and p.id < s.id), 0)) as marcas,
      exists (select 1 from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null and o.presupuesto_id is not null) as presupuestada,
      exists (select 1 from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null and o.presupuesto_id is null) as pendiente_proforma
    from luna_dental.odontograma_sesion s left join luna_dental.doctores dc on dc.id = s.doctor_id left join luna_dental.staff st on st.user_id = s.staff_id
    where s.clienta_id = p_id order by s.id desc limit 100) x);
end $$;

-- El odontograma tal como estaba al cerrar una sesión (mismo formato que odontograma_lista).
create function luna_dental.odontograma_en(p_sesion bigint) returns json language plpgsql security definer set search_path = '' as $$
declare s luna_dental.odontograma_sesion;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  select * into s from luna_dental.odontograma_sesion where id = p_sesion;
  if not found then raise exception 'Sesión no encontrada.'; end if;
  perform luna_dental._audit('ver_odontograma', s.clienta_id, 'sesion ' || p_sesion::text);
  return (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'superficie', o.superficie, 'estado', o.estado, 'nota', o.nota,
      'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD')) order by o.id), '[]'::json)
    from (select distinct on (diente, coalesce(superficie, '*')) id, diente, superficie, estado, nota, creado
          from luna_dental.odontograma_mov where clienta_id = s.clienta_id and id <= s.mov_hasta order by diente, coalesce(superficie, '*'), id desc) o);
end $$;

-- Proforma de una sesión: un renglón por tratamiento, con las piezas en la descripción. Solo administración y doctor; una sesión se convierte una sola vez.
create function luna_dental.sesion_a_presupuesto(p_sesion bigint, p_doctor bigint, p_descuento int, p_seguimiento date) returns json language plpgsql security definer set search_path = '' as $$
declare s luna_dental.odontograma_sesion; c luna_dental.clientas; sub numeric; tot numeric; pid bigint;
begin
  if not luna_dental.es_presupuestos() then raise exception 'No autorizado'; end if;
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

revoke all on function luna_dental.sesion_guardar(bigint, bigint, bigint, text), luna_dental.sesiones_lista(bigint), luna_dental.odontograma_en(bigint),
  luna_dental.sesion_a_presupuesto(bigint, bigint, int, date) from public, anon, authenticated;
grant execute on function luna_dental.sesion_guardar(bigint, bigint, bigint, text), luna_dental.sesiones_lista(bigint), luna_dental.odontograma_en(bigint),
  luna_dental.sesion_a_presupuesto(bigint, bigint, int, date) to authenticated;
