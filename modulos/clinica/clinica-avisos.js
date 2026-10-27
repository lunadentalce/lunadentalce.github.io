/* clinica-avisos.js · avisos de solicitudes nuevas en equipo.html y dueno.html, mientras el panel está abierto (tablet del consultorio, celular, computador).
   Cada 30 s (y al volver a la pantalla) mira las solicitudes de cita nuevas; si llegó una, muestra un aviso en pantalla, suena un tono corto, pone el número en la
   pestaña y, si el personal activó los avisos, muestra una notificación del navegador. No usa servidor de envío: con la app cerrada o la tablet bloqueada no llega.
   El botón «Activar avisos» pide el permiso del navegador una sola vez; el estado se guarda en este dispositivo. Todo lo que viene de la base pasa por esc(). */
(function () {
  const { esc, $, aviso } = CLUI, SEG = 30000;
  let C = null, vistas = null, timer = null, titulo0 = document.title, sinLeer = 0, ctx = null, reg = null, clave = 'avisos';
  const guardado = () => { try { return localStorage.getItem(clave) === 'on'; } catch (e) { return false; } };
  const guardar = v => { try { localStorage.setItem(clave, v ? 'on' : 'off'); } catch (e) {} };
  const hayNotif = () => 'Notification' in window;
  const activo = () => guardado() && (!hayNotif() || Notification.permission !== 'denied');

  function tono() {   // dos notas cortas; si el navegador no deja sonar todavía (sin toque previo), se omite en silencio
    try {
      ctx = ctx || new (window.AudioContext || window.webkitAudioContext)();
      if (ctx.state === 'suspended') ctx.resume();
      [[880, 0], [1175, .16]].forEach(([f, t]) => { const o = ctx.createOscillator(), g = ctx.createGain(); o.type = 'sine'; o.frequency.value = f; o.connect(g); g.connect(ctx.destination);
        const t0 = ctx.currentTime + t; g.gain.setValueAtTime(0, t0); g.gain.linearRampToValueAtTime(.22, t0 + .02); g.gain.exponentialRampToValueAtTime(.001, t0 + .3); o.start(t0); o.stop(t0 + .32); });
    } catch (e) {}
  }
  async function notificar(titulo, cuerpo) {
    if (!hayNotif() || Notification.permission !== 'granted') return;
    try { if (reg && reg.showNotification) await reg.showNotification(titulo, { body: cuerpo, icon: 'assets/icon-192.png', badge: 'assets/icon-192.png', tag: 'solicitud-nueva', renotify: true }); else new Notification(titulo, { body: cuerpo, icon: 'assets/icon-192.png', tag: 'solicitud-nueva' }); } catch (e) {}
  }
  function botonEstado() {
    const b = $('#s-avisos'); if (!b) return;
    const bloqueado = hayNotif() && Notification.permission === 'denied';
    b.textContent = bloqueado ? 'Avisos bloqueados' : activo() ? 'Avisos activados' : 'Activar avisos';
    b.setAttribute('aria-pressed', String(activo())); b.classList.toggle('on', activo());
    b.title = bloqueado ? 'El navegador los bloqueó: se activan en los permisos del sitio.' : 'Avisa cuando llega una solicitud de cita nueva (con el panel abierto).';
  }
  async function alternar() {
    if (activo()) { guardar(false); aviso('Avisos desactivados en este dispositivo.'); botonEstado(); return; }
    if (hayNotif() && Notification.permission === 'default') { try { await Notification.requestPermission(); } catch (e) {} }
    if (hayNotif() && Notification.permission === 'denied') { botonEstado(); aviso('El navegador tiene bloqueados los avisos de este sitio. Actívalos en los permisos del sitio y vuelve a intentar.', 'mal'); return; }
    guardar(true); botonEstado(); tono(); notificar('Avisos activados', 'Te avisaremos cuando llegue una solicitud de cita nueva.'); aviso('Avisos activados: sonarán con el panel abierto.');
  }
  function marcar(n) { sinLeer = n; document.title = n ? `(${n}) ${titulo0}` : titulo0; }

  async function revisar() {
    if (!C) return;
    let l; try { l = await C.rpc('solicitudes_lista', { p_estado: 'nueva' }); } catch (e) { return; }   // sin red o sesión vencida: se intenta en el próximo ciclo
    const n = $('#n-sol'); if (n) { n.textContent = l.length; n.hidden = !l.length; }
    const ids = new Set(l.map(s => s.id));
    if (vistas) {
      const nuevas = l.filter(s => !vistas.has(s.id));
      if (nuevas.length) {
        marcar(sinLeer + nuevas.length);
        if (activo() || !guardado()) {   // sin elegir nada todavía: igual se avisa en pantalla (sin sonido ni notificación del sistema)
          const s = nuevas[0], que = (s.servicios || []).map(x => x.nombre).join(', '), txt = nuevas.length > 1 ? `${nuevas.length} solicitudes de cita nuevas` : `Nueva solicitud de cita: ${s.nombre}`;
          aviso(txt);
          if (activo()) { tono(); notificar(nuevas.length > 1 ? 'Solicitudes de cita nuevas' : 'Solicitud de cita nueva', nuevas.length > 1 ? `Tienes ${nuevas.length} solicitudes por atender.` : `${s.nombre}${que ? ' · ' + que : ''}`); }
        }
        const tab = $('#t-solicitudes'); if (tab && tab.getAttribute('aria-selected') === 'true' && window.CLPANEL && CLPANEL.cargar['t-solicitudes']) CLPANEL.cargar['t-solicitudes']();
      }
    }
    vistas = ids;
  }
  function iniciar(cliente) {
    C = cliente; clave = 'avisos_' + ((window.DEMO && DEMO.clinica && DEMO.clinica.schema) || 'clinica');
    const salir = $('#s-salir'), barra = salir && salir.parentNode;
    if (barra && salir && !$('#s-avisos')) { const b = document.createElement('button'); b.type = 'button'; b.id = 's-avisos'; b.onclick = alternar; barra.insertBefore(b, salir); barra.insertBefore(document.createTextNode(' '), salir); }
    botonEstado();
    if ('serviceWorker' in navigator && hayNotif()) navigator.serviceWorker.register('sw-avisos.js').then(r => { reg = r; }).catch(() => {});
    revisar(); clearInterval(timer); timer = setInterval(revisar, SEG);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) { revisar(); } });
    window.addEventListener('focus', () => marcar(0));
    $('#t-solicitudes') && $('#t-solicitudes').addEventListener('click', () => marcar(0));
  }
  window.CLAVISOS = { iniciar, revisar, tono, activo };
})();
