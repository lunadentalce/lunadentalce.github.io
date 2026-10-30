-- 018 · Limpiar el odontograma del paciente sin perder el historial.
-- Deja el dibujo limpio (todos los dientes sanos) pero NO borra nada: las marcas, las sesiones, los tratamientos y las proformas siguen guardados. Se registra un
-- «reinicio» (quién, cuándo y por qué) que marca el punto desde el cual el dibujo vuelve a empezar. Solo administración y doctor, y con el consentimiento de tratamiento.
-- Cada sesión sigue mostrando el odontograma tal como estaba ese día («Ver el odontograma de ese día»); los dientes «trabajados» del dibujo actual cuentan desde el reinicio.
-- Reemplazos numerados: odontograma_lista, odontograma_en, sesiones_lista (marca las sesiones anteriores al reinicio) y plan_lista (odo_limpio y la lista de reinicios).
-- Orden de instalación: después de 017. Todo calificado con el schema del cliente.

create table luna_dental.odontograma_reinicio (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  corte bigint not null,                          -- último id de odontograma_mov del paciente al limpiar: lo anterior queda en el historial y ya no se dibuja
  motivo text not null check (length(trim(motivo)) >= 3 and length(motivo) <= 200),
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now()
);
create index odontograma_reinicio_idx on luna_dental.odontograma_reinicio (clienta_id, id);
create trigger odontograma_reinicio_inmutable before update or delete on luna_dental.odontograma_reinicio for each row execute function luna_dental._solo_agregar();
alter table luna_dental.odontograma_reinicio enable row level security;   -- sin políticas: solo entra por funciones

create function luna_dental.es_doctor_o_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from luna_dental.staff where user_id = auth.uid() and rol in ('admin', 'doctor')) $$;
revoke all on function luna_dental.es_doctor_o_admin() from public, anon, authenticated;

create function luna_dental.odontograma_reiniciar(p_id bigint, p_motivo text) returns void language plpgsql security definer set search_path = '' as $$
declare hasta bigint; previo bigint;
begin
  if not luna_dental.es_doctor_o_admin() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo (por ejemplo: nuevo ciclo de tratamiento).'; end if;
  select coalesce(max(id), 0) into hasta from luna_dental.odontograma_mov where clienta_id = p_id;
  select coalesce(max(corte), 0) into previo from luna_dental.odontograma_reinicio where clienta_id = p_id;
  if hasta <= previo then raise exception 'El odontograma ya está limpio.'; end if;
  insert into luna_dental.odontograma_reinicio (clienta_id, corte, motivo, staff_id) values (p_id, hasta, trim(left(p_motivo, 200)), auth.uid());
  perform luna_dental._audit('odontograma_reinicio', p_id, left(trim(p_motivo), 150));
end $$;
revoke all on function luna_dental.odontograma_reiniciar(bigint, text) from public, anon, authenticated;
grant execute on function luna_dental.odontograma_reiniciar(bigint, text) to authenticated;

create or replace function luna_dental.odontograma_lista(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('ver_odontograma', p_id, null);
  return (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'superficie', o.superficie, 'capa', o.capa, 'estado', o.estado, 'nota', o.nota,
      'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD')) order by o.id), '[]'::json)
    from (select distinct on (diente, coalesce(superficie, '*'), capa) id, diente, superficie, capa, estado, nota, creado
          from luna_dental.odontograma_mov where clienta_id = p_id
            and id > coalesce((select max(r.corte) from luna_dental.odontograma_reinicio r where r.clienta_id = p_id), 0)
          order by diente, coalesce(superficie, '*'), capa, id desc) o);
end $$;

create or replace function luna_dental.odontograma_en(p_sesion bigint) returns json language plpgsql security definer set search_path = '' as $$
declare s luna_dental.odontograma_sesion;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  select * into s from luna_dental.odontograma_sesion where id = p_sesion;
  if not found then raise exception 'Sesión no encontrada.'; end if;
  perform luna_dental._audit('ver_odontograma', s.clienta_id, 'sesion ' || p_sesion::text);
  return (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'superficie', o.superficie, 'capa', o.capa, 'estado', o.estado, 'nota', o.nota,
      'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD')) order by o.id), '[]'::json)
    from (select distinct on (diente, coalesce(superficie, '*'), capa) id, diente, superficie, capa, estado, nota, creado
          from luna_dental.odontograma_mov where clienta_id = s.clienta_id and id <= s.mov_hasta
            and id > coalesce((select max(r.corte) from luna_dental.odontograma_reinicio r where r.clienta_id = s.clienta_id and r.creado <= s.creado), 0)
          order by diente, coalesce(superficie, '*'), capa, id desc) o);
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
      exists (select 1 from luna_dental.odontograma_reinicio r where r.clienta_id = s.clienta_id and r.creado > s.creado) as previa_reinicio,
      exists (select 1 from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null and o.presupuesto_id is not null) as presupuestada,
      exists (select 1 from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null and o.presupuesto_id is null) as pendiente_proforma
    from luna_dental.odontograma_sesion s left join luna_dental.doctores dc on dc.id = s.doctor_id left join luna_dental.staff st on st.user_id = s.staff_id
    where s.clienta_id = p_id order by s.id desc limit 100) x);
end $$;

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
    'odo_limpio', not exists (select 1 from luna_dental.odontograma_mov m where m.clienta_id = p_id and m.id > coalesce((select max(r.corte) from luna_dental.odontograma_reinicio r where r.clienta_id = p_id), 0)),
    'reinicios', (select coalesce(json_agg(json_build_object('dia', to_char(r.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI'), 'motivo', r.motivo, 'quien', st.nombre) order by r.id desc), '[]'::json)
                  from luna_dental.odontograma_reinicio r left join luna_dental.staff st on st.user_id = r.staff_id where r.clienta_id = p_id),
    'marcas', (select coalesce(json_agg(json_build_object('diente', m.diente, 'superficie', m.superficie, 'capa', m.capa, 'estado', m.estado, 'nota', m.nota) order by m.id), '[]'::json)
                from luna_dental.odontograma_mov m where m.clienta_id = p_id
                 and m.id > coalesce((select max(s.mov_hasta) from luna_dental.odontograma_sesion s where s.clienta_id = p_id), 0)));
end $$;
