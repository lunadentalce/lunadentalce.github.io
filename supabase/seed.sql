-- Semilla de Luna Dental Centro de Especialidades Odontológicas · se corre UNA vez, después de las migraciones 001–012. Lo marcado CONFIRMAR lo da la clínica.
-- Los nombres de los tratamientos deben ser IGUALES a los de la carta de la página (menu.js): así se une la solicitud con su tratamiento.
insert into luna_dental.servicios (nombre, categoria, duracion_min, fidelidad, orden) values
  ('Valoración inicial', 'Tratamientos', 40, false, 1),
  ('Odontopediatría', 'Tratamientos', 40, false, 2),
  ('Ortodoncia', 'Tratamientos', 40, false, 3),
  ('Estética dental', 'Tratamientos', 40, false, 4),
  ('Implantes', 'Tratamientos', 40, false, 5),
  ('Prótesis', 'Tratamientos', 40, false, 6),
  ('Cirugía oral', 'Tratamientos', 40, false, 7);   -- CONFIRMAR: duración real de cada tratamiento (40 min por ahora)

-- Las citas se ofrecen cada 20 min dentro del horario (con tratamientos de 40 min, 20 deja encajar bien antes y después del almuerzo).
update luna_dental.config set paso_min = 20 where id = 1;

-- Horario de atención (1 = lunes … 7 = domingo), con pausa de almuerzo donde no se agenda. CONFIRMAR con la clínica:
insert into luna_dental.horario (dia_semana, abre, cierra, pausa_ini, pausa_fin) values (1, '09:00', '18:00', '13:00', '14:00'), (2, '09:00', '18:00', '13:00', '14:00'), (3, '09:00', '18:00', '13:00', '14:00'), (4, '09:00', '18:00', '13:00', '14:00'), (5, '09:00', '18:00', '13:00', '14:00'), (6, '09:00', '18:00', '13:00', '14:00');

-- Doctores y tarifario los carga el administrador desde equipo.html › Ajustes (nombres y precios reales).

-- Personal: primero crea el usuario en Supabase › Authentication › Add user (correo y clave); luego, con su id:
-- insert into luna_dental.staff (user_id, nombre, rol) values ('<uuid del usuario>', 'Nombre', 'admin');   -- rol: admin (dueño) o recepcion
