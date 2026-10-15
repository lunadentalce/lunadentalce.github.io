-- Módulo de clínica dental · 007 permisos (§4.3). Postgres concede EXECUTE a PUBLIC en cada función nueva: se revoca explícitamente en las de este módulo
-- (las del módulo citas ya quedaron resueltas en 004) y luego se concede solo lo necesario.
revoke all on function
  luna_dental.solicitar_cita(text, text, bigint[], date, text, boolean, text, boolean),
  luna_dental.doctores_lista(), luna_dental.doctor_guardar(bigint, text, text, text, boolean),
  luna_dental.tarifario_lista(), luna_dental.tarifario_guardar(bigint, text, numeric, boolean),
  luna_dental.solicitudes_lista(text), luna_dental.solicitud_descartar(bigint), luna_dental.solicitud_agendar(bigint, bigint, date, text, bigint),
  luna_dental.clinica_agenda(date, date), luna_dental.cita_doctor(bigint, bigint),
  luna_dental.caja_dia(date), luna_dental.caja_registrar(text, numeric, text, bigint), luna_dental.caja_anular(bigint, text),
  luna_dental.presupuesto_guardar(text, bigint, int, json, date), luna_dental.presupuestos_lista(text), luna_dental.presupuesto_estado(bigint, text),
  luna_dental.dueno_resumen(date, date), luna_dental._caja_inmutable(), luna_dental._presupuesto_inmutable()
from public, anon, authenticated;

-- El paciente (sin sesión): solo la solicitud de cita
grant execute on function luna_dental.solicitar_cita(text, text, bigint[], date, text, boolean, text, boolean) to anon, authenticated;

-- El personal (con sesión): cada función comprueba es_staff() / es_admin() por dentro
grant execute on function
  luna_dental.doctores_lista(), luna_dental.doctor_guardar(bigint, text, text, text, boolean),
  luna_dental.tarifario_lista(), luna_dental.tarifario_guardar(bigint, text, numeric, boolean),
  luna_dental.solicitudes_lista(text), luna_dental.solicitud_descartar(bigint), luna_dental.solicitud_agendar(bigint, bigint, date, text, bigint),
  luna_dental.clinica_agenda(date, date), luna_dental.cita_doctor(bigint, bigint),
  luna_dental.caja_dia(date), luna_dental.caja_registrar(text, numeric, text, bigint), luna_dental.caja_anular(bigint, text),
  luna_dental.presupuesto_guardar(text, bigint, int, json, date), luna_dental.presupuestos_lista(text), luna_dental.presupuesto_estado(bigint, text),
  luna_dental.dueno_resumen(date, date)
to authenticated;
