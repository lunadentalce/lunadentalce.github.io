-- Módulo de citas y tarjeta de sellos · 001 esquema.
-- Se aplica con scripts/migraciones-modulo.py citas <schema>, que reemplaza luna_dental por el schema del cliente (ej.: dermabelle).
-- Reglas de CLAUDE.md §4: RLS en todas las tablas y SIN políticas (anon/authenticated nunca leen ni escriben tablas directo: todo pasa por funciones).
create schema if not exists luna_dental;

create table luna_dental.config (
  id int primary key default 1 check (id = 1),
  prefijo text not null default 'CL' check (prefijo ~ '^[A-Z]{2,4}$'),
  capacidad int not null default 1 check (capacidad between 1 and 10),          -- cabinas o puestos en paralelo
  paso_min int not null default 30 check (paso_min between 10 and 120),
  sellos_meta int not null default 5 check (sellos_meta between 2 and 20),
  anticipacion_min int not null default 60 check (anticipacion_min between 0 and 1440),
  max_dias int not null default 60 check (max_dias between 1 and 365),
  max_citas_activas int not null default 3 check (max_citas_activas between 1 and 10),   -- por clienta
  max_citas_hora int not null default 40 check (max_citas_hora between 1 and 500),       -- topes globales contra abuso
  max_registros_hora int not null default 20 check (max_registros_hora between 1 and 500)
);
insert into luna_dental.config default values;

create table luna_dental.horario (
  dia_semana int primary key check (dia_semana between 1 and 7),   -- 1 = lunes … 7 = domingo (isodow)
  abre time not null,
  cierra time not null,
  check (cierra > abre)
);

create table luna_dental.staff (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nombre text not null,
  rol text not null check (rol in ('admin', 'recepcion'))
);

create table luna_dental.servicios (
  id bigint generated always as identity primary key,
  nombre text not null check (length(trim(nombre)) >= 2),
  categoria text not null default 'General',
  descripcion text,
  duracion_min int not null check (duracion_min between 15 and 240),
  precio text,
  fidelidad boolean not null default true,       -- suma sellos hacia la sesión gratis
  orden int not null default 0,
  activo boolean not null default true
);

create table luna_dental.clientas (
  id bigint generated always as identity primary key,
  token uuid not null unique default gen_random_uuid(),                                         -- sesión de la clienta: NUNCA se muestra en el QR
  qr_token text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16), -- lo que muestra el QR: solo sirve al personal (§4.7)
  codigo text not null unique,
  nombre text not null check (length(trim(nombre)) >= 2),
  telefono text not null unique check (telefono ~ '^593[0-9]{9}$'),                              -- normalizado 593XXXXXXXXX (§4.12)
  creado timestamptz not null default now()
);

create table luna_dental.citas (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  servicio_id bigint not null references luna_dental.servicios (id),
  inicio timestamptz not null,
  fin timestamptz not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'confirmada', 'atendida', 'cancelada', 'no_vino')),
  creado timestamptz not null default now(),
  check (fin > inicio)
);
create index citas_inicio_idx on luna_dental.citas (inicio);
create index citas_clienta_idx on luna_dental.citas (clienta_id, estado);

-- Sellos y canjes: movimientos que otorgan valor. Inmutables: se corrigen con anulación (§4.9).
create table luna_dental.sellos (
  id bigint generated always as identity primary key,
  clienta_id bigint not null references luna_dental.clientas (id),
  servicio_id bigint not null references luna_dental.servicios (id),
  cita_id bigint references luna_dental.citas (id),
  tipo text not null check (tipo in ('sello', 'canje')),
  staff_id uuid not null references auth.users (id),
  anulado boolean not null default false,
  anulado_por uuid references auth.users (id),
  anulado_en timestamptz,
  creado timestamptz not null default now()
);
create unique index sellos_una_por_cita on luna_dental.sellos (cita_id) where cita_id is not null and not anulado;
create index sellos_clienta_idx on luna_dental.sellos (clienta_id, servicio_id);

create function luna_dental._sellos_inmutable() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Los sellos no se borran: se anulan.'; end if;
  if old.anulado or new.anulado is not true
     or (old.clienta_id, old.servicio_id, old.cita_id, old.tipo, old.staff_id, old.creado)
        is distinct from (new.clienta_id, new.servicio_id, new.cita_id, new.tipo, new.staff_id, new.creado) then
    raise exception 'Un sello solo se puede anular.';
  end if;
  return new;
end $$;
create trigger sellos_inmutable before update or delete on luna_dental.sellos for each row execute function luna_dental._sellos_inmutable();

-- Intentos fallidos de acceso con código + 4 dígitos (§4.8)
create table luna_dental.intentos (
  clave text primary key,
  n int not null default 0,
  desde timestamptz not null default now(),
  bloqueado_hasta timestamptz
);

alter table luna_dental.config enable row level security;
alter table luna_dental.horario enable row level security;
alter table luna_dental.staff enable row level security;
alter table luna_dental.servicios enable row level security;
alter table luna_dental.clientas enable row level security;
alter table luna_dental.citas enable row level security;
alter table luna_dental.sellos enable row level security;
alter table luna_dental.intentos enable row level security;
revoke all on all tables in schema luna_dental from public, anon, authenticated;
