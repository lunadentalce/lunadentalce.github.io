/* Motor de cita · agenda por pasos para clínicas: motivo → día → horario → datos → solicitud guardada (solicitar_cita) y WhatsApp.
   No es una carta: el paciente no "agrega" nada, arma una cita. Requiere config.js (window.DEMO) y menu.js (window.MENU);
   si hay base (window.CLINICA) la solicitud se guarda antes de salir por WhatsApp. Uso: Cita.montar('#cita') · Cita.elegir('servicio-3').
   Los días y franjas salen de DEMO.agenda (clinica.semilla.horario); la hora exacta la confirma el equipo. */
(() => {
  const D = window.DEMO, M = window.MENU;
  const CL = D.clinica && window.CLINICA ? window.CLINICA : null;
  const $ = (s, r = document) => r.querySelector(s);
  const esc = t => String(t ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const wa = (n, t) => `https://wa.me/${String(n).replace(/\D/g, '')}?text=${encodeURIComponent(t)}`;
  const TZ = 'America/Guayaquil';
  const AG = Object.assign({ dias: [1, 2, 3, 4, 5, 6], abre: '09:00', cierra: '18:00', pausa: null, visibles: 21 }, D.agenda || {});
  const items = new Map(); M.categorias.forEach(c => c.items.forEach(i => items.set(i.id, i)));
  const hm = t => { const [h, m] = t.split(':').map(Number); return h * 60 + m; };
  const corte = AG.pausa || ['13:00', '14:00'];
  const FRANJAS = [
    { v: 'Mañana', k: 'manana', t: 'Mañana', h: `${AG.abre} a ${corte[0]}`, ini: hm(AG.abre), fin: hm(corte[0]), ico: 'M12 4v2M12 18v2M4 12h2M18 12h2M6.3 6.3l1.4 1.4M16.3 16.3l1.4 1.4M17.7 6.3l-1.4 1.4M7.7 16.3l-1.4 1.4M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z' },
    { v: 'Tarde', k: 'tarde', t: 'Tarde', h: `${corte[1]} a ${AG.cierra}`, ini: hm(corte[1]), fin: hm(AG.cierra), ico: 'M3.5 17.5h17M7 17.5a5 5 0 0 1 10 0M12 6v2.5M5.5 9.5 7.3 11M18.5 9.5 16.7 11' },
    { v: 'Cualquiera', k: 'cualquiera', t: 'Cualquier horario', h: 'Nos adaptamos a tu agenda', ini: 0, fin: 1440, ico: 'M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16zM12 8v4.2l2.8 1.8' }
  ];
  const PARA = [['yo', 'Para mí', 'mí'], ['hijo', 'Para mi hijo o hija', 'mi hijo o hija'], ['otro', 'Para otra persona', 'otra persona']];   // [valor, texto del botón, texto corto para resúmenes y mensaje]
  const PASOS = [[1, '¿Qué necesitas?'], [2, '¿Qué día te queda bien?'], [3, '¿En qué horario?'], [4, 'Tus datos']];

  const SIMPLE = !!AG.simple;   // agenda corta: el motivo ya se eligió arriba (especialidades), así que solo piden día, horario y datos
  const primero = () => [...items.keys()][0];
  const s = { paso: SIMPLE ? 2 : 1, motivo: SIMPLE ? primero() : '', para: 'yo', dia: '', franja: '', nombre: '', telefono: '', representante: '', menor: false, nota: '', consent: false, error: '', salidaWa: false, enviando: false, listo: null };
  let raiz;

  /* ---- fechas (siempre hora de Ecuador) ---- */
  const hoyStr = () => new Date().toLocaleDateString('en-CA', { timeZone: TZ });
  const ahoraMin = () => { const [h, m] = new Date().toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' }).split(':').map(Number); return h * 60 + m; };
  const suma = (iso, k) => { const [y, m, d] = iso.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d + k)); };
  const iso = d => d.toISOString().slice(0, 10);
  const fmt = (d, o) => d.toLocaleDateString('es-EC', Object.assign({ timeZone: 'UTC' }, o));
  const cierto = (dia, f) => dia === hoyStr() && f.fin <= ahoraMin() && f.k !== 'cualquiera';   // franja ya pasada hoy
  const diaAbierto = d => AG.dias.includes(d.getUTCDay() || 7);
  const diaDe = i => suma(hoyStr(), i);
  const hayFranja = dia => FRANJAS.some(f => f.k !== 'cualquiera' && !cierto(dia, f));

  /* ---- validación y avance ---- */
  const menor = () => s.para === 'hijo' || (s.para === 'otro' && s.menor);
  const datosFalta = () => s.nombre.trim().length < 2 ? 'Escribe el nombre y apellido del paciente.'
    : !/^(09\d{8}|593\d{9})$/.test(s.telefono.replace(/[\s-]/g, '')) ? 'Escribe un celular válido, por ejemplo 0991234567.'
    : menor() && s.representante.trim().length < 2 ? 'Escribe el nombre de quien autoriza al menor de edad.'
    : !s.consent ? 'Para enviar tu solicitud, acepta el tratamiento de tus datos.' : '';
  const completo = n => n === 1 ? !!s.motivo : n === 2 ? !!s.dia : n === 3 ? !!s.franja : !datosFalta();
  const primerPendiente = () => { for (let n = 1; n <= 4; n++) if (!completo(n)) return n; return 4; };
  const alcanzable = n => n <= primerPendiente();

  /* ---- vistas ---- */
  const check = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m5 12.5 4.5 4.5L19 7.5"/></svg>';
  const resumen = n => n === 1 ? (s.motivo ? esc(items.get(s.motivo).nombre) + ' · para ' + esc(PARA.find(p => p[0] === s.para)[2]) : '')
    : n === 2 ? (s.dia ? esc(fmt(new Date(s.dia + 'T12:00:00Z'), { weekday: 'long', day: 'numeric', month: 'long' })) : '')
    : n === 3 ? (s.franja ? esc(FRANJAS.find(f => f.v === s.franja).t) : '')
    : (completo(4) ? esc(s.nombre) : '');

  const cuerpo1 = () => `<div class="ct-motivos" role="group" aria-label="Motivo de la cita">${[...items.values()].map((i, n) => `
      <button type="button" class="ct-op${s.motivo === i.id ? ' on' : ''}${n === 0 ? ' ct-op-primera' : ''}" data-motivo="${esc(i.id)}" aria-pressed="${s.motivo === i.id}">
        <span class="ct-op-ico"><svg><use href="#${esc(i.icono || 'i-diente')}"/></svg></span>
        <span class="ct-op-txt"><b>${esc(i.nombre)}</b>${i.corto ? `<small>${esc(i.corto)}</small>` : ''}</span>
        <span class="ct-op-ok" aria-hidden="true">${check}</span>
      </button>`).join('')}</div>
    <fieldset class="ct-para"><legend>¿Para quién es la cita?</legend>${PARA.map(([v, t]) => `
      <label><input type="radio" name="ct-para" value="${v}" ${s.para === v ? 'checked' : ''}><span>${t}</span></label>`).join('')}</fieldset>`;

  const cuerpo2 = () => {
    const dias = Array.from({ length: AG.visibles }, (_, i) => diaDe(i));
    return `<div class="ct-dias" role="group" aria-label="Días">${dias.map((d, i) => {
      const v = iso(d), abierto = diaAbierto(d) && hayFranja(v);
      return `<button type="button" class="ct-dia${s.dia === v ? ' on' : ''}" data-dia="${v}" aria-pressed="${s.dia === v}" ${abierto ? '' : 'disabled'} aria-label="${esc(fmt(d, { weekday: 'long', day: 'numeric', month: 'long' }))}${abierto ? '' : ', sin atención'}">
        <small>${i === 0 ? 'Hoy' : esc(fmt(d, { weekday: 'short' }).replace('.', ''))}</small><b>${d.getUTCDate()}</b><em>${abierto ? esc(fmt(d, { month: 'short' }).replace('.', '')) : 'Cerrado'}</em></button>`;
    }).join('')}</div>
    <p class="ct-pista">Atendemos ${esc(D.agenda && D.agenda.texto_dias ? D.agenda.texto_dias : 'de lunes a sábado')}. Desliza para ver más días.</p>`;
  };

  const cuerpo3 = () => `<div class="ct-franjas" role="group" aria-label="Horario preferido">${FRANJAS.map(f => {
    const off = cierto(s.dia, f);
    return `<button type="button" class="ct-franja${s.franja === f.v ? ' on' : ''}" data-franja="${f.v}" aria-pressed="${s.franja === f.v}" ${off ? 'disabled' : ''}>
      <span class="ct-franja-ico"><svg viewBox="0 0 24 24"><path d="${f.ico}"/></svg></span><b>${f.t}</b><small>${off ? 'Ya pasó por hoy' : f.h}</small></button>`;
  }).join('')}</div>
    <p class="ct-pista">Es el horario que prefieres: el equipo te confirma la hora exacta por WhatsApp.</p>`;

  const campo = (id, et, extra = '') => `<label class="ct-campo"><span>${et}</span><input id="ct-${id}" value="${esc(s[id])}" ${extra}></label>`;
  const paraHtml = () => `<fieldset class="ct-para"><legend>¿Para quién es la cita?</legend>${PARA.map(([v, t]) => `
      <label><input type="radio" name="ct-para" value="${v}" ${s.para === v ? 'checked' : ''}><span>${t}</span></label>`).join('')}</fieldset>`;
  const motivoSel = () => `<label class="ct-motivo-sel"><span>Tu cita es para</span><select id="ct-motivo">${[...items.values()].map(i => `<option value="${esc(i.id)}"${s.motivo === i.id ? ' selected' : ''}>${esc(i.nombre)}</option>`).join('')}</select></label>`;
  const cuerpo4 = () => `<div class="ct-form">
      ${SIMPLE ? paraHtml() : ''}
      ${campo('nombre', 'Nombre y apellido del paciente', 'autocomplete="name" maxlength="80" required')}
      ${campo('telefono', 'Tu celular (para confirmar la cita)', 'type="tel" inputmode="tel" autocomplete="tel" placeholder="09xxxxxxxx" maxlength="14" required')}
      ${s.para === 'otro' ? `<label class="ct-chk"><input type="checkbox" id="ct-menor" ${s.menor ? 'checked' : ''}><span>El paciente es menor de edad</span></label>` : ''}
      ${menor() ? campo('representante', 'Nombre de quien autoriza (madre, padre o representante)', 'autocomplete="off" maxlength="80" required') : ''}
      ${campo('nota', 'Nota (opcional)', 'maxlength="140" placeholder="Algo que debamos saber"')}
      <label class="ct-chk"><input type="checkbox" id="ct-consent" ${s.consent ? 'checked' : ''}><span>${esc((D.clinica && D.clinica.consentimiento) || 'Acepto que se usen mis datos para gestionar mi cita.')} <a href="${esc((D.clinica && D.clinica.privacidad) || 'privacidad.html')}" target="_blank" rel="noopener">Política de privacidad</a></span></label>
      <p class="ct-error" id="ct-error" role="alert">${esc(s.error)}</p>
      ${s.salidaWa ? `<a class="btn btn-linea" id="ct-solo-wa" href="${esc(wa(D.waCliente, mensaje()))}" target="_blank" rel="noopener">Escribirnos por WhatsApp sin guardar</a>` : ''}
      <button type="button" class="btn ct-enviar" id="ct-enviar" ${s.enviando ? 'disabled' : ''}>${s.enviando ? 'Enviando…' : 'Enviar solicitud de cita'}</button>
    </div>`;

  const paso = (n, t) => {
    if (SIMPLE && n === 1) return '';
    const num = SIMPLE ? n - 1 : n, on = s.paso === n, ok = completo(n) && !on, bloq = !alcanzable(n);
    return `<section class="ct-paso${on ? ' on' : ''}${ok ? ' ok' : ''}" data-n="${n}">
      <h3><button type="button" class="ct-cab" data-ir="${n}" aria-expanded="${on}" aria-controls="ct-c${n}" ${bloq ? 'disabled' : ''}>
        <span class="ct-num">${ok ? check : num}</span><span class="ct-tit">${t}<small>${resumen(n)}</small></span><span class="ct-cambiar">Cambiar</span></button></h3>
      <div class="ct-cuerpo" id="ct-c${n}" ${on ? '' : 'hidden'}>${on ? [cuerpo1, cuerpo2, cuerpo3, cuerpo4][n - 1]() : ''}</div></section>`;
  };

  const fila = (a, b) => `<div class="${b ? '' : 'vacio'}"><dt>${a}</dt><dd>${b ? esc(b) : 'Por elegir'}</dd></div>`;
  const ticket = () => {
    const it = s.motivo && items.get(s.motivo);
    return `<aside class="ct-ticket" aria-label="Resumen de tu cita">
      <div class="ct-t-cab"><img src="${esc(D.logo || 'assets/logo-provisional.svg')}" alt="" width="44" height="44"><div><b>${esc(D.corto || D.cliente)}</b><small>${esc(D.agenda && D.agenda.sub ? D.agenda.sub : 'Tu cita')}</small></div></div>
      <h3>Tu cita</h3>
      <dl>${fila('Motivo', it && it.nombre)}${fila('Para', s.motivo && PARA.find(p => p[0] === s.para)[2])}${fila('Día', s.dia && fmt(new Date(s.dia + 'T12:00:00Z'), { weekday: 'long', day: 'numeric', month: 'long' }))}${fila('Horario', s.franja && FRANJAS.find(f => f.v === s.franja).t)}${fila('Paciente', completo(4) && s.nombre)}</dl>
      <div class="ct-avance" aria-hidden="true">${[1, 2, 3, 4].map(n => `<i class="${completo(n) ? 'on' : ''}"></i>`).join('')}</div>
      <p class="ct-t-nota">Pides tu cita aquí y el equipo te escribe por WhatsApp para confirmar la hora exacta. No se paga nada por pedirla.</p>
      <button type="button" class="btn ct-t-btn" id="ct-t-btn">${completo(4) ? 'Enviar solicitud' : 'Siguiente: paso ' + primerPendiente()}</button>
    </aside>`;
  };

  const listoHtml = r => `<div class="ct-listo" role="status">
      <span class="fx-check ct-check" aria-hidden="true"><i></i><i></i></span>
      <h3>Recibimos tu solicitud</h3>
      <p>${r.ref ? `Solicitud N.º ${esc(r.ref)}. ` : ''}Para confirmarla, envía el mensaje por WhatsApp: ${esc(D.corto || D.cliente)} te responde con el día y la hora exactos.</p>
      <ul class="ct-listo-res"><li>${esc(r.motivo)}</li><li>${esc(r.dia)}</li><li>${esc(r.franja)}</li></ul>
      <a class="btn" id="ct-wa" href="${esc(wa(D.waCliente, r.mensaje))}" target="_blank" rel="noopener">Enviar por WhatsApp</a>
      <button type="button" class="btn btn-linea" id="ct-otra">Pedir otra cita</button>
    </div>`;

  function pintar() {
    if (!raiz) return;
    const tira = $('.ct-dias', raiz), x = tira ? tira.scrollLeft : 0;
    const activo = document.activeElement && document.activeElement.id;
    raiz.innerHTML = s.listo ? `<div class="ct-wrap ct-solo">${listoHtml(s.listo)}</div>`
      : `<div class="ct-wrap${SIMPLE ? ' ct-simple' : ''}"><div class="ct-pasos">${SIMPLE ? motivoSel() : ''}${PASOS.map(([n, t]) => paso(n, t)).join('')}</div>${SIMPLE ? '' : ticket()}</div>`;
    const t2 = $('.ct-dias', raiz); if (t2) { t2.scrollLeft = x; if (!x && s.dia) { const on = $('.ct-dia.on', t2); on && t2.scrollTo({ left: on.offsetLeft - 16 }); } }
    if (activo && /^ct-(nombre|telefono|representante|nota)$/.test(activo)) { const el = document.getElementById(activo); if (el) { el.focus(); const l = el.value.length; try { el.setSelectionRange(l, l); } catch (e) { /* tipo sin selección */ } } }
  }

  function avanzar() { s.paso = primerPendiente(); s.error = ''; pintar(); const c = $(`.ct-paso[data-n="${s.paso}"]`, raiz); if (c && c.getBoundingClientRect().top < 0) c.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }); }

  function mensaje() {
    const it = items.get(s.motivo), f = FRANJAS.find(x => x.v === s.franja);
    return [D.saludoPedido || `Hola ${D.cliente}, quiero reservar desde la web`, '', `Motivo: ${it.nombre}`,
      `Para: ${PARA.find(p => p[0] === s.para)[2]}`, `Paciente: ${s.nombre.trim()}`, menor() ? `Autoriza: ${s.representante.trim()}` : null, `Celular: ${s.telefono.trim()}`,
      `Día preferido: ${fmt(new Date(s.dia + 'T12:00:00Z'), { weekday: 'long', day: 'numeric', month: 'long' })}`, `Horario preferido: ${f.t}`,
      s.nota.trim() ? `Nota: ${s.nota.trim()}` : null, s.ref ? `Solicitud N.º ${s.ref}` : null].filter(x => x !== null).join('\n');
  }

  async function enviar() {
    const falta = !s.motivo ? 'Elige qué necesitas.' : !s.dia ? 'Elige un día.' : !s.franja ? 'Elige un horario.' : datosFalta();
    if (falta) { s.error = falta; s.paso = primerPendiente(); pintar(); const e = $('#ct-error'); e && e.scrollIntoView({ block: 'center' }); return; }
    s.error = ''; s.salidaWa = false; s.enviando = true; s.ref = null; pintar();
    let ref = null, aviso = '';
    if (CL) {
      try {
        const r = await CL.solicitar({ nombre: s.nombre.trim(), telefono: s.telefono.replace(/[\s-]/g, ''), servicios: [items.get(s.motivo).nombre], dia: s.dia, franja: FRANJAS.find(f => f.v === s.franja).k, menor: menor(), representante: menor() ? s.representante.trim() : '', consentimiento: s.consent });
        ref = r && r.ref; window.track && window.track('solicitud_enviada');
      } catch (e) { s.enviando = false; s.error = e.message || 'No pudimos guardar tu solicitud. Escríbenos por WhatsApp.'; s.salidaWa = true; s.paso = 4; pintar(); return; }   // si el servidor rechaza, queda la salida por WhatsApp sin guardar
    } else aviso = 'sin guardar';
    s.ref = ref; s.enviando = false;
    const m = mensaje(), f = FRANJAS.find(x => x.v === s.franja);
    window.open(wa(D.waCliente, m), '_blank', 'noopener');
    s.listo = { ref, mensaje: m, aviso, motivo: items.get(s.motivo).nombre, dia: fmt(new Date(s.dia + 'T12:00:00Z'), { weekday: 'long', day: 'numeric', month: 'long' }), franja: f.t };
    pintar(); raiz.scrollIntoView({ block: 'nearest' });
  }

  function montar(sel) {
    raiz = $(sel);
    raiz.addEventListener('click', e => {
      const t = e.target;
      let b;
      if ((b = t.closest('[data-motivo]'))) { s.motivo = b.dataset.motivo; return avanzar(); }
      if ((b = t.closest('[data-dia]'))) { s.dia = b.dataset.dia; if (s.franja && cierto(s.dia, FRANJAS.find(f => f.v === s.franja))) s.franja = ''; return avanzar(); }
      if ((b = t.closest('[data-franja]'))) { s.franja = b.dataset.franja; return avanzar(); }
      if ((b = t.closest('[data-ir]'))) { s.paso = +b.dataset.ir; s.error = ''; return pintar(); }
      if (t.closest('#ct-enviar')) return enviar();
      if (t.closest('#ct-t-btn')) { if (completo(4)) return enviar(); s.paso = primerPendiente(); pintar(); const c = $(`.ct-paso[data-n="${s.paso}"]`, raiz); c && c.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); return; }
      if (t.closest('#ct-wa')) { window.track && window.track('whatsapp_click', { lugar: 'agenda' }); return; }
      if (t.closest('#ct-otra')) { Object.assign(s, { paso: SIMPLE ? 2 : 1, motivo: SIMPLE ? primero() : '', para: 'yo', dia: '', franja: '', nombre: '', telefono: '', representante: '', menor: false, nota: '', consent: false, error: '', salidaWa: false, listo: null, ref: null }); pintar(); }
    });
    raiz.addEventListener('input', e => { const i = e.target; if (i.id && /^ct-(nombre|telefono|representante|nota)$/.test(i.id)) { s[i.id.slice(3)] = i.value; if (s.error) { s.error = ''; const er = $('#ct-error', raiz); if (er) er.textContent = ''; } const tb = $('#ct-t-btn', raiz); if (tb) tb.textContent = completo(4) ? 'Enviar solicitud' : 'Siguiente: paso ' + primerPendiente(); } });
    raiz.addEventListener('change', e => {
      const i = e.target;
      if (i.id === 'ct-motivo') { s.motivo = i.value; return; }
      if (i.name === 'ct-para') { s.para = i.value; if (s.para !== 'otro') s.menor = false; if (s.para !== 'hijo' && s.para !== 'otro') s.representante = ''; return pintar(); }
      if (i.id === 'ct-consent') { s.consent = i.checked; const tb = $('#ct-t-btn', raiz); if (tb) tb.textContent = completo(4) ? 'Enviar solicitud' : 'Siguiente: paso ' + primerPendiente(); }
      if (i.id === 'ct-menor') { s.menor = i.checked; if (!s.menor) s.representante = ''; pintar(); }
    });
    document.addEventListener('click', e => { const a = e.target.closest('[data-cita]'); if (a) elegir(a.dataset.cita, false); });
    pintar();
  }

  /* Preselecciona el motivo (desde las especialidades o el diagnóstico). Si el enlace ya navega a #agenda no hace falta mover la página. */
  function elegir(id, mover = true) {
    if (!items.has(id)) return;
    s.listo = null; s.motivo = id; s.paso = primerPendiente(); s.error = ''; pintar();
    if (mover) { const a = raiz.closest('section') || raiz; a.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }); }
  }

  window.Cita = { montar, elegir, items, esc };
})();
