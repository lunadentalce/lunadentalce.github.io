-- Módulo de clínica dental · 010 ficha del paciente: datos, historial de citas, cobros y presupuestos por paciente, y la parte clínica.
-- DATOS DE SALUD = DATOS SENSIBLES (Ley Orgánica de Protección de Datos Personales). Protecciones de diseño:
--  · Lo clínico (antecedentes, odontograma, evolución) solo lo ven y escriben los roles admin y doctor. Recepción ve datos de contacto, citas, cobros y presupuestos.
--  · Todo lo clínico es de solo agregar: nada se edita ni se borra; se corrige con una nota nueva que apunta a la anterior (§4.9).
--  · No se escribe en lo clínico sin el consentimiento de tratamiento registrado (quién lo dio y cuándo).
--  · Cada vez que alguien con acceso clínico abre o cambia una ficha queda un registro en auditoria (quién, cuándo, qué).
--  · Los archivos (radiografías, fotos) NO están incluidos: requieren almacenamiento privado y se definen aparte.

-- ---------- rol doctor ----------
alter table luna_dental.staff drop constraint staff_rol_check;
alter table luna_dental.staff add constraint staff_rol_check check (rol in ('admin', 'doctor', 'recepcion'));

create or replace function luna_dental.equipo_guardar(p_email text, p_nombre text, p_rol text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  if p_rol not in ('admin', 'doctor', 'recepcion') then raise exception 'Rol no válido.'; end if;
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then raise exception 'Ese correo no tiene usuario. Créalo primero en Supabase › Authentication › Add user.'; end if;
  insert into luna_dental.staff (user_id, nombre, rol) values (u, coalesce(nullif(trim(p_nombre), ''), split_part(p_email, '@', 1)), p_rol)
    on conflict (user_id) do update set nombre = excluded.nombre, rol = excluded.rol;
end $$;

create function luna_dental.es_clinico() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from luna_dental.staff where user_id = auth.uid() and rol in ('admin', 'doctor')) $$;

-- ---------- tablas ----------
create table luna_dental.paciente_datos (
  clienta_id bigint primary key references luna_dental.clientas (id),
  cedula text check (cedula is null or cedula ~ '^[0-9A-Za-z-]{5,20}$'),
  nacimiento date check (nacimiento is null or nacimiento >= date '1900-01-01'),
  email text check (email is null or email ~ '^[^@[:space:]]+@[^@[:space:]]+$'),
  direccion text check (length(direccion) <= 200),
  contacto_nombre text check (length(contacto_nombre) <= 80),
  contacto_tel text check (length(contacto_tel) <= 20),
  representante text check (length(representante) <= 80),
  actualizado timestamptz not null default now()
);

create table luna_dental.consentimientos (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  tipo text not null check (tipo in ('datos', 'tratamiento', 'imagenes')),
  otorgado boolean not null,
  quien text not null check (length(trim(quien)) >= 2),          -- el paciente, o su representante si es menor
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now()
);
create index consentimientos_idx on luna_dental.consentimientos (clienta_id, tipo, id);

create table luna_dental.clinico_versiones (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  alergias text check (length(alergias) <= 1000), medicamentos text check (length(medicamentos) <= 1000),
  antecedentes_medicos text check (length(antecedentes_medicos) <= 2000), antecedentes_odonto text check (length(antecedentes_odonto) <= 2000),
  habitos text check (length(habitos) <= 1000), observaciones text check (length(observaciones) <= 2000),
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now()
);
create index clinico_versiones_idx on luna_dental.clinico_versiones (clienta_id, id);

create table luna_dental.odontograma_mov (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  diente int not null check (diente = any (array[11,12,13,14,15,16,17,18,21,22,23,24,25,26,27,28,31,32,33,34,35,36,37,38,41,42,43,44,45,46,47,48,
                                                 51,52,53,54,55,61,62,63,64,65,71,72,73,74,75,81,82,83,84,85])),    -- numeración FDI (permanentes y temporales)
  estado text not null check (estado in ('sano', 'caries', 'resina', 'endodoncia', 'corona', 'brackets', 'implante', 'protesis', 'ausente')),
  nota text check (length(nota) <= 200),
  doctor_id bigint references luna_dental.doctores (id),
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now()
);
create index odontograma_mov_idx on luna_dental.odontograma_mov (clienta_id, diente, id);

