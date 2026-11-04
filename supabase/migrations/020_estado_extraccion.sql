-- 020 · Nuevo estado del odontograma: «extraccion» (exodoncia). En el dibujo es una X roja sobre el diente: el diente está indicado para extraer.
-- Cuando se hace la extracción, el diente se marca «ausente» (X gris). Se agrega a la lista de estados permitidos; no cambia nada de lo ya guardado.
-- Orden de instalación: después de 019. Todo calificado con el schema del cliente.

alter table luna_dental.odontograma_mov drop constraint odontograma_mov_estado_check;
alter table luna_dental.odontograma_mov add constraint odontograma_mov_estado_check
  check (estado in ('sano', 'caries', 'resina', 'endodoncia', 'corona', 'brackets', 'implante', 'protesis', 'ausente', 'extraccion'));
