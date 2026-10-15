-- Módulo de clínica dental · 005 esquema (se aplica DESPUÉS de las migraciones 001–004 del módulo citas).
-- Se instala con scripts/migraciones-modulo.py clinica <cliente>, que copia citas (001–004) y luego estas y reemplaza luna_dental.
-- Reglas de CLAUDE.md §4: RLS en todas las tablas y SIN políticas; todo pasa por funciones security definer.
-- NO guarda historia clínica ni diagnósticos: solo datos comerciales (agenda, caja, presupuestos). Los datos de salud son sensibles
-- (Ley Orgánica de Protección de Datos Personales) y se activan aparte, con consentimiento y almacenamiento definidos con la clínica.

alter table luna_dental.config
  add column max_solicitudes_hora int not null default 20 check (max_solicitudes_hora between 1 and 500),
  add column max_solicitudes_tel_dia int not null default 3 check (max_solicitudes_tel_dia between 1 and 20);

create table luna_dental.doctores (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  especialidad text,
  color text not null default '#B8933A' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  activo boolean not null default true,
  orden int not null default 0
);

alter table luna_dental.citas add column doctor_id bigint references luna_dental.doctores (id);
create index citas_doctor_idx on luna_dental.citas (doctor_id, inicio);

-- Tarifario: el precio de un presupuesto sale de aquí, nunca del navegador (§4.5)
create table luna_dental.tarifario (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  precio numeric(10, 2) not null check (precio >= 0),
  activo boolean not null default true,
  orden int not null default 0
);

-- Solicitudes de cita que llegan de la web: el personal las convierte en cita con hora exacta
create table luna_dental.solicitudes (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  telefono text not null check (telefono ~ '^593[0-9]{9}$'),
  servicio_ids bigint[] not null check (cardinality(servicio_ids) between 1 and 4),
  dia date not null,
  franja text not null check (franja in ('manana', 'tarde', 'cualquiera')),
  para_menor boolean not null default false,
  representante text,                                         -- quien autoriza si el paciente es menor de edad
  consentimiento_en timestamptz not null,                     -- cuándo aceptó el tratamiento de sus datos
  estado text not null default 'nueva' check (estado in ('nueva', 'agendada', 'descartada')),
  cita_id bigint references luna_dental.citas (id),
  atendida_por uuid references auth.users (id),
  creado timestamptz not null default now(),
  check (not para_menor or length(trim(coalesce(representante, ''))) >= 2)
);
create index solicitudes_estado_idx on luna_dental.solicitudes (estado, creado);
create index solicitudes_tel_idx on luna_dental.solicitudes (telefono, creado);

-- Caja: movimientos inmutables; se corrigen con anulación (§4.9)
create table luna_dental.caja (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  descripcion text not null check (length(trim(descripcion)) >= 2),
  importe numeric(10, 2) not null check (importe > 0 and importe <= 100000),
  tipo text not null check (tipo in ('ing', 'egr')),
  doctor_id bigint references luna_dental.doctores (id),
  staff_id uuid not null references auth.users (id),
  anulado boolean not null default false,
  anulado_por uuid references auth.users (id),
  anulado_en timestamptz,
  motivo_anulacion text
);
create index caja_creado_idx on luna_dental.caja (creado);

create function luna_dental._caja_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Los movimientos de caja no se borran: se anulan.'; end if;
  if old.anulado or new.anulado is not true
     or (old.creado, old.descripcion, old.importe, old.tipo, old.doctor_id, old.staff_id)
        is distinct from (new.creado, new.descripcion, new.importe, new.tipo, new.doctor_id, new.staff_id) then
    raise exception 'Un movimiento de caja solo se puede anular.';
  end if;
  return new;
end $$;
create trigger caja_inmutable before update or delete on luna_dental.caja for each row execute function luna_dental._caja_inmutable();

-- Presupuestos: el contenido no cambia después de guardarlo; solo avanza su estado y su seguimiento
create table luna_dental.presupuestos (
  id bigint generated always as identity primary key,
  paciente text not null check (length(trim(paciente)) >= 2),
  clienta_id bigint references luna_dental.clientas (id),
  doctor_id bigint references luna_dental.doctores (id),
  descuento_pct int not null default 0 check (descuento_pct between 0 and 50),
  total numeric(10, 2) not null check (total >= 0),
  estado text not null default 'enviado' check (estado in ('enviado', 'aceptado', 'rechazado')),
  seguimiento date,
  staff_id uuid not null references auth.users (id),
  creado timestamptz not null default now(),
  decidido_en timestamptz
);
create index presupuestos_estado_idx on luna_dental.presupuestos (estado, creado);

create table luna_dental.presupuesto_items (
  id bigint generated always as identity primary key,
  presupuesto_id bigint not null references luna_dental.presupuestos (id),
  tarifario_id bigint not null references luna_dental.tarifario (id),
  descripcion text not null,
  cant int not null check (cant between 1 and 20),
  precio numeric(10, 2) not null check (precio >= 0)
);
create index presupuesto_items_idx on luna_dental.presupuesto_items (presupuesto_id);

create function luna_dental._presupuesto_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_table_name = 'presupuesto_items' then raise exception 'Los renglones de un presupuesto no se editan ni se borran: se crea otro presupuesto.'; end if;
  if tg_op = 'DELETE' then raise exception 'Los presupuestos no se borran.'; end if;
  if (old.paciente, old.clienta_id, old.doctor_id, old.descuento_pct, old.total, old.staff_id, old.creado)
     is distinct from (new.paciente, new.clienta_id, new.doctor_id, new.descuento_pct, new.total, new.staff_id, new.creado) then
    raise exception 'El contenido de un presupuesto no se edita: se crea otro.'; end if;
  if old.estado <> 'enviado' and new.estado is distinct from old.estado then raise exception 'Un presupuesto ya decidido no cambia de estado.'; end if;
  return new;
end $$;
create trigger presupuestos_inmutable before update or delete on luna_dental.presupuestos for each row execute function luna_dental._presupuesto_inmutable();
create trigger presupuesto_items_inmutable before update or delete on luna_dental.presupuesto_items for each row execute function luna_dental._presupuesto_inmutable();

alter table luna_dental.doctores enable row level security;
alter table luna_dental.tarifario enable row level security;
alter table luna_dental.solicitudes enable row level security;
alter table luna_dental.caja enable row level security;
alter table luna_dental.presupuestos enable row level security;
alter table luna_dental.presupuesto_items enable row level security;
revoke all on all tables in schema luna_dental from public, anon, authenticated;