create table luna_dental.evoluciones (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  cita_id bigint references luna_dental.citas (id),
  doctor_id bigint references luna_dental.doctores (id),
  motivo text not null check (length(trim(motivo)) >= 3 and length(motivo) <= 300),
  diagnostico text check (length(diagnostico) <= 2000), procedimiento text check (length(procedimiento) <= 2000), indicaciones text check (length(indicaciones) <= 2000),
  corrige_id bigint references luna_dental.evoluciones (id),
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now()
);
create index evoluciones_idx on luna_dental.evoluciones (clienta_id, id);

create table luna_dental.auditoria (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  user_id uuid not null references auth.users (id),
  accion text not null,
  clienta_id bigint references luna_dental.clientas (id),
  detalle text
);
create index auditoria_idx on luna_dental.auditoria (clienta_id, id);

alter table luna_dental.caja add column clienta_id bigint references luna_dental.clientas (id);
create index caja_clienta_idx on luna_dental.caja (clienta_id) where clienta_id is not null;
create index presupuestos_clienta_idx on luna_dental.presupuestos (clienta_id) where clienta_id is not null;
create or replace function luna_dental._caja_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Los movimientos de caja no se borran: se anulan.'; end if;
  if old.anulado or new.anulado is not true
     or (old.creado, old.descripcion, old.importe, old.tipo, old.doctor_id, old.staff_id, old.clienta_id)
        is distinct from (new.creado, new.descripcion, new.importe, new.tipo, new.doctor_id, new.staff_id, new.clienta_id) then
    raise exception 'Un movimiento de caja solo se puede anular.';
  end if;
  return new;
end $$;

-- Lo clínico y la auditoría son de solo agregar
create function luna_dental._solo_agregar() returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'Este registro no se edita ni se borra: se agrega una corrección.'; end $$;
create trigger consentimientos_inmutable before update or delete on luna_dental.consentimientos for each row execute function luna_dental._solo_agregar();
create trigger clinico_inmutable before update or delete on luna_dental.clinico_versiones for each row execute function luna_dental._solo_agregar();
create trigger odontograma_inmutable before update or delete on luna_dental.odontograma_mov for each row execute function luna_dental._solo_agregar();
create trigger evoluciones_inmutable before update or delete on luna_dental.evoluciones for each row execute function luna_dental._solo_agregar();
create trigger auditoria_inmutable before update or delete on luna_dental.auditoria for each row execute function luna_dental._solo_agregar();

alter table luna_dental.paciente_datos enable row level security;
alter table luna_dental.consentimientos enable row level security;
alter table luna_dental.clinico_versiones enable row level security;
alter table luna_dental.odontograma_mov enable row level security;
alter table luna_dental.evoluciones enable row level security;
alter table luna_dental.auditoria enable row level security;
revoke all on all tables in schema luna_dental from public, anon, authenticated;

-- ---------- ayudas internas ----------
create function luna_dental._audit(p_accion text, p_clienta bigint, p_detalle text) returns void language sql set search_path = '' as $$
  insert into luna_dental.auditoria (user_id, accion, clienta_id, detalle) values (auth.uid(), p_accion, p_clienta, left(p_detalle, 200)) $$;

create function luna_dental._consiente(p_clienta bigint, p_tipo text) returns boolean language sql stable set search_path = '' as $$
  select coalesce((select otorgado from luna_dental.consentimientos where clienta_id = p_clienta and tipo = p_tipo order by id desc limit 1), false) $$;

