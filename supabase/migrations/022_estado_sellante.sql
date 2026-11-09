-- 022 · Nuevo estado del odontograma: «sellante» (sellante de fosas y fisuras). Se marca por superficie (normalmente la oclusal) o en el diente completo.
-- Se agrega a la lista de estados permitidos; no cambia nada de lo ya guardado.
-- Orden de instalación: después de 021. Todo calificado con el schema del cliente.

alter table luna_dental.odontograma_mov drop constraint odontograma_mov_estado_check;
alter table luna_dental.odontograma_mov add constraint odontograma_mov_estado_check
  check (estado in ('sano', 'caries', 'resina', 'endodoncia', 'corona', 'brackets', 'implante', 'protesis', 'ausente', 'extraccion', 'sellante'));
