-- 011 · Odontograma por superficies (reemplazo numerado de odontograma_marcar de 010 + lectura nueva).
-- Cada diente se dibuja como un cuadrado con 5 superficies: O oclusal/incisal (centro), V vestibular, L lingual/palatina, M mesial, D distal.
-- Un movimiento sin superficie (null) marca el DIENTE COMPLETO (ausente, implante, corona, brackets…); con superficie marca solo esa cara (caries, resina…).
-- Solo agrega: los movimientos anteriores quedan con superficie null (diente completo) y siguen siendo válidos. El historial sigue siendo inmutable (trigger de 010).
-- Orden de instalación: después de 010. Todo calificado con el schema del cliente; nada fuera de él.

alter table luna_dental.odontograma_mov add column superficie text check (superficie in ('O', 'V', 'L', 'M', 'D'));
create index odontograma_sup_idx on luna_dental.odontograma_mov (clienta_id, diente, superficie, id);

-- Reemplazo explícito: se retira la firma de 5 parámetros y la nueva suma p_superficie (opcional, null = diente completo).
drop function luna_dental.odontograma_marcar(bigint, int, text, text, bigint);
create function luna_dental.odontograma_marcar(p_id bigint, p_diente int, p_estado text, p_nota text, p_doctor bigint, p_superficie text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  if p_superficie is not null and p_superficie not in ('O', 'V', 'L', 'M', 'D') then raise exception 'Superficie no válida.'; end if;
  insert into luna_dental.odontograma_mov (clienta_id, diente, superficie, estado, nota, doctor_id, staff_id)
    values (p_id, p_diente, p_superficie, p_estado, nullif(trim(left(p_nota, 200)), ''), p_doctor, auth.uid());
  perform luna_dental._audit('odontograma', p_id, p_diente::text || coalesce('/' || p_superficie, '') || ' ' || p_estado);
exception when check_violation then raise exception 'Diente o estado no válido.';
end $$;

-- Estado vigente: el último movimiento de cada diente completo y de cada superficie. `id` permite al panel resolver el orden
-- (una marca de diente completo posterior reemplaza las marcas de superficie anteriores). Solo admin y doctor; la lectura queda en la auditoría.
create function luna_dental.odontograma_lista(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  perform luna_dental._audit('ver_odontograma', p_id, null);
  return (select coalesce(json_agg(json_build_object('id', o.id, 'diente', o.diente, 'superficie', o.superficie, 'estado', o.estado, 'nota', o.nota,
      'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD')) order by o.id), '[]'::json)
    from (select distinct on (diente, coalesce(superficie, '*')) id, diente, superficie, estado, nota, creado
          from luna_dental.odontograma_mov where clienta_id = p_id order by diente, coalesce(superficie, '*'), id desc) o);
end $$;

-- Permisos: igual que el resto de la ficha (solo usuarios con sesión; la función misma exige es_clinico()).
revoke all on function luna_dental.odontograma_marcar(bigint, int, text, text, bigint, text), luna_dental.odontograma_lista(bigint) from public, anon, authenticated;
grant execute on function luna_dental.odontograma_marcar(bigint, int, text, text, bigint, text), luna_dental.odontograma_lista(bigint) to authenticated;
