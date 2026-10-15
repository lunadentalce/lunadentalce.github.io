-- Módulo de citas · 004 permisos (§4.3): primero se revoca TODO a public/anon/authenticated y luego se concede solo lo necesario.
-- Postgres concede EXECUTE a PUBLIC por defecto en cada función nueva; por eso el revoke va explícito.
revoke all on all functions in schema luna_dental from public, anon, authenticated;
alter default privileges in schema luna_dental revoke execute on functions from public, anon, authenticated;
grant usage on schema luna_dental to anon, authenticated;

-- La clienta (sin sesión de Supabase): solo estas 8
grant execute on function
  luna_dental.ping(),
  luna_dental.servicios_lista(),
  luna_dental.disponibilidad(bigint, date),
  luna_dental.agendar(text, text, bigint, date, text),
  luna_dental.agendar_token(text, bigint, date, text),
  luna_dental.acceder(text, text),
  luna_dental.tarjeta(text),
  luna_dental.cancelar(text, bigint)
to anon, authenticated;

-- El personal (con sesión): las funciones comprueban es_staff()/es_admin() por dentro
grant execute on function
  luna_dental.yo(), luna_dental.agenda(date, date), luna_dental.pendientes(), luna_dental.buscar(text), luna_dental.ficha(text),
  luna_dental.clientas_lista(), luna_dental.registrar(text, text), luna_dental.cita_estado(bigint, text), luna_dental.mover_cita(bigint, date, text),
  luna_dental.cita_staff(text, text, bigint, date, text), luna_dental.sellar(text, bigint, bigint), luna_dental.canjear(text, bigint, bigint),
  luna_dental.anular(bigint), luna_dental.resumen(), luna_dental.config_admin(), luna_dental.config_guardar(int, int),
  luna_dental.servicio_guardar(bigint, text, text, text, int, text, boolean, boolean), luna_dental.horario_guardar(int, text, text),
  luna_dental.equipo_guardar(text, text, text), luna_dental.equipo_quitar(uuid)
to authenticated;
-- Ayudas internas (tel, es_staff, es_admin, codigo, prog, ocupadas, a_uuid, clienta_por_ref, json_clienta, _reservar): sin permiso para nadie.
-- Las llaman las funciones de arriba, que corren con los permisos de su dueño (security definer).
