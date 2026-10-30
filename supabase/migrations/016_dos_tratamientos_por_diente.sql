-- 016 · Dos tratamientos en un mismo diente (endodoncia + corona, etc.) y la lista de marcas guardadas en la visita.
-- Hasta ahora un diente completo tenía un solo estado: marcar «corona» reemplazaba a «endodoncia» en el dibujo. Ahora una marca de diente completo puede ser la
-- 1.ª (capa 1, la de siempre: reemplaza todo lo anterior del diente) o la 2.ª (capa 2: se suma a la primera sin reemplazarla). El historial sigue siendo de solo agregar.
-- La capa 2 solo existe para el diente completo; una marca de capa 1 posterior (por ejemplo «ausente») vuelve a empezar el diente y retira la 2.ª.
-- Reemplazos numerados: odontograma_marcar (nueva firma con p_capa), odontograma_lista, odontograma_en, sesiones_lista (devuelven la capa) y plan_lista (suma la
-- lista de marcas guardadas desde la última sesión, para que la doctora vea qué se guardó en esta visita).
-- Orden de instalación: después de 015. Todo calificado con el schema del cliente.

alter table luna_dental.odontograma_mov add column capa smallint not null default 1 check (capa in (1, 2));
alter table luna_dental.odontograma_mov add constraint odontograma_capa_diente_completo check (capa = 1 or superficie is null);

drop function luna_dental.odontograma_marcar(bigint, int, text, text, bigint, text);
create function luna_dental.odontograma_marcar(p_id bigint, p_diente int, p_estado text, p_nota text, p_doctor bigint, p_superficie text default null, p_capa int default 1) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  if p_superficie is not null and p_superficie not in ('O', 'V', 'L', 'M', 'D') then raise exception 'Superficie no válida.'; end if;
  if p_capa is null or p_capa not in (1, 2) then raise exception 'Capa no válida.'; end if;
  if p_capa = 2 and p_superficie is not null then raise exception 'El segundo tratamiento es del diente completo, no de una superficie.'; end if;
  insert into luna_dental.odontograma_mov (clienta_id, diente, superficie, capa, estado, nota, doctor_id, staff_id)
    values (p_id, p_diente, p_superficie, p_capa, p_estado, nullif(trim(left(p_nota, 200)), ''), p_doctor, auth.uid());
  perform luna_dental._audit('odontograma', p_id, p_diente::text || coalesce('/' || p_superficie, '') || case when p_capa = 2 then ' (2.º) ' else ' ' end || p_estado);
exception when check_violation then raise exception 'Diente o estado no válido.';
end $$;
revoke all on function luna_dental.odontograma_marcar(bigint, int, text, text, bigint, text, int) from public, anon, authenticated;
grant execute on function luna_dental.odontograma_marcar(bigint, int, text, text, bigint, text, int) to authenticated;

create or replace function luna_dental.odontograma_lista(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('ver_odontograma', p_id, null);
  return (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'superficie', o.superficie, 'capa', o.capa, 'estado', o.estado, 'nota', o.nota,
      'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD')) order by o.id), '[]'::json)
    from (select distinct on (diente, coalesce(superficie, '*'), capa) id, diente, superficie, capa, estado, nota, creado
          from luna_dental.odontograma_mov where clienta_id = p_id order by diente, coalesce(superficie, '*'), capa, id desc) o);
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
          from luna_dental.odontograma_mov where clienta_id = s.clienta_id and id <= s.mov_hasta order by diente, coalesce(superficie, '*'), capa, id desc) o);
end $$;

create or replace function luna_dental.sesiones_lista(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('ver_sesiones', p_id, null);
  return (select coalesce(json_agg(x order by x.id desc), '[]'::json) from (
    select s.id, to_char(s.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI') as dia, s.total, s.nota, s.cita_id, s.doctor_id, dc.nombre as doctor, st.nombre as autor,
      (select coalesce(json_agg(json_build_object('diente', o.diente, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente, o.id), '[]'::json)
         from luna_dental.odontograma_plan o where o.sesion_id = s.id and o.quitado_en is null) as items,
      (select coalesce(json_agg(json_build_object('diente', m.diente, 'superficie', m.superficie, 'capa', m.capa, 'estado', m.estado, 'nota', m.nota) order by m.id), '[]'::json)
         from luna_dental.odontograma_mov m where m.clienta_id = s.clienta_id and m.id <= s.mov_hasta
          and m.id > coalesce((select max(p.mov_hasta) from luna_dental.odontograma_sesion p where p.clienta_id = s.clienta_id and p.id < s.id), 0)) as marcas,
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
    'items', (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'tarifario_id', o.tarifario_id, 'descripcion', o.descripcion, 'precio', o.precio) order by o.diente, o.id), '[]'::json)
              from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null),
    'total', (select coalesce(sum(o.precio), 0) from luna_dental.odontograma_plan o where o.clienta_id = p_id and o.quitado_en is null and o.presupuesto_id is null and o.sesion_id is null),
    'marcas_nuevas', (select count(*) from luna_dental.odontograma_mov m where m.clienta_id = p_id
                       and m.id > coalesce((select max(s.mov_hasta) from luna_dental.odontograma_sesion s where s.clienta_id = p_id), 0)),
    'marcas', (select coalesce(json_agg(json_build_object('diente', m.diente, 'superficie', m.superficie, 'capa', m.capa, 'estado', m.estado, 'nota', m.nota) order by m.id), '[]'::json)
                from luna_dental.odontograma_mov m where m.clienta_id = p_id
                 and m.id > coalesce((select max(s.mov_hasta) from luna_dental.odontograma_sesion s where s.clienta_id = p_id), 0)));
end $$;
