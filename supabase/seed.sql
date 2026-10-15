-- Semilla de Luna Dental · se corre UNA vez, después de las migraciones 001–007. Lo marcado CONFIRMAR lo da la clínica.
-- Los nombres de los tratamientos deben ser IGUALES a los de la carta de la página (menu.js): así se une la solicitud con su tratamiento.
insert into luna_dental.servicios (nombre, categoria, duracion_min, fidelidad, orden) values
  ('Valoración inicial', 'Tratamientos', 30, false, 1),
  ('Odontopediatría', 'Tratamientos', 30, false, 2),
  ('Ortodoncia', 'Tratamientos', 30, false, 3),
  ('Estética dental', 'Tratamientos', 30, false, 4),
  ('Implantes', 'Tratamientos', 30, false, 5),
  ('Prótesis', 'Tratamientos', 30, false, 6),
  ('Cirugía oral', 'Tratamientos', 30, false, 7);   -- CONFIRMAR: duración real de cada tratamiento (15 a 240 min)

-- Horario de atención (1 = lunes … 7 = domingo). CONFIRMAR con la clínica y descomentar:
-- insert into luna_dental.horario (dia_semana, abre, cierra) values (1, '08:00', '17:00'), (2, '08:00', '17:00');

-- Doctores y tarifario los carga el administrador desde equipo.html › Ajustes (nombres y precios reales).

-- Personal: primero crea el usuario en Supabase › Authentication › Add user (correo y clave); luego, con su id:
-- insert into luna_dental.staff (user_id, nombre, rol) values ('<uuid del usuario>', 'Nombre', 'admin');   -- rol: admin (dueño) o recepcion
