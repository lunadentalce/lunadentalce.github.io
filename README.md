# Luna Dental · sitio y paneles

Sitio estático (HTML/CSS/JS sin build) publicado en GitHub Pages. La base es Supabase, schema **`luna_dental`** (un schema por cliente; nada en `public`).

| Página | Quién | Qué hace |
|---|---|---|
| `index.html` | Pacientes | Landing: tratamientos, «Qué necesita tu sonrisa», reserva (la solicitud se guarda y sale por WhatsApp) |
| `equipo.html` | Recepción y administración | Trabajo diario: solicitudes de la web → cita con hora y doctor, agenda de todos los doctores (nueva cita, mover, cambiar estado), pacientes con su ficha, caja con anulaciones, presupuestos con precio del tarifario. Los doctores ven además la parte clínica de la ficha |
| `dueno.html` | Solo administración | Todo lo anterior más el resumen (ingresos, citas atendidas, inasistencia, pacientes nuevos, presupuestos por periodo; imprimir y CSV) y la configuración: doctores, tarifario, tratamientos y duración, horario con pausa de almuerzo y cuentas del equipo |
| `privacidad.html` | Pacientes | Política de privacidad (borrador que debe revisar un asesor legal) |

## Puesta en marcha (una vez)
1. **Proyecto Supabase:** si es el proyecto compartido de la agencia, antes de empezar confirma que el schema `luna_dental` no existe y no cambies ajustes globales (Authentication, extensiones, claves).
2. **SQL Editor:** corre en orden `supabase/migrations/001…009`, luego `supabase/seed.sql` (completa lo marcado CONFIRMAR).
3. **Settings › API › Exposed schemas:** agrega `luna_dental` **sin quitar** los que ya están.
4. **Personal:** Authentication › Add user (correo y clave) por cada persona, y luego la fila en `luna_dental.staff` (ver el final de `seed.sql`). Nadie se da de alta como personal por su cuenta: ninguna función da acceso solo por «tener sesión», todas comprueban la tabla `staff`.
5. **`config.js`:** pon `clinica.url` (Project URL) y `clinica.anonKey` (clave **anon**; la `service_role` nunca va en el repo).
6. **GitHub Pages:** push a `main`. Dominio propio en Settings › Pages.
7. **Probar de punta a punta:** una solicitud desde `index.html` → aparece en `equipo.html` › Solicitudes → agendar → agenda → cobrar en caja → presupuesto → `dueno.html`.

## Seguridad (CLAUDE.md §4)
- RLS activado en todas las tablas y sin políticas: el navegador nunca lee ni escribe tablas; solo llama funciones `security definer` con `set search_path = ''`.
- El paciente (`anon`) solo puede ejecutar `solicitar_cita` (con consentimiento obligatorio, tope por hora y por teléfono) y las funciones públicas de citas.
- Caja, presupuestos y sellos son inmutables: se corrigen con anulación. El precio de un presupuesto sale del tarifario en SQL, no del navegador.
- **La ficha clínica guarda datos de salud (sensibles, LOPDP):** solo la ven administración y doctores, exige el consentimiento del paciente, no se edita ni se borra (se corrige con una nota nueva) y cada acceso queda en la auditoría. Antes de usarla con pacientes reales: revisión legal de `privacidad.html`, política de respaldos y formato de consentimiento firmado en persona. Radiografías y fotos no están incluidas.
- Pruebas del módulo: `PG_URI=… python3 modulos/clinica/probar.py` (en el repo de la agencia, `landing-base`).