-- ---------- pacientes: búsqueda, ficha y datos (todo el personal) ----------
create function luna_dental.pacientes_buscar(p_q text) returns json language plpgsql stable security definer set search_path = '' as $$
declare q text := replace(replace(replace(trim(coalesce(p_q, '')), '\', '\\'), '%', '\%'), '_', '\_');
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  return (select coalesce(json_agg(x order by x.ultima desc nulls last, x.nombre), '[]'::json) from (
    select c.id, c.nombre, c.telefono, d.cedula,
      (select count(*) from luna_dental.citas ci where ci.clienta_id = c.id and ci.estado <> 'cancelada') as citas,
      (select to_char(max(ci.inicio at time zone 'America/Guayaquil'), 'YYYY-MM-DD') from luna_dental.citas ci where ci.clienta_id = c.id and ci.inicio <= now()) as ultima,
      (select to_char(min(ci.inicio at time zone 'America/Guayaquil'), 'YYYY-MM-DD') from luna_dental.citas ci where ci.clienta_id = c.id and ci.inicio > now() and ci.estado in ('pendiente', 'confirmada')) as proxima
    from luna_dental.clientas c left join luna_dental.paciente_datos d on d.clienta_id = c.id
    where length(q) < 2 or c.nombre ilike '%' || q || '%' or c.telefono like '%' || q || '%' or d.cedula ilike '%' || q || '%'
    order by c.creado desc limit 40) x);
end $$;

create function luna_dental.paciente_ficha(p_id bigint) returns json language plpgsql security definer set search_path = '' as $$
declare c luna_dental.clientas; clin boolean := luna_dental.es_clinico(); r json;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  select * into c from luna_dental.clientas where id = p_id;
  if not found then raise exception 'Paciente no encontrado.'; end if;
  if clin then perform luna_dental._audit('ver_ficha', p_id, null); end if;
  select json_build_object(
    'id', c.id, 'nombre', c.nombre, 'telefono', c.telefono, 'creado', to_char(c.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'),
    'datos', (select row_to_json(d) from (select cedula, to_char(nacimiento, 'YYYY-MM-DD') as nacimiento, email, direccion, contacto_nombre, contacto_tel, representante from luna_dental.paciente_datos where clienta_id = p_id) d),
    'citas', (select coalesce(json_agg(json_build_object('id', ci.id, 'dia', to_char(ci.inicio at time zone 'America/Guayaquil', 'YYYY-MM-DD'), 'hora', to_char(ci.inicio at time zone 'America/Guayaquil', 'HH24:MI'),
        'duracion', (extract(epoch from (ci.fin - ci.inicio)) / 60)::int, 'servicio', sv.nombre, 'estado', ci.estado, 'doctor', dc.nombre) order by ci.inicio desc), '[]'::json)
      from luna_dental.citas ci join luna_dental.servicios sv on sv.id = ci.servicio_id left join luna_dental.doctores dc on dc.id = ci.doctor_id where ci.clienta_id = p_id),
    'cobros', (select coalesce(json_agg(json_build_object('id', m.id, 'dia', to_char(m.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'), 'descripcion', m.descripcion, 'importe', m.importe, 'tipo', m.tipo, 'anulado', m.anulado) order by m.creado desc), '[]'::json)
      from luna_dental.caja m where m.clienta_id = p_id),
    'presupuestos', (select coalesce(json_agg(json_build_object('id', p.id, 'dia', to_char(p.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'), 'total', p.total, 'estado', p.estado, 'descuento', p.descuento_pct,
        'items', (select json_agg(json_build_object('descripcion', i.descripcion, 'cant', i.cant, 'precio', i.precio) order by i.id) from luna_dental.presupuesto_items i where i.presupuesto_id = p.id)) order by p.creado desc), '[]'::json)
      from luna_dental.presupuestos p where p.clienta_id = p_id),
    'consentimientos', (select coalesce(json_agg(json_build_object('tipo', t.tipo, 'otorgado', t.otorgado, 'quien', t.quien, 'dia', to_char(t.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'))), '[]'::json)
      from (select distinct on (tipo) tipo, otorgado, quien, creado from luna_dental.consentimientos where clienta_id = p_id order by tipo, id desc) t),
    'acceso_clinico', clin,
    'clinico', case when clin then (select row_to_json(v) from (select alergias, medicamentos, antecedentes_medicos, antecedentes_odonto, habitos, observaciones,
        to_char(creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI') as actualizado from luna_dental.clinico_versiones where clienta_id = p_id order by id desc limit 1) v) end,
    'odontograma', case when clin then (select coalesce(json_agg(json_build_object('diente', o.diente, 'estado', o.estado, 'nota', o.nota, 'dia', to_char(o.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD'))), '[]'::json)
      from (select distinct on (diente) diente, estado, nota, creado from luna_dental.odontograma_mov where clienta_id = p_id order by diente, id desc) o) end,
    'evoluciones', case when clin then (select coalesce(json_agg(json_build_object('id', e.id, 'dia', to_char(e.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI'), 'motivo', e.motivo, 'diagnostico', e.diagnostico,
        'procedimiento', e.procedimiento, 'indicaciones', e.indicaciones, 'doctor', dc.nombre, 'autor', s.nombre, 'corrige_id', e.corrige_id, 'cita_id', e.cita_id) order by e.id desc), '[]'::json)
      from luna_dental.evoluciones e left join luna_dental.doctores dc on dc.id = e.doctor_id left join luna_dental.staff s on s.user_id = e.staff_id where e.clienta_id = p_id) end
  ) into r;
  return r;
end $$;

create function luna_dental.paciente_guardar(p_id bigint, p_nombre text, p_telefono text, p_cedula text, p_nacimiento date, p_email text, p_direccion text,
  p_contacto_nombre text, p_contacto_tel text, p_representante text) returns json language plpgsql security definer set search_path = '' as $$
declare tel text := luna_dental.tel(p_telefono); cid bigint := p_id; hoy date := (now() at time zone 'America/Guayaquil')::date;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre del paciente.'; end if;
  if tel = '' then raise exception 'Escribe un celular válido (09...).'; end if;
  if p_nacimiento is not null and (p_nacimiento > hoy or p_nacimiento < date '1900-01-01') then raise exception 'La fecha de nacimiento no es válida.'; end if;
  if p_nacimiento is not null and p_nacimiento > hoy - interval '18 years' and length(trim(coalesce(p_representante, ''))) < 2 then
    raise exception 'Para un menor de edad escribe el nombre de su representante.'; end if;
  if cid is null then
    insert into luna_dental.clientas (codigo, nombre, telefono) values (luna_dental.codigo(), trim(left(p_nombre, 80)), tel) returning id into cid;
  else
    update luna_dental.clientas set nombre = trim(left(p_nombre, 80)), telefono = tel where id = cid;
    if not found then raise exception 'Paciente no encontrado.'; end if;
  end if;
  insert into luna_dental.paciente_datos (clienta_id, cedula, nacimiento, email, direccion, contacto_nombre, contacto_tel, representante)
  values (cid, nullif(trim(p_cedula), ''), p_nacimiento, nullif(trim(p_email), ''), nullif(trim(p_direccion), ''), nullif(trim(p_contacto_nombre), ''), nullif(trim(p_contacto_tel), ''), nullif(trim(p_representante), ''))
  on conflict (clienta_id) do update set cedula = excluded.cedula, nacimiento = excluded.nacimiento, email = excluded.email, direccion = excluded.direccion,
    contacto_nombre = excluded.contacto_nombre, contacto_tel = excluded.contacto_tel, representante = excluded.representante, actualizado = now();
  perform luna_dental._audit(case when p_id is null then 'crear_paciente' else 'editar_datos' end, cid, null);
  return json_build_object('id', cid);
exception when unique_violation then raise exception 'Ya existe un paciente con ese celular o esa cédula.';
end $$;

create function luna_dental.consentimiento_registrar(p_id bigint, p_tipo text, p_otorgado boolean, p_quien text) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if p_tipo not in ('datos', 'tratamiento', 'imagenes') then raise exception 'Tipo no válido.'; end if;
  if length(trim(coalesce(p_quien, ''))) < 2 then raise exception 'Escribe el nombre de quien da el consentimiento (el paciente o su representante).'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  insert into luna_dental.consentimientos (clienta_id, tipo, otorgado, quien, staff_id) values (p_id, p_tipo, coalesce(p_otorgado, false), trim(left(p_quien, 80)), auth.uid());
  perform luna_dental._audit('consentimiento', p_id, p_tipo || ': ' || case when p_otorgado then 'otorgado' else 'retirado' end);
end $$;

-- ---------- parte clínica (solo admin y doctor) ----------
create function luna_dental.paciente_clinico_guardar(p_id bigint, p_alergias text, p_medicamentos text, p_antecedentes_medicos text, p_antecedentes_odonto text, p_habitos text, p_observaciones text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  insert into luna_dental.clinico_versiones (clienta_id, alergias, medicamentos, antecedentes_medicos, antecedentes_odonto, habitos, observaciones, staff_id)
  values (p_id, nullif(trim(p_alergias), ''), nullif(trim(p_medicamentos), ''), nullif(trim(p_antecedentes_medicos), ''), nullif(trim(p_antecedentes_odonto), ''), nullif(trim(p_habitos), ''), nullif(trim(p_observaciones), ''), auth.uid());
  perform luna_dental._audit('editar_clinico', p_id, null);
end $$;

create function luna_dental.odontograma_marcar(p_id bigint, p_diente int, p_estado text, p_nota text, p_doctor bigint) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  insert into luna_dental.odontograma_mov (clienta_id, diente, estado, nota, doctor_id, staff_id) values (p_id, p_diente, p_estado, nullif(trim(left(p_nota, 200)), ''), p_doctor, auth.uid());
  perform luna_dental._audit('odontograma', p_id, p_diente::text || ' ' || p_estado);
exception when check_violation then raise exception 'Diente o estado no válido.';
end $$;

create function luna_dental.evolucion_guardar(p_id bigint, p_cita bigint, p_doctor bigint, p_motivo text, p_diagnostico text, p_procedimiento text, p_indicaciones text, p_corrige bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare eid bigint;
begin
  if not luna_dental.es_clinico() then raise exception 'No autorizado'; end if;
  if not exists (select 1 from luna_dental.clientas where id = p_id) then raise exception 'Paciente no encontrado.'; end if;
  if not luna_dental._consiente(p_id, 'tratamiento') then raise exception 'Primero registra el consentimiento de tratamiento del paciente.'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo de la consulta.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  if p_cita is not null and not exists (select 1 from luna_dental.citas where id = p_cita and clienta_id = p_id) then raise exception 'Esa cita no es de este paciente.'; end if;
  if p_corrige is not null and not exists (select 1 from luna_dental.evoluciones where id = p_corrige and clienta_id = p_id) then raise exception 'La nota que corriges no es de este paciente.'; end if;
  insert into luna_dental.evoluciones (clienta_id, cita_id, doctor_id, motivo, diagnostico, procedimiento, indicaciones, corrige_id, staff_id)
  values (p_id, p_cita, p_doctor, trim(left(p_motivo, 300)), nullif(trim(p_diagnostico), ''), nullif(trim(p_procedimiento), ''), nullif(trim(p_indicaciones), ''), p_corrige, auth.uid()) returning id into eid;
  perform luna_dental._audit(case when p_corrige is null then 'evolucion' else 'corrige_evolucion' end, p_id, eid::text);
  return eid;
end $$;

create function luna_dental.auditoria_lista(p_id bigint default null, p_limite int default 100) returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not luna_dental.es_admin() then raise exception 'Solo admin.'; end if;
  return (select coalesce(json_agg(x), '[]'::json) from (
    select to_char(a.creado at time zone 'America/Guayaquil', 'YYYY-MM-DD HH24:MI') as cuando, coalesce(s.nombre, 'Cuenta retirada') as quien, a.accion, c.nombre as paciente, a.detalle
    from luna_dental.auditoria a left join luna_dental.staff s on s.user_id = a.user_id left join luna_dental.clientas c on c.id = a.clienta_id
    where p_id is null or a.clienta_id = p_id order by a.id desc limit least(greatest(coalesce(p_limite, 100), 1), 500)) x);
end $$;

-- ---------- cobros y presupuestos ligados al paciente (reemplazan a los de 006: mismo comportamiento + paciente opcional) ----------
drop function luna_dental.caja_registrar(text, numeric, text, bigint);
create function luna_dental.caja_registrar(p_descripcion text, p_importe numeric, p_tipo text, p_doctor bigint, p_clienta bigint default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare i bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
  if length(trim(coalesce(p_descripcion, ''))) < 2 then raise exception 'Escribe una descripción.'; end if;
  if p_importe is null or p_importe <= 0 or p_importe > 100000 then raise exception 'Importe no válido.'; end if;
  if p_tipo not in ('ing', 'egr') then raise exception 'Tipo no válido.'; end if;
  if p_doctor is not null and not exists (select 1 from luna_dental.doctores where id = p_doctor) then raise exception 'Doctor no válido.'; end if;
  if p_clienta is not null and not exists (select 1 from luna_dental.clientas where id = p_clienta) then raise exception 'Paciente no encontrado.'; end if;
  insert into luna_dental.caja (descripcion, importe, tipo, doctor_id, staff_id, clienta_id) values (trim(left(p_descripcion, 80)), round(p_importe, 2), p_tipo, p_doctor, auth.uid(), p_clienta) returning id into i;
  return i;
end $$;

drop function luna_dental.presupuesto_guardar(text, bigint, int, json, date);
create function luna_dental.presupuesto_guardar(p_paciente text, p_doctor bigint, p_descuento int, p_items json, p_seguimiento date, p_clienta bigint default null) returns json
language plpgsql security definer set search_path = '' as $$
declare it json; t luna_dental.tarifario; n int := 0; sub numeric := 0; pid bigint; tot numeric; cl bigint;
begin
  if not luna_dental.es_staff() then raise exception 'No autorizado'; end if;
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

-- ---------- permisos ----------
revoke all on function
  luna_dental.es_clinico(), luna_dental._audit(text, bigint, text), luna_dental._consiente(bigint, text), luna_dental._solo_agregar(),
  luna_dental.pacientes_buscar(text), luna_dental.paciente_ficha(bigint),
  luna_dental.paciente_guardar(bigint, text, text, text, date, text, text, text, text, text), luna_dental.consentimiento_registrar(bigint, text, boolean, text),
  luna_dental.paciente_clinico_guardar(bigint, text, text, text, text, text, text), luna_dental.odontograma_marcar(bigint, int, text, text, bigint),
  luna_dental.evolucion_guardar(bigint, bigint, bigint, text, text, text, text, bigint), luna_dental.auditoria_lista(bigint, int),
  luna_dental.caja_registrar(text, numeric, text, bigint, bigint), luna_dental.presupuesto_guardar(text, bigint, int, json, date, bigint)
from public, anon, authenticated;
grant execute on function
  luna_dental.pacientes_buscar(text), luna_dental.paciente_ficha(bigint),
  luna_dental.paciente_guardar(bigint, text, text, text, date, text, text, text, text, text), luna_dental.consentimiento_registrar(bigint, text, boolean, text),
  luna_dental.paciente_clinico_guardar(bigint, text, text, text, text, text, text), luna_dental.odontograma_marcar(bigint, int, text, text, bigint),
  luna_dental.evolucion_guardar(bigint, bigint, bigint, text, text, text, text, bigint), luna_dental.auditoria_lista(bigint, int),
  luna_dental.caja_registrar(text, numeric, text, bigint, bigint), luna_dental.presupuesto_guardar(text, bigint, int, json, date, bigint)
to authenticated;
