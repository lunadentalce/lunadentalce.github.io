/* clinica-ui.js · piezas comunes de equipo.html y dueno.html: ayudas de texto/fecha, avisos y la puerta de entrada (login).
   Todo el texto que viene de la base pasa por esc() antes de pintarse. */
(() => {
  const esc = t => String(t ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const $ = (s, r) => (r || document).querySelector(s), $$ = (s, r) => [...(r || document).querySelectorAll(s)];
  const TZ = 'America/Guayaquil';
  const usd = n => '$' + Number(n || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const hoy = () => new Date().toLocaleDateString('en-CA', { timeZone: TZ });
  const suma = (s, n) => { const d = new Date(s + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const dif = (a, b) => Math.round((new Date(a + 'T12:00:00Z') - new Date(b + 'T12:00:00Z')) / 864e5);
  const dow = s => (new Date(s + 'T12:00:00Z').getUTCDay() + 6) % 7;              // 0 = lunes … 6 = domingo
  const lunes = s => suma(s, -dow(s));
  const fechaCorta = s => new Date(s + 'T12:00:00Z').toLocaleDateString('es-EC', { weekday: 'short', day: '2-digit', month: 'short', timeZone: 'UTC' });
  const fechaLarga = s => new Date(s + 'T12:00:00Z').toLocaleDateString('es-EC', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });
  const tel09 = t => String(t || '').replace(/^593/, '0');
  const waNum = t => String(t || '').replace(/\D/g, '');
  const wa = (n, t) => `https://wa.me/${waNum(n)}?text=${encodeURIComponent(t)}`;
  const pct = (a, b) => b > 0 ? Math.round(a / b * 100) : null;
  const msgErr = e => (e && e.message) || 'No se pudo completar la acción.';

  let _av;
  function aviso(texto, tipo) {
    let a = $('#aviso-clin'); if (!a) { a = document.createElement('div'); a.id = 'aviso-clin'; a.setAttribute('role', 'status'); a.setAttribute('aria-live', 'polite'); document.body.append(a); }
    a.textContent = texto; a.className = 'toast ' + (tipo || 'ok') + ' on'; clearTimeout(_av); _av = setTimeout(() => a.classList.remove('on'), tipo === 'mal' ? 6000 : 3200);
  }

  /* Puerta de entrada. Muestra el formulario (producción) o los botones de rol (demo) y devuelve la sesión.
     opciones.soloAdmin: la pantalla es solo del rol admin (dueño): otro rol ve un aviso en vez del contenido. */
  async function puerta(opc) {
    opc = opc || {};
    const caja = $('#puerta'), contenido = $('#contenido'), C = window.CLINICA;
    const mostrar = yo => {
      if (opc.soloAdmin && yo.rol !== 'admin') {
        caja.hidden = false; contenido.hidden = true;
        caja.innerHTML = `<div class="puerta-card"><h2>Esta pantalla es del dueño</h2><p>Tu cuenta (${esc(yo.nombre)}) es de recepción. Pide acceso de administrador o vuelve al panel del equipo.</p>
          <div class="acciones"><a class="btn" href="${esc(opc.volver || 'equipo.html')}">Ir al panel del equipo</a><button type="button" class="btn btn-linea" id="p-salir">Salir</button></div></div>`;
        $('#p-salir').onclick = () => { C.staff.salir(); location.reload(); }; return null;
      }
      caja.hidden = true; contenido.hidden = false; return yo;
    };
    if (!C.conectado) {
      caja.hidden = false; contenido.hidden = true;
      caja.innerHTML = `<div class="puerta-card"><h2>Falta conectar la base de datos</h2><p>Esta página todavía no tiene la dirección y la clave pública de Supabase en <code>config.js</code>. Cuando estén, aquí entra el equipo con su correo y su clave.</p></div>`;
      return null;
    }
    const yo = await C.staff.sesion().catch(() => null);
    if (yo) return mostrar(yo);
    contenido.hidden = true; caja.hidden = false;
    const demo = C.modo === 'demo';
    caja.innerHTML = `<form class="puerta-card" id="p-form" novalidate>
        <h2>${demo ? 'Entra a la demo' : 'Entrar al panel'}</h2>
        ${demo ? `<p>Elige quién eres para ver cómo cambia lo que cada persona puede hacer. Todo son datos de ejemplo guardados solo en este navegador.</p>
          <div class="acciones"><button type="button" class="btn" data-rol="recepcion">Entrar como recepción</button><button type="button" class="btn btn-linea" data-rol="admin">Entrar como dueña</button></div>`
        : `<p>Solo para el equipo de la clínica. Usa el correo y la clave que te dio la administración.</p>
          <div class="campo"><label for="p-mail">Correo</label><input id="p-mail" type="email" autocomplete="username" required></div>
          <div class="campo"><label for="p-clave">Clave</label><input id="p-clave" type="password" autocomplete="current-password" required></div>
          <button class="btn" type="submit">Entrar</button>`}
        <p class="puerta-err" id="p-err" role="alert"></p></form>`;
    const entrar = async (a, b) => { const er = $('#p-err'); er.textContent = '';
      try { const y = await C.staff.entrar(a, b); if (mostrar(y)) opc.alEntrar && opc.alEntrar(y); } catch (e) { er.textContent = msgErr(e); } };
    return new Promise(ok => {
      opc.alEntrar = y => ok(y);
      if (demo) $$('[data-rol]').forEach(b => b.onclick = () => entrar(b.dataset.rol));
      else $('#p-form').onsubmit = e => { e.preventDefault(); const m = $('#p-mail').value.trim(), c = $('#p-clave').value; if (!m || !c) { $('#p-err').textContent = 'Escribe tu correo y tu clave.'; return; } entrar(m, c); };
    });
  }

  window.CLUI = { esc, $, $$, usd, hoy, suma, dif, dow, lunes, fechaCorta, fechaLarga, tel09, waNum, wa, pct, msgErr, aviso, puerta, TZ };
})();
