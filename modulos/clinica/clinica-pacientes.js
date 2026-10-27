/* clinica-pacientes.js · ficha del paciente: datos, historial de citas, cobros y presupuestos y, para administración y doctores, la parte clínica
   (antecedentes, odontograma, evolución). Lo clínico lo devuelve la base SOLO a esos roles; aquí además se esconden las pestañas para los demás.
   Cada nota clínica es de solo agregar: se corrige con una nota nueva. Todo lo que viene de la base pasa por esc() antes de pintarse. */
(() => {
  const { esc, $, $$, usd, hoy, fechaCorta, tel09, wa, aviso, msgErr } = CLUI, C = CLINICA, P = window.CLPANEL;
  const falla = (id, e) => { const el = $(id); if (el) el.textContent = msgErr(e); aviso(msgErr(e), 'mal'); };
  const CITA = { pendiente: 'Por confirmar', confirmada: 'Confirmada', atendida: 'Atendida', no_vino: 'No vino', cancelada: 'Cancelada' };
  const PRES = { enviado: ['En espera', 'esp'], aceptado: ['Aceptado', 'ok'], rechazado: ['Rechazado', 'mal'] };
  let F = null, sub = 'datos', timer = null, corrigiendo = null, ODO = null, ODOid = null, odoSup = true, odoUI = null;   // ODO: marcas vigentes del odontograma del paciente abierto
  const rol = () => (P.yo() || {}).rol;
  const edad = n => { if (!n) return null; const h = hoy(), a = +h.slice(0, 4) - +n.slice(0, 4); return h.slice(5) < n.slice(5) ? a - 1 : a; };
  const consiente = () => { const c = (F.consentimientos || []).find(x => x.tipo === 'tratamiento'); return !!(c && c.otorgado); };
  const campo = (id, et, val, extra) => `<div class="campo"><label for="${id}">${et}</label><input id="${id}" value="${esc(val || '')}" ${extra || ''}></div>`;
  const area = (id, et, val) => `<div class="campo" style="grid-column:1/-1"><label for="${id}">${et}</label><textarea id="${id}" rows="2" maxlength="1000" style="width:100%;padding:10px 12px;border-radius:12px;border:1.5px solid color-mix(in srgb,var(--fx-ink) 22%,transparent);font:400 1rem var(--fx-font-txt);background:#fff">${esc(val || '')}</textarea></div>`;

  /* ---------- lista y búsqueda ---------- */
  async function buscar() {
    const cont = $('#pa-lista');
    try {
      const l = await C.rpc('pacientes_buscar', { p_q: $('#pa-q').value });
      cont.innerHTML = l.length ? l.map(p => `<button type="button" class="sol" data-p="${p.id}" style="text-align:left;cursor:pointer"><h3>${esc(p.nombre)}</h3>
        <div class="meta"><span>📱 ${esc(tel09(p.telefono))}</span>${p.cedula ? `<span>CI ${esc(p.cedula)}</span>` : ''}<span>${p.citas} ${p.citas === 1 ? 'cita' : 'citas'}</span>${p.ultima ? `<span>Última: ${esc(fechaCorta(p.ultima))}</span>` : ''}${p.proxima ? `<span class="pill ok">Próxima: ${esc(fechaCorta(p.proxima))}</span>` : ''}</div></button>`).join('') : '<p class="vacio">No encontramos pacientes con eso.</p>';
      $$('[data-p]', cont).forEach(b => b.onclick = () => abrir(+b.dataset.p));
    } catch (e) { cont.innerHTML = `<p class="vacio">${esc(msgErr(e))}</p>`; }
  }
  $('#pa-q').oninput = () => { clearTimeout(timer); timer = setTimeout(buscar, 300); };
  $('#pa-nuevo').onclick = () => { F = { id: null, nombre: '', telefono: '', datos: {}, citas: [], cobros: [], presupuestos: [], consentimientos: [], acceso_clinico: false }; sub = 'datos'; mostrar(); };

  async function abrir(id, seccion) {
    try { F = await C.rpc('paciente_ficha', { p_id: id }); ODO = null; if (seccion) sub = seccion; else if (!F || sub === 'nuevo') sub = 'datos'; mostrar(); }
    catch (e) { aviso(msgErr(e), 'mal'); }
  }
  function volver() { F = null; $('#pa-ficha').hidden = true; $('#pa-buscar').hidden = false; buscar(); }

  /* ---------- ficha ---------- */
  function mostrar() {
    $('#pa-buscar').hidden = true; const f = $('#pa-ficha'); f.hidden = false;
    const nuevo = F.id == null, e = edad((F.datos || {}).nacimiento), clin = F.acceso_clinico;
    const tabs = nuevo ? [['datos', 'Datos']] : [['datos', 'Datos'], ['citas', `Citas (${F.citas.length})`], ['cobros', 'Cobros y presupuestos'], ...(clin ? [['clinico', 'Historia clínica'], ['odo', 'Odontograma'], ['evo', `Evolución (${(F.evoluciones || []).length})`]] : []), ...(rol() === 'admin' ? [['accesos', 'Accesos']] : [])];
    if (!tabs.some(t => t[0] === sub)) sub = 'datos';
    f.innerHTML = `<div class="no-print" style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:10px"><button type="button" class="cb" id="fi-volver">← Pacientes</button>${nuevo ? '' : `<button type="button" class="cb" id="fi-print">Imprimir ficha</button>`}</div>
      <h2 style="margin-bottom:2px">${nuevo ? 'Nuevo paciente' : esc(F.nombre)}</h2>
      ${nuevo ? '' : `<p class="sub" style="margin-bottom:10px">${e != null ? `${e} años · ` : ''}📱 ${esc(tel09(F.telefono))} · <a href="${wa(F.telefono, `Hola ${F.nombre.split(' ')[0]}, te escribimos de ${DEMO.cliente}.`)}" target="_blank" rel="noopener">WhatsApp</a> · paciente desde ${esc(fechaCorta(F.creado))}</p>`}
      ${!nuevo && !clin ? '<p class="nota-d" style="margin:0 0 10px">La parte clínica (historia, odontograma, evolución) la ven los doctores y la administración.</p>' : ''}
      <div class="ctrl no-print" role="tablist" aria-label="Secciones de la ficha">${tabs.map(([k, t]) => `<button type="button" class="cb" role="tab" data-sub="${k}" aria-pressed="${k === sub}">${esc(t)}</button>`).join('')}</div>
      <div id="fi-cuerpo"></div>`;
    $('#fi-volver').onclick = volver; const pr = $('#fi-print'); if (pr) pr.onclick = () => { document.body.classList.add('print-ficha'); window.print(); setTimeout(() => document.body.classList.remove('print-ficha'), 500); };
    $$('[data-sub]', f).forEach(b => b.onclick = () => { sub = b.dataset.sub; mostrar(); });
    ({ datos: pDatos, citas: pCitas, cobros: pCobros, clinico: pClinico, odo: pOdo, evo: pEvo, accesos: pAccesos })[sub]();
  }

  /* ---- datos + consentimientos ---- */
  function pDatos() {
    const d = F.datos || {}, nuevo = F.id == null, cons = F.consentimientos || [];
    const estado = t => { const c = cons.find(x => x.tipo === t); return c ? (c.otorgado ? `<span class="pill ok">Otorgado por ${esc(c.quien)} · ${esc(fechaCorta(c.dia))}</span>` : `<span class="pill mal">Retirado · ${esc(fechaCorta(c.dia))}</span>`) : '<span class="pill esp">Pendiente</span>'; };
    $('#fi-cuerpo').innerHTML = `<form class="fila" id="fi-datos" autocomplete="off">
        ${campo('d-nombre', 'Nombre y apellido', F.nombre, 'maxlength="80" required')}${campo('d-tel', 'Celular', F.telefono ? tel09(F.telefono) : '', 'type="tel" inputmode="tel" maxlength="14" required')}${campo('d-ced', 'Cédula', d.cedula, 'maxlength="20"')}
        ${campo('d-nac', 'Fecha de nacimiento', d.nacimiento, `type="date" max="${hoy()}"`)}${campo('d-mail', 'Correo', d.email, 'type="email" maxlength="80"')}${campo('d-dir', 'Dirección', d.direccion, 'maxlength="200"')}
        ${campo('d-cn', 'Contacto de emergencia', d.contacto_nombre, 'maxlength="80"')}${campo('d-ct', 'Teléfono del contacto', d.contacto_tel, 'type="tel" maxlength="20"')}${campo('d-rep', 'Representante (si es menor de edad)', d.representante, 'maxlength="80"')}
        <button class="btn" type="submit">${nuevo ? 'Crear paciente' : 'Guardar datos'}</button></form><p class="err-f" id="fi-err" role="alert"></p>
      ${nuevo ? '' : `<h3 style="font:800 1.05rem var(--fx-font-disp);margin:18px 0 8px">Consentimientos</h3>
        <div class="tarjetas"><div class="sol"><div class="meta"><b>Tratamiento y atención</b> ${estado('tratamiento')}</div><div class="meta"><b>Uso de datos</b> ${estado('datos')}</div><div class="meta"><b>Fotos e imágenes</b> ${estado('imagenes')}</div>
          <form class="agendar" id="fi-cons" autocomplete="off"><div class="campo"><label for="c-tipo2">Consentimiento</label><select id="c-tipo2"><option value="tratamiento">Tratamiento y atención</option><option value="datos">Uso de datos</option><option value="imagenes">Fotos e imágenes</option></select></div>
            <div class="campo"><label for="c-quien">Quién lo da (paciente o representante)</label><input id="c-quien" maxlength="80" required value="${esc(d.representante || F.nombre)}"></div>
            <button class="btn" type="submit" value="1">Registrar</button><button class="btn btn-linea" type="button" id="c-retirar">Retirar</button></form>
          <div class="acciones no-print"><button type="button" class="btn btn-linea" id="c-imprimir">Imprimir consentimiento para firmar</button></div>
          <p class="nota-d" style="margin:0">El paciente (o su representante) lo firma en el consultorio. Cuando esté firmado, regístralo aquí arriba.</p></div></div>`}`;
    $('#fi-datos').onsubmit = async e => { e.preventDefault(); $('#fi-err').textContent = '';
      try { const r = await C.rpc('paciente_guardar', { p_id: F.id, p_nombre: $('#d-nombre').value, p_telefono: $('#d-tel').value.replace(/[\s-]/g, ''), p_cedula: $('#d-ced').value, p_nacimiento: $('#d-nac').value || null, p_email: $('#d-mail').value, p_direccion: $('#d-dir').value, p_contacto_nombre: $('#d-cn').value, p_contacto_tel: $('#d-ct').value, p_representante: $('#d-rep').value });
        aviso(nuevo ? 'Paciente creado.' : 'Datos guardados.'); abrir(r.id, 'datos'); } catch (x) { falla('#fi-err', x); } };
    if (!nuevo) {
      const reg = async otorgado => { try { await C.rpc('consentimiento_registrar', { p_id: F.id, p_tipo: $('#c-tipo2').value, p_otorgado: otorgado, p_quien: $('#c-quien').value }); aviso(otorgado ? 'Consentimiento registrado.' : 'Consentimiento retirado.'); abrir(F.id, 'datos'); } catch (x) { aviso(msgErr(x), 'mal'); } };
      $('#c-imprimir').onclick = imprimirConsentimiento;
      $('#fi-cons').onsubmit = e => { e.preventDefault(); reg(true); }; $('#c-retirar').onclick = () => { if (confirm('¿Registrar que el paciente retiró este consentimiento? No se podrá escribir en lo clínico hasta que lo dé de nuevo.')) reg(false); };
    }
  }

  /* ---- consentimiento imprimible: el texto sale de config.js (cliente.json → clinica.consentimiento_doc) y lo revisa un asesor legal ---- */
  function imprimirConsentimiento() {
    const K = (DEMO.clinica || {}).consentimientoDoc;
    if (!K) { aviso('Falta el texto del consentimiento en la configuración.', 'mal'); return; }
    const d = F.datos || {}, menor = !!d.representante, rep = d.representante ? esc(d.representante) : '';
    const sub = t => String(t).replace(/\{clinica\}/g, esc(DEMO.cliente)).replace(/\{responsable\}/g, esc(K.responsable)).replace(/\{contacto\}/g, esc(K.contacto)).replace(/\{conservacion\}/g, esc(K.conservacion));
    const fecha = new Date().toLocaleDateString('es-EC', { day: 'numeric', month: 'long', year: 'numeric', timeZone: CLUI.TZ });
    const linea = (txt, nota) => `<div class="firma"><div class="raya"></div><b>${txt}</b>${nota ? `<span>${nota}</span>` : ''}</div>`;
    const w = window.open('', '_blank'); if (!w) { aviso('Permite las ventanas emergentes para imprimir el consentimiento.', 'mal'); return; }
    w.document.write(`<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Consentimiento · ${esc(F.nombre)}</title><style>
      body { font: 12pt/1.45 "Helvetica Neue", Arial, sans-serif; color: #111; max-width: 760px; margin: 0 auto; padding: 28px 22px; }
      h1 { font-size: 15pt; margin: 4px 0 2px; } .clin { font-size: 10pt; letter-spacing: .06em; text-transform: uppercase; color: #555; }
      h2 { font-size: 11.5pt; margin: 16px 0 3px; } p { margin: 0 0 6px; text-align: justify; } .datos { border: 1px solid #999; padding: 10px 12px; margin: 12px 0; font-size: 11pt; }
      .caja { display: inline-block; width: 11px; height: 11px; border: 1.3px solid #111; margin-right: 8px; vertical-align: -1px; }
      .firmas { display: grid; grid-template-columns: 1fr 1fr; gap: 36px; margin-top: 54px; } .raya { border-top: 1px solid #111; margin-bottom: 4px; } .firma b { display: block; font-size: 10.5pt; } .firma span { font-size: 9.5pt; color: #444; }
      .aviso { background: #fff3c4; border: 1px solid #d9b25f; padding: 8px 12px; margin-bottom: 14px; font-size: 10pt; } button { font: inherit; padding: 8px 16px; margin: 0 8px 12px 0; }
      @media print { .aviso, button { display: none; } body { padding: 0; } } @page { size: A4; margin: 18mm; }</style></head><body>
      <div class="aviso">Borrador: un asesor legal debe revisar este texto antes de usarlo con pacientes. Esta franja no sale al imprimir.</div>
      <button onclick="window.print()">Imprimir</button>
      <div class="clin">${esc(DEMO.cliente)}</div><h1>${esc(K.titulo)}</h1>
      <div class="datos"><b>Paciente:</b> ${esc(F.nombre)}${d.cedula ? ` · <b>Cédula:</b> ${esc(d.cedula)}` : ''}${d.nacimiento ? ` · <b>Nacimiento:</b> ${esc(d.nacimiento)}` : ''}<br><b>Celular:</b> ${esc(tel09(F.telefono))}${menor ? `<br><b>Representante legal:</b> ${rep}` : ''}</div>
      <p>${menor ? `Yo, ${rep}, representante legal del paciente indicado,` : `Yo, ${esc(F.nombre)},`} declaro lo siguiente:</p>
      ${K.secciones.map(x => `<h2>${esc(x.t)}</h2><p>${sub(esc(x.p))}</p>`).join('')}
      <h2>Fotografías (marca lo que autorizas)</h2><p><span class="caja"></span>${esc(K.imagenes)}</p><p><span class="caja"></span>${esc(K.imagenes_difusion)}</p>
      <p style="margin-top:14px">He leído este documento, lo entiendo y firmo en señal de conformidad. Fecha: ${esc(fecha)}. Lugar: ____________________</p>
      <div class="firmas">${linea(menor ? 'Firma del representante legal' : 'Firma del paciente', `Nombre: ${menor ? rep : esc(F.nombre)} · C.I.: ______________`)}${linea('Firma del odontólogo o la odontóloga', 'Nombre y registro: ______________________')}</div></body></html>`);
    w.document.close(); w.focus();
  }

  /* ---- citas ---- */
  function pCitas() {
    $('#fi-cuerpo').innerHTML = `<div class="acciones no-print" style="margin-bottom:10px"><button type="button" class="btn" id="fi-nc">+ Nueva cita para este paciente</button></div>
      <div style="overflow-x:auto"><table class="tabla"><thead><tr><th>Fecha</th><th>Hora</th><th>Tratamiento</th><th>Doctor</th><th>Estado</th></tr></thead><tbody>${F.citas.map(c => `<tr><td>${esc(fechaCorta(c.dia))}</td><td>${esc(c.hora)}</td><td>${esc(c.servicio)}</td><td>${esc(c.doctor || '—')}</td><td><span class="pill ${c.estado === 'atendida' ? 'ok' : c.estado === 'no_vino' || c.estado === 'cancelada' ? 'mal' : 'esp'}">${esc(CITA[c.estado] || c.estado)}</span></td></tr>`).join('') || '<tr><td colspan="5">Todavía no tiene citas.</td></tr>'}</tbody></table></div>`;
    $('#fi-nc').onclick = () => P.nuevaCita(F);
  }

  /* ---- cobros y presupuestos ---- */
  function pCobros() {
    const tot = F.cobros.filter(m => !m.anulado && m.tipo === 'ing').reduce((q, m) => q + +m.importe, 0);
    $('#fi-cuerpo').innerHTML = `<h3 style="font:800 1.05rem var(--fx-font-disp);margin-bottom:8px">Cobros · total pagado ${usd(tot)}</h3>
      <form class="fila no-print" id="fi-cobro" autocomplete="off"><div class="campo"><label for="k-desc">Descripción</label><input id="k-desc" maxlength="80" required placeholder="ej.: Resina pieza 16"></div><div class="campo"><label for="k-imp">Importe</label><input id="k-imp" type="number" step="0.01" min="0.01" required></div>
        <div class="campo"><label for="k-doc">Doctor</label><select id="k-doc"><option value="">Sin doctor</option>${P.docs().filter(d => d.activo).map(d => `<option value="${d.id}">${esc(d.nombre)}</option>`).join('')}</select></div><button class="btn" type="submit">Registrar cobro</button></form><p class="err-f" id="fi-err" role="alert"></p>
      <div style="overflow-x:auto"><table class="tabla"><thead><tr><th>Fecha</th><th>Descripción</th><th class="n">Importe</th></tr></thead><tbody>${F.cobros.map(m => `<tr class="${m.anulado ? 'anulado' : ''}"><td>${esc(fechaCorta(m.dia))}</td><td>${esc(m.descripcion)}${m.anulado ? ' (anulado)' : ''}</td><td class="n ${m.tipo}">${m.tipo === 'egr' ? '−' : '+'}${usd(m.importe)}</td></tr>`).join('') || '<tr><td colspan="3">Sin cobros todavía.</td></tr>'}</tbody></table></div>
      <h3 style="font:800 1.05rem var(--fx-font-disp);margin:20px 0 8px">Presupuestos</h3>${P.puedePres() ? '<div class="acciones no-print" style="margin-bottom:8px"><button type="button" class="btn" id="fi-np">+ Nuevo presupuesto para este paciente</button></div>' : ''}
      <div class="tarjetas">${F.presupuestos.map(p => `<article class="sol"><h3>${usd(p.total)} · ${esc(fechaCorta(p.dia))}</h3><div class="meta"><span class="pill ${PRES[p.estado][1]}">${PRES[p.estado][0]}</span>${p.descuento ? `<span>desc. ${p.descuento} %</span>` : ''}</div><div class="meta">${(p.items || []).map(i => `${i.cant} × ${esc(i.descripcion)}`).join(' · ')}</div></article>`).join('') || '<p class="vacio">Sin presupuestos todavía.</p>'}</div>`;
    $('#fi-cobro').onsubmit = async e => { e.preventDefault(); $('#fi-err').textContent = '';
      try { await C.rpc('caja_registrar', { p_descripcion: $('#k-desc').value, p_importe: parseFloat($('#k-imp').value), p_tipo: 'ing', p_doctor: $('#k-doc').value ? +$('#k-doc').value : null, p_clienta: F.id }); aviso('Cobro registrado.'); abrir(F.id, 'cobros'); } catch (x) { falla('#fi-err', x); } };
    if ($('#fi-np')) $('#fi-np').onclick = () => P.presupuestoPara(F);
  }

  /* ---- historia clínica ---- */
  function bannerConsent() { return consiente() ? '' : `<p class="aviso-clin">Antes de escribir en la parte clínica, registra el consentimiento de tratamiento del paciente (pestaña Datos).</p>`; }
  function pClinico() {
    const c = F.clinico || {};
    $('#fi-cuerpo').innerHTML = `${bannerConsent()}<form class="fila" id="fi-clin" autocomplete="off">${area('h-ale', 'Alergias', c.alergias)}${area('h-med', 'Medicamentos que toma', c.medicamentos)}${area('h-ant', 'Antecedentes médicos (enfermedades, cirugías, embarazo…)', c.antecedentes_medicos)}
      ${area('h-odo', 'Antecedentes odontológicos', c.antecedentes_odonto)}${area('h-hab', 'Hábitos (fuma, bruxismo, higiene…)', c.habitos)}${area('h-obs', 'Observaciones', c.observaciones)}
      <button class="btn" type="submit" ${consiente() ? '' : 'disabled'}>Guardar historia clínica</button></form><p class="err-f" id="fi-err" role="alert"></p>
      <p class="nota-d">${c.actualizado ? `Última actualización: ${esc(c.actualizado)}. ` : 'Todavía no hay historia clínica registrada. '}Cada guardado conserva la versión anterior.</p>`;
    $('#fi-clin').onsubmit = async e => { e.preventDefault(); $('#fi-err').textContent = '';
      try { await C.rpc('paciente_clinico_guardar', { p_id: F.id, p_alergias: $('#h-ale').value, p_medicamentos: $('#h-med').value, p_antecedentes_medicos: $('#h-ant').value, p_antecedentes_odonto: $('#h-odo').value, p_habitos: $('#h-hab').value, p_observaciones: $('#h-obs').value }); aviso('Historia clínica guardada.'); abrir(F.id, 'clinico'); } catch (x) { falla('#fi-err', x); } };
  }

  /* ---- odontograma por superficies (numeración FDI; el dibujo y las marcas viven en clinica-odo.js) ---- */
  async function cargarOdo() {
    try { ODO = await C.rpc('odontograma_lista', { p_id: F.id }); odoSup = true; }
    catch (e) {   // base sin la migración 011: se sigue con el diente completo, sin marcar por superficie
      if (!/odontograma_lista|PGRST202|Could not find/i.test(String((e && (e.message || e.code)) || e))) throw e;
      odoSup = false; ODO = (F.odontograma || []).map(o => ({ id: 0, diente: o.diente, superficie: null, estado: o.estado, nota: o.nota, dia: o.dia }));
    }
    ODOid = F.id;
  }
  function pOdo() {
    if (ODOid !== F.id || ODO === null) {
      $('#fi-cuerpo').innerHTML = '<p class="vacio">Cargando odontograma…</p>';
      cargarOdo().then(() => { if (sub === 'odo' && F) pOdo(); }).catch(e => { $('#fi-cuerpo').innerHTML = `<p class="vacio">${esc(msgErr(e))}</p>`; });
      return;
    }
    const a = edad(F.datos && F.datos.nacimiento);
    $('#fi-cuerpo').innerHTML = `${bannerConsent()}<div id="od-raiz"></div><p class="nota-d">Cada marca queda en el historial y no se edita; el dibujo muestra el último estado de cada diente y de cada superficie.</p><section class="plan-trat" id="pln" aria-labelledby="pln-h"></section>`;
    odoUI = CLODO.montar($('#od-raiz'), { filas: ODO, escribir: consiente(), superficies: odoSup, temporales: (a != null && a < 14) || ODO.some(o => o.diente > 50), msg: msgErr, alElegir: n => { const s = $('#pln-d'); if (s) s.value = String(n); },
      aviso: odoSup ? '' : 'Marcar por superficie queda pendiente de actualizar la base de datos (migración 011). Por ahora se marca el diente completo.',
      guardar: async (diente, cambios, nota) => {
        try {
          for (const c of cambios) { const arg = { p_id: F.id, p_diente: diente, p_estado: c.estado, p_nota: nota, p_doctor: null }; if (c.superficie) arg.p_superficie = c.superficie; await C.rpc('odontograma_marcar', arg); }
          aviso(`Diente ${diente} guardado.`);
        } finally { await cargarOdo(); odoUI.actualizar(ODO); pintarPlan(); }   // aunque falle a la mitad, se muestra lo que sí quedó guardado
      } });
    pintarPlan();
  }

  /* ---- sesión de la visita (carrito de tratamientos + marcas del odontograma) e historial de sesiones ----
     Cada tratamiento puesto en un diente suma su precio (del tarifario, calculado en la base); «Guardar sesión» deja todo en un solo registro que no se edita,
     y de cada sesión se pasa a proforma (solo administración y doctor). */
  const ETQ = e => (CLODO.ESTADO[e] || [])[1] || e;
  async function pintarPlan() {
    const r = $('#pln'); if (!r) return;
    let L, H;
    try { [L, H] = await Promise.all([C.rpc('plan_lista', { p_id: F.id }), C.rpc('sesiones_lista', { p_id: F.id }).catch(e => { if (/sesiones_lista|PGRST202|Could not find/i.test(String((e && (e.message || e.code)) || e))) return null; throw e; })]); }
    catch (e) {   // base sin la migración 013: el odontograma sigue igual y la sesión lo avisa
      if (!/plan_lista|PGRST202|Could not find/i.test(String((e && (e.message || e.code)) || e))) { r.innerHTML = `<p class="vacio">${esc(msgErr(e))}</p>`; return; }
      r.innerHTML = '<h3 id="pln-h">Sesión de hoy</h3><p class="nota-d">La sesión de tratamiento queda pendiente de actualizar la base de datos (migraciones 013 y 014).</p>'; return;
    }
    const temp = ODO.some(o => o.diente > 50) || (edad(F.datos && F.datos.nacimiento) != null && edad(F.datos.nacimiento) < 14), sel = odoUI ? odoUI.diente() : 16;
    const dientes = [...CLODO.SUP, ...CLODO.INF, ...(temp ? [...CLODO.TSUP, ...CLODO.TINF] : [])].sort((a, b) => a - b), tar = P.tar().filter(t => t.activo !== false);
    const docs = P.docs().filter(d => d.activo), citas = F.citas.filter(c => c.estado !== 'cancelada'), puede = P.puedeProforma(), conH = H !== null;
    const piezas = it => it.map(i => `<li>${i.diente} · ${esc(i.descripcion)} · ${usd(i.precio)}</li>`).join('');
    r.innerHTML = `<h3 id="pln-h">Sesión de hoy</h3><p class="nota-d">Marca el odontograma y agrega cada tratamiento realizado: el precio sale del tarifario y se suma abajo. Al terminar, guarda la sesión: queda en el historial.</p>
      <form class="fila no-print" id="pln-form" autocomplete="off"><div class="campo"><label for="pln-d">Diente</label><select id="pln-d">${dientes.map(n => `<option value="${n}"${n === sel ? ' selected' : ''}>${n}</option>`).join('')}</select></div>
        <div class="campo"><label for="pln-tr">Tratamiento</label><select id="pln-tr">${tar.map(t => `<option value="${t.id}">${esc(t.nombre)} · ${usd(t.precio)}</option>`).join('')}</select></div>
        <button class="btn" type="submit" ${consiente() && tar.length ? '' : 'disabled'}>Agregar a la sesión</button></form><p class="err-f" id="pln-err" role="alert"></p>
      <div style="overflow-x:auto"><table class="tabla"><thead><tr><th>Diente</th><th>Tratamiento</th><th class="n">Precio</th><th></th></tr></thead><tbody>${L.items.map(i => `<tr><td>${i.diente}</td><td>${esc(i.descripcion)}</td><td class="n">${usd(i.precio)}</td><td class="no-print"><button type="button" class="mini" data-pq="${i.id}" aria-label="Quitar ${esc(i.descripcion)} del diente ${i.diente}">Quitar</button></td></tr>`).join('') || '<tr><td colspan="4">Todavía no hay tratamientos en la sesión.</td></tr>'}</tbody></table></div>
      <div class="tot" style="display:flex;justify-content:space-between;font:800 1.2rem var(--fx-font-disp);padding-top:8px;margin-top:6px;border-top:2px solid var(--fx-deep)"><span>Total de la sesión</span><span id="pln-total">${usd(L.total)}</span></div>
      ${conH ? `<p class="nota-d" id="pln-marcas">Marcas nuevas en el odontograma: ${L.marcas_nuevas || 0}</p>
      <div class="fila no-print"><div class="campo"><label for="pln-cita">Cita</label><select id="pln-cita"><option value="">Sin cita</option>${citas.map(c => `<option value="${c.id}">${esc(fechaCorta(c.dia))} ${esc(c.hora)} · ${esc(c.servicio)}</option>`).join('')}</select></div>
        <div class="campo"><label for="pln-doc">Doctor</label><select id="pln-doc"><option value="">—</option>${docs.map(d => `<option value="${d.id}">${esc(d.nombre)}</option>`).join('')}</select></div>
        <div class="campo" style="grid-column:1/-1"><label for="pln-nota">Nota de la sesión (opcional)</label><input id="pln-nota" maxlength="300"></div>
        <button type="button" class="btn" id="pln-guardar" ${consiente() && (L.items.length || L.marcas_nuevas) ? '' : 'disabled'}>Guardar sesión</button></div>
      <h3 id="ses-h" style="font:800 1.15rem var(--fx-font-disp);margin:26px 0 8px">Historial de sesiones</h3>
      <div class="tarjetas">${H.map(x => `<article class="sol" data-ses="${x.id}"><h3>${esc(x.dia)} · ${usd(x.total)}</h3>
        <div class="meta">${x.doctor ? `<span>${esc(x.doctor)}</span>` : ''}<span>Registró: ${esc(x.autor || '—')}</span>${x.presupuestada ? '<span class="pill ok">Proforma creada</span>' : ''}</div>
        ${x.nota ? `<p>${esc(x.nota)}</p>` : ''}
        ${x.items.length ? `<p><b>Tratamientos realizados</b></p><ul class="lista-ses">${piezas(x.items)}</ul>` : ''}
        ${x.marcas.length ? `<p><b>Marcas del odontograma</b></p><p class="meta">${x.marcas.map(m => `${m.diente}${m.superficie ? '/' + m.superficie : ''} ${esc(ETQ(m.estado))}`).join(' · ')}</p>` : ''}
        <div class="acciones no-print"><button type="button" class="mini" data-oda="${x.id}">Ver el odontograma de ese día</button>
          ${puede && x.pendiente_proforma ? `<label class="mini-lbl">Descuento (%) <input type="number" min="0" max="50" value="0" data-dsc="${x.id}" style="width:64px"></label><button type="button" class="btn" data-pro="${x.id}">Pasar a proforma</button>` : ''}</div>
        <div data-odb="${x.id}"></div></article>`).join('') || '<p class="vacio">Todavía no hay sesiones guardadas.</p>'}</div>` : '<p class="nota-d">El historial de sesiones queda pendiente de actualizar la base de datos (migración 014).</p>'}`;
    $('#pln-form').onsubmit = async e => { e.preventDefault(); $('#pln-err').textContent = '';
      try { await C.rpc('plan_agregar', { p_id: F.id, p_diente: +$('#pln-d').value, p_tarifario: +$('#pln-tr').value }); } catch (x) { falla('#pln-err', x); return; }
      pintarPlan(); };
    $$('[data-pq]', r).forEach(b => b.onclick = async () => { try { await C.rpc('plan_quitar', { p_item: +b.dataset.pq }); } catch (x) { falla('#pln-err', x); } pintarPlan(); });
    const g = $('#pln-guardar'); if (g) g.onclick = async () => { $('#pln-err').textContent = ''; g.disabled = true;
      try { const x = await C.rpc('sesion_guardar', { p_id: F.id, p_cita: $('#pln-cita').value ? +$('#pln-cita').value : null, p_doctor: $('#pln-doc').value ? +$('#pln-doc').value : null, p_nota: $('#pln-nota').value }); aviso(`Sesión guardada: ${usd(x.total)}.`); pintarPlan(); }
      catch (x) { falla('#pln-err', x); g.disabled = false; } };
    $$('[data-oda]', r).forEach(b => b.onclick = async () => { const cont = $(`[data-odb="${b.dataset.oda}"]`, r); if (cont.innerHTML) { cont.innerHTML = ''; return; }
      try { const f = await C.rpc('odontograma_en', { p_sesion: +b.dataset.oda }); cont.innerHTML = '<p class="nota-d">Así estaba el odontograma al cerrar esa sesión (solo lectura).</p><div class="od-hist"></div>';
        CLODO.montar($('.od-hist', cont), { filas: f, escribir: false, superficies: true, temporales: f.some(o => o.diente > 50), msg: msgErr, guardar: async () => {} }); } catch (x) { falla('#pln-err', x); } });
    $$('[data-pro]', r).forEach(b => b.onclick = async () => { $('#pln-err').textContent = '';
      try { const x = await C.rpc('sesion_a_presupuesto', { p_sesion: +b.dataset.pro, p_doctor: null, p_descuento: Math.round(+$(`[data-dsc="${b.dataset.pro}"]`).value || 0), p_seguimiento: null }); aviso(`Proforma creada: ${usd(x.total)}.`); abrir(F.id, 'cobros'); }
      catch (x) { falla('#pln-err', x); } });
  }

  /* ---- evolución (notas de cada consulta; no se editan: se corrigen con una nota nueva) ---- */
  function pEvo() {
    const corr = corrigiendo && (F.evoluciones || []).find(x => x.id === corrigiendo);
    $('#fi-cuerpo').innerHTML = `${bannerConsent()}<form class="fila no-print" id="e-form" autocomplete="off">
        ${corr ? `<p class="aviso-clin" style="grid-column:1/-1">Estás corrigiendo la nota del ${esc(corr.dia)} («${esc(corr.motivo)}»). La nota original se conserva y esta quedará enlazada.</p>` : ''}
        <div class="campo"><label for="e-cita">Cita</label><select id="e-cita"><option value="">Sin cita</option>${F.citas.filter(c => c.estado !== 'cancelada').map(c => `<option value="${c.id}">${esc(fechaCorta(c.dia))} ${esc(c.hora)} · ${esc(c.servicio)}</option>`).join('')}</select></div>
        <div class="campo"><label for="e-doc">Doctor</label><select id="e-doc"><option value="">—</option>${P.docs().filter(d => d.activo).map(d => `<option value="${d.id}">${esc(d.nombre)}</option>`).join('')}</select></div>
        <div class="campo" style="grid-column:1/-1"><label for="e-mot">Motivo de la consulta</label><input id="e-mot" maxlength="300" required value="${corr ? esc(corr.motivo) : ''}"></div>
        ${area('e-dx', 'Diagnóstico', corr && corr.diagnostico)}${area('e-pr', 'Procedimiento realizado', corr && corr.procedimiento)}${area('e-in', 'Indicaciones al paciente', corr && corr.indicaciones)}
        <button class="btn" type="submit" ${consiente() ? '' : 'disabled'}>${corr ? 'Guardar corrección' : 'Guardar evolución'}</button>${corr ? '<button class="btn btn-linea" type="button" id="e-cancel">Cancelar</button>' : ''}</form><p class="err-f" id="fi-err" role="alert"></p>
      <div class="tarjetas">${(F.evoluciones || []).map(x => `<article class="sol"><h3>${esc(x.motivo)}</h3><div class="meta"><span>${esc(x.dia)}</span>${x.doctor ? `<span>${esc(x.doctor)}</span>` : ''}<span>Escribió: ${esc(x.autor || '—')}</span>${x.corrige_id ? '<span class="pill esp">Corrige una nota anterior</span>' : ''}</div>
        ${x.diagnostico ? `<p><b>Diagnóstico:</b> ${esc(x.diagnostico)}</p>` : ''}${x.procedimiento ? `<p><b>Procedimiento:</b> ${esc(x.procedimiento)}</p>` : ''}${x.indicaciones ? `<p><b>Indicaciones:</b> ${esc(x.indicaciones)}</p>` : ''}
        ${consiente() ? `<div class="acciones no-print"><button type="button" class="mini" data-corr="${x.id}">Corregir</button></div>` : ''}</article>`).join('') || '<p class="vacio">Todavía no hay notas de evolución.</p>'}</div>`;
    $$('[data-corr]').forEach(b => b.onclick = () => { corrigiendo = +b.dataset.corr; pEvo(); window.scrollTo({ top: $('#pa-ficha').offsetTop, behavior: 'smooth' }); });
    const ca = $('#e-cancel'); if (ca) ca.onclick = () => { corrigiendo = null; pEvo(); };
    $('#e-form').onsubmit = async e => { e.preventDefault(); $('#fi-err').textContent = '';
      try { await C.rpc('evolucion_guardar', { p_id: F.id, p_cita: $('#e-cita').value ? +$('#e-cita').value : null, p_doctor: $('#e-doc').value ? +$('#e-doc').value : null, p_motivo: $('#e-mot').value, p_diagnostico: $('#e-dx').value, p_procedimiento: $('#e-pr').value, p_indicaciones: $('#e-in').value, p_corrige: corrigiendo });
        corrigiendo = null; aviso('Evolución guardada.'); abrir(F.id, 'evo'); } catch (x) { falla('#fi-err', x); } };
  }

  /* ---- accesos (auditoría; solo administración) ---- */
  async function pAccesos() {
    $('#fi-cuerpo').innerHTML = '<p class="vacio">Cargando…</p>';
    try { const l = await C.rpc('auditoria_lista', { p_id: F.id, p_limite: 100 });
      $('#fi-cuerpo').innerHTML = `<div style="overflow-x:auto"><table class="tabla"><thead><tr><th>Cuándo</th><th>Quién</th><th>Qué hizo</th><th>Detalle</th></tr></thead><tbody>${l.map(a => `<tr><td>${esc(a.cuando)}</td><td>${esc(a.quien)}</td><td>${esc(a.accion.replace(/_/g, ' '))}</td><td>${esc(a.detalle || '')}</td></tr>`).join('') || '<tr><td colspan="4">Sin movimientos.</td></tr>'}</tbody></table></div>`; }
    catch (e) { $('#fi-cuerpo').innerHTML = `<p class="vacio">${esc(msgErr(e))}</p>`; }
  }

  P.cargar['t-pacientes'] = () => { if (F) mostrar(); else buscar(); };
})();
