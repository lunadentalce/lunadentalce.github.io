const { esc, $, $$, usd, hoy, suma, dif, dow, lunes, fechaCorta, fechaLarga, tel09, wa, msgErr, aviso } = CLUI, C = CLINICA;
/* clinica-panel.js · panel de trabajo del equipo (solicitudes, agenda, caja, presupuestos). Lo usan equipo.html y dueno.html (que suma la gestión). */
const falla = (el, e) => { const t = msgErr(e); el ? (el.textContent = t) : null; aviso(t, 'mal'); };
let YO = null, DOCS = [], TAR = [], HORARIO = { h0: 8, h1: 17, paso: 30 };
const docNombre = id => (DOCS.find(d => d.id === id) || { nombre: 'Sin asignar' }).nombre;
const docColor = id => (DOCS.find(d => d.id === id) || { color: '#8E8F94' }).color;

/* ---------- pestañas (teclado: flechas) ---------- */
const tabs = $$('.riel button[role=tab]');
const visibles = () => tabs.filter(b => !b.hidden);
function ir(t) { tabs.forEach(b => { const on = b === t; b.setAttribute('aria-selected', on); b.tabIndex = on ? 0 : -1; $('#' + b.getAttribute('aria-controls')).hidden = !on; }); (CARGAR[t.id] || (() => {}))(); }
tabs.forEach(b => { b.onclick = () => ir(b); b.onkeydown = e => { const v = visibles(), i = v.indexOf(b), d = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key]; if (d) { e.preventDefault(); const n = v[(i + d + v.length) % v.length]; n.focus(); ir(n); } }; });

/* ---------- solicitudes ---------- */
const FR = { manana: 'Mañana', tarde: 'Tarde', cualquiera: 'Cualquier horario' };
let solEstado = 'nueva';
const horas = () => { const o = []; for (let m = HORARIO.h0 * 60; m < HORARIO.h1 * 60; m += HORARIO.paso) o.push(String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0')); return o; };
async function pintarSolicitudes() {
  const cont = $('#sol-lista');
  try {
    const l = await C.rpc('solicitudes_lista', { p_estado: solEstado });
    if (solEstado === 'nueva') { const n = $('#n-sol'); n.textContent = l.length; n.hidden = !l.length; }
    cont.innerHTML = l.length ? l.map(s => `<article class="sol" data-id="${s.id}">
      <h3>${esc(s.nombre)}</h3>
      <div class="meta"><span>📱 ${esc(tel09(s.telefono))}</span><span>📅 ${esc(fechaCorta(s.dia))} · ${esc(FR[s.franja] || s.franja)}</span><span>Recibida ${esc(new Date(s.creado).toLocaleString('es-EC', { timeZone: CLUI.TZ, day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }))}</span></div>
      <div class="chips">${s.servicios.map(x => `<span class="pill">${esc(x.nombre)}</span>`).join('')}${s.para_menor ? `<span class="pill menor">Menor de edad · autoriza ${esc(s.representante)}</span>` : ''}</div>
      ${solEstado === 'nueva' ? `<div class="acciones"><button type="button" class="btn" data-agendar="${s.id}">Agendar</button>
        <a class="btn btn-linea" target="_blank" rel="noopener" href="${wa(s.telefono, `Hola ${s.nombre.split(' ')[0]}, te escribimos de ${DEMO.cliente} por tu solicitud de cita (${s.servicios.map(x => x.nombre).join(', ')}).`)}">Escribir por WhatsApp</a>
        <button type="button" class="mini" data-descartar="${s.id}">Descartar</button></div><div class="agendar" hidden></div>` : ''}
    </article>`).join('') : `<p class="vacio">${solEstado === 'nueva' ? 'No hay solicitudes nuevas.' : 'Nada por aquí todavía.'}</p>`;
    $$('[data-agendar]', cont).forEach(b => b.onclick = () => abrirAgendar(b.closest('.sol'), l.find(x => x.id == b.dataset.agendar)));
    $$('[data-descartar]', cont).forEach(b => b.onclick = async () => { if (!confirm('¿Descartar esta solicitud?')) return; try { await C.rpc('solicitud_descartar', { p_id: +b.dataset.descartar }); aviso('Solicitud descartada.'); pintarSolicitudes(); } catch (e) { falla(null, e); } });
  } catch (e) { cont.innerHTML = `<p class="vacio">${esc(msgErr(e))}</p>`; }
}
function abrirAgendar(card, s) {
  const f = $('.agendar', card); f.hidden = !f.hidden; if (f.hidden) return;
  f.innerHTML = `<div class="campo"><label>Tratamiento</label><select class="a-sv">${s.servicios.map(x => `<option value="${x.id}">${esc(x.nombre)}</option>`).join('')}</select></div>
    <div class="campo"><label>Día</label><input class="a-dia" type="date" value="${esc(s.dia)}" min="${hoy()}"></div>
    <div class="campo"><label>Hora</label><select class="a-hora">${horas().map(h => `<option ${h === (s.franja === 'tarde' ? '15:00' : '09:00') ? 'selected' : ''}>${h}</option>`).join('')}</select></div>
    <div class="campo"><label>Doctor</label><select class="a-doc"><option value="">Sin asignar</option>${DOCS.filter(d => d.activo).map(d => `<option value="${d.id}">${esc(d.nombre)}</option>`).join('')}</select></div>
    <button type="button" class="btn a-ok">Confirmar cita</button><p class="err-f a-err" role="alert" style="grid-column:1/-1"></p>`;
  $('.a-ok', f).onclick = async () => {
    try {
      const r = await C.rpc('solicitud_agendar', { p_id: s.id, p_servicio: +$('.a-sv', f).value, p_dia: $('.a-dia', f).value, p_hora: $('.a-hora', f).value, p_doctor: $('.a-doc', f).value ? +$('.a-doc', f).value : null });
      aviso(`Cita confirmada para ${r.nombre}.`); window.open(wa(s.telefono, `Hola ${s.nombre.split(' ')[0]}, tu cita en ${DEMO.cliente} quedó confirmada: ${fechaLarga($('.a-dia', f).value)} a las ${$('.a-hora', f).value}. Te esperamos.`), '_blank', 'noopener');
      pintarSolicitudes();
    } catch (e) { falla($('.a-err', f), e); }
  };
}
$$('#sol-filtro .cb').forEach(b => b.onclick = () => { solEstado = b.dataset.e; $$('#sol-filtro .cb').forEach(x => x.setAttribute('aria-pressed', x === b)); pintarSolicitudes(); });

/* ---------- agenda ---------- */
const IH = 44;
const ag = { dia: hoy(), vista: 'dia', docs: new Set(), citas: [], sel: null };
const hm = m => String(Math.floor(m / 60)).padStart(2, '0') + ':' + String(m % 60).padStart(2, '0');
const mins = s => +s.slice(0, 2) * 60 + +s.slice(3, 5);
const ESTADO = { pendiente: 'Por confirmar', confirmada: 'Confirmada', atendida: 'Atendida', no_vino: 'No vino', cancelada: 'Cancelada' };
async function cargarAgenda() {
  const d0 = ag.vista === 'dia' ? ag.dia : lunes(ag.dia), d1 = ag.vista === 'dia' ? ag.dia : suma(lunes(ag.dia), 5);
  try { ag.citas = await C.rpc('clinica_agenda', { p_desde: d0, p_hasta: d1 }); } catch (e) { ag.citas = []; falla(null, e); }
  pintarAgenda(); detalle();
}
function pintarAgenda() {
  const activos = DOCS.filter(d => d.activo || ag.citas.some(c => c.doctor_id === d.id));
  if (!ag.docs.size) activos.forEach(d => ag.docs.add(d.id));
  const sinAsignar = ag.citas.some(c => c.doctor_id == null);
  const cols = ag.vista === 'dia'
    ? [...activos.filter(d => ag.docs.has(d.id)).map(d => ({ t: d.nombre, f: c => c.doctor_id === d.id })), ...(sinAsignar ? [{ t: 'Sin asignar', f: c => c.doctor_id == null }] : [])]
    : [0, 1, 2, 3, 4, 5].map(i => { const dia = suma(lunes(ag.dia), i); return { t: fechaCorta(dia), f: c => c.dia === dia && (c.doctor_id == null || ag.docs.has(c.doctor_id)) }; });
  const H0 = HORARIO.h0 * 60, filas = (HORARIO.h1 - HORARIO.h0) * 2, g = $('#ag-grid');
  g.style.gridTemplateColumns = `56px repeat(${Math.max(cols.length, 1)}, minmax(130px, 1fr))`;
  let h = `<div class="ag-cab">${ag.vista === 'dia' ? esc(fechaCorta(ag.dia)) : 'Semana'}</div>` + cols.map(c => `<div class="ag-cab">${esc(c.t)}</div>`).join('');
  h += `<div>${Array.from({ length: filas }, (_, i) => `<div class="ag-hora">${i % 2 ? '' : hm(H0 + i * 30)}</div>`).join('')}</div>`;
  const botonCita = (c, i, n) => { const top = (mins(c.hora) - H0) / 30 * IH; if (top < 0 || top > filas * IH) return '';
    return `<button type="button" class="cita" data-id="${c.id}" aria-pressed="${ag.sel === c.id}" style="--c:${docColor(c.doctor_id)};top:${top}px;height:${Math.max(c.duracion / 30 * IH - 2, 30)}px;left:calc(${i} * 100% / ${n} + 3px);right:calc(${n - 1 - i} * 100% / ${n} + 3px)${c.estado === 'atendida' ? ';opacity:.6' : ''}${c.estado === 'no_vino' ? ';text-decoration:line-through' : ''}"><b>${esc(c.hora)} · ${esc(c.nombre)}</b>${esc(c.servicio)}${c.estado === 'pendiente' ? ' · por confirmar' : ''}</button>`; };
  /* citas que se solapan en la misma columna (varias cabinas, o una atendida que sigue ahí) se reparten el ancho */
  const carriles = lista => { const o = lista.slice().sort((x, y) => mins(x.hora) - mins(y.hora) || x.id - y.id), fin = [], out = []; let grupo = [];
    const cerrar = () => { const n = Math.max(1, ...grupo.map(g => g.i + 1)); grupo.forEach(g => out.push(botonCita(g.c, g.i, n))); grupo = []; };
    o.forEach(c => { const ini = mins(c.hora); if (grupo.length && ini >= Math.max(...fin)) { cerrar(); fin.length = 0; }
      let i = fin.findIndex(f => f <= ini); if (i < 0) i = fin.length; fin[i] = ini + c.duracion; grupo.push({ c, i }); }); cerrar(); return out.join(''); };
  cols.forEach(col => { h += `<div class="ag-col" style="height:${filas * IH}px">` + carriles(ag.citas.filter(col.f)) + '</div>'; });
  g.innerHTML = h;
  $$('.cita', g).forEach(b => b.onclick = () => { ag.sel = ag.sel == b.dataset.id ? null : +b.dataset.id; pintarAgenda(); detalle(); });
}
function detalle() {
  const c = ag.citas.find(x => x.id === ag.sel), d = $('#ag-det'); d.hidden = !c; if (!c) return;
  d.innerHTML = `<b>${esc(c.nombre)} · ${esc(c.hora)} (${c.duracion} min)</b><span>${esc(c.servicio)} · ${esc(docNombre(c.doctor_id))} · <span class="pill">${esc(ESTADO[c.estado])}</span></span>
    <div class="campo" style="max-width:260px"><label for="d-doc">Doctor</label><select id="d-doc"><option value="">Sin asignar</option>${DOCS.filter(x => x.activo || x.id === c.doctor_id).map(x => `<option value="${x.id}" ${x.id === c.doctor_id ? 'selected' : ''}>${esc(x.nombre)}</option>`).join('')}</select></div>
    <div class="estado-btns">${['confirmada', 'atendida', 'no_vino', 'cancelada'].map(e => `<button type="button" class="cb" data-est="${e}" aria-pressed="${c.estado === e}">${esc(ESTADO[e])}</button>`).join('')}</div>
    <form class="agendar" id="mv-form" style="padding-top:10px"><div class="campo"><label for="mv-dia">Mover a otro día</label><input id="mv-dia" type="date" value="${esc(c.dia)}" min="${hoy()}" required></div><div class="campo"><label for="mv-hora">Hora</label><input id="mv-hora" type="time" step="300" value="${esc(c.hora)}" required></div><button class="btn btn-linea" type="submit">Mover cita</button></form>
    <div class="acciones"><a class="btn" target="_blank" rel="noopener" href="${wa(c.telefono, `Hola ${c.nombre.split(' ')[0]}, te escribimos de ${DEMO.cliente} para confirmar tu cita (${c.servicio}) el ${fechaLarga(c.dia)} a las ${c.hora}.`)}">Confirmar por WhatsApp</a><button type="button" class="btn btn-linea" id="det-x">Cerrar</button></div><p class="err-f" id="d-err" role="alert"></p>`;
  $('#mv-form').onsubmit = async e => { e.preventDefault(); try { await C.rpc('mover_cita', { p_cita: c.id, p_dia: $('#mv-dia').value, p_hora: $('#mv-hora').value }); aviso('Cita movida.'); ag.dia = $('#mv-dia').value; cargarAgenda(); } catch (er) { falla($('#d-err'), er); } };
  $('#det-x').onclick = () => { ag.sel = null; pintarAgenda(); detalle(); };
  $('#d-doc').onchange = async e => { try { await C.rpc('cita_doctor', { p_cita: c.id, p_doctor: e.target.value ? +e.target.value : null }); aviso('Doctor actualizado.'); cargarAgenda(); } catch (er) { falla($('#d-err'), er); } };
  $$('[data-est]', d).forEach(b => b.onclick = async () => { try { await C.rpc('cita_estado', { p_cita: c.id, p_estado: b.dataset.est }); aviso('Estado actualizado.'); if (b.dataset.est === 'cancelada') ag.sel = null; cargarAgenda(); } catch (er) { falla($('#d-err'), er); } });
}
let SERV = [];
async function prepararNuevaCita() {
  if (!$('#nc-form')) return;
  try { SERV = await C.rpc('servicios_lista'); } catch (e) { SERV = []; }
  $('#nc-sv').innerHTML = SERV.map(s => `<option value="${s.id}">${esc(s.nombre)} · ${s.duracion_min} min</option>`).join('');
  $('#nc-doc').innerHTML = '<option value="">Sin asignar</option>' + DOCS.filter(d => d.activo).map(d => `<option value="${d.id}">${esc(d.nombre)}</option>`).join('');
  $('#nc-dia').min = hoy(); if (!$('#nc-dia').value) $('#nc-dia').value = ag.dia < hoy() ? hoy() : ag.dia;
}
$('#nc-abrir').onclick = () => { const f = $('#nc-form'); f.hidden = !f.hidden; $('#nc-abrir').setAttribute('aria-expanded', !f.hidden); if (!f.hidden) $('#nc-nombre').focus(); };
$('#nc-form').onsubmit = async e => { e.preventDefault(); const er = $('#nc-err'); er.textContent = '';
  try { const r = await C.rpc('cita_nueva', { p_nombre: $('#nc-nombre').value, p_telefono: $('#nc-tel').value.replace(/[\s-]/g, ''), p_servicio: +$('#nc-sv').value, p_dia: $('#nc-dia').value, p_hora: $('#nc-hora').value, p_doctor: $('#nc-doc').value ? +$('#nc-doc').value : null });
    const dia = $('#nc-dia').value; aviso(`Cita creada para ${r.nombre}.`); e.target.reset(); $('#nc-form').hidden = true; $('#nc-abrir').setAttribute('aria-expanded', false); ag.dia = dia || ag.dia; prepararNuevaCita(); cargarAgenda(); }
  catch (x) { falla(er, x); } };
const paso = () => ag.vista === 'dia' ? 1 : 7;
$('#ag-ant').onclick = () => { ag.dia = suma(ag.dia, -paso()); cargarAgenda(); };
$('#ag-sig').onclick = () => { ag.dia = suma(ag.dia, paso()); cargarAgenda(); };
$('#ag-hoy').onclick = () => { ag.dia = hoy(); cargarAgenda(); };
[['#vi-dia', 'dia'], ['#vi-sem', 'sem']].forEach(([s, v]) => $(s).onclick = () => { ag.vista = v; $('#vi-dia').setAttribute('aria-pressed', v === 'dia'); $('#vi-sem').setAttribute('aria-pressed', v === 'sem'); cargarAgenda(); });
function pintarFiltroDocs() {
  $('#ag-docs').innerHTML = DOCS.filter(d => d.activo).map(d => `<button type="button" class="cb doc-chip" data-d="${d.id}" aria-pressed="${ag.docs.has(d.id)}" style="--c:${d.color}"><i></i>${esc(d.nombre)}</button>`).join('');
  $$('#ag-docs .cb').forEach(b => b.onclick = () => { const id = +b.dataset.d; ag.docs.has(id) ? ag.docs.delete(id) : ag.docs.add(id); b.setAttribute('aria-pressed', ag.docs.has(id)); pintarAgenda(); });
  $('#ag-ley').innerHTML = DOCS.filter(d => d.activo).map(d => `<span><i style="--c:${d.color}"></i>${esc(d.nombre)}${d.especialidad ? ' · ' + esc(d.especialidad) : ''}</span>`).join('');
}

/* ---------- caja ---------- */
let cajaDia = hoy(), motivoDe = null;
async function pintarCaja() {
  try {
    const r = await C.rpc('caja_dia', { p_dia: cajaDia });
    $('#caja-kpis').innerHTML = [['Ingresos', usd(r.ingresos), 'del día'], ['Egresos', usd(r.egresos), 'del día'], ['Saldo', usd(r.ingresos - r.egresos), 'ingresos menos egresos']].map(([a, b, c]) => `<div class="kpi"><small>${a}</small><b>${b}</b><span>${c}</span></div>`).join('');
    $('#caja-lista').innerHTML = r.items.length ? r.items.slice().reverse().map(m => `<tr class="${m.anulado ? 'anulado' : ''}"><td>${esc(m.hora)}</td><td>${esc(m.descripcion)}${m.anulado && m.motivo ? `<br><small>Anulado: ${esc(m.motivo)}</small>` : ''}</td><td>${esc(docNombre(m.doctor_id))}</td><td class="n ${m.tipo}">${m.tipo === 'egr' ? '−' : '+'}${usd(m.importe)}</td><td>${m.anulado ? 'Anulado' : `<button type="button" class="mini" data-a="${m.id}" data-d="${esc(m.descripcion)}">Anular</button>`}</td></tr>`).join('') : '<tr><td colspan="5">Sin movimientos este día.</td></tr>';
    $$('[data-a]').forEach(b => b.onclick = () => { motivoDe = +b.dataset.a; $('#dlg-txt').textContent = `Vas a anular «${b.dataset.d}». Queda el registro con tu nombre y el motivo.`; $('#dlg-m').value = ''; $('#dlg-motivo').showModal(); });
  } catch (e) { $('#caja-lista').innerHTML = `<tr><td colspan="5">${esc(msgErr(e))}</td></tr>`; }
}
$('#dlg-x').onclick = () => $('#dlg-motivo').close();
$('#dlg-form').onsubmit = async e => { e.preventDefault(); try { await C.rpc('caja_anular', { p_id: motivoDe, p_motivo: $('#dlg-m').value }); $('#dlg-motivo').close(); aviso('Movimiento anulado.'); pintarCaja(); } catch (er) { falla(null, er); } };
$('#c-dia').value = cajaDia; $('#c-dia').max = hoy(); $('#c-dia').onchange = e => { cajaDia = e.target.value || hoy(); pintarCaja(); };
$('#caja-form').onsubmit = async e => { e.preventDefault(); const er = $('#c-err'); er.textContent = '';
  try { await C.rpc('caja_registrar', { p_descripcion: $('#c-desc').value, p_importe: parseFloat($('#c-imp').value), p_tipo: $('#c-tipo').value, p_doctor: $('#c-doc').value ? +$('#c-doc').value : null });
    e.target.reset(); aviso('Movimiento registrado.'); cajaDia = hoy(); $('#c-dia').value = cajaDia; pintarCaja(); } catch (x) { falla(er, x); } };

/* ---------- presupuestos ---------- */
let pres = [], plEstado = '', presClienta = null;
const totalP = () => Math.round(pres.reduce((s, l) => s + l.precio * l.cant, 0) * (100 - Math.min(50, Math.max(0, +$('#p-desc').value || 0))) ) / 100;
function pintarPres() {
  $('#p-lista').innerHTML = pres.length ? pres.map((l, i) => `<tr><td>${esc(l.nombre)}</td><td class="n">${l.cant}</td><td class="n">${usd(l.precio * l.cant)}</td><td><button type="button" class="mini" data-q="${i}" aria-label="Quitar ${esc(l.nombre)}">Quitar</button></td></tr>`).join('') : '<tr><td colspan="4">Agrega tratamientos para armar el presupuesto.</td></tr>';
  $('#p-total').textContent = usd(totalP());
  $$('[data-q]').forEach(b => b.onclick = () => { pres.splice(+b.dataset.q, 1); pintarPres(); });
}
$('#p-add').onclick = () => { const t = TAR.find(x => x.id == $('#p-item').value); if (!t) return; const c = Math.min(20, Math.max(1, parseInt($('#p-cant').value) || 1)); const ex = pres.find(l => l.id === t.id); ex ? ex.cant = Math.min(20, ex.cant + c) : pres.push({ id: t.id, nombre: t.nombre, precio: +t.precio, cant: c }); pintarPres(); };
$('#p-desc').oninput = pintarPres;
$('#p-pac').oninput = () => { presClienta = null; };
$('#p-guardar').onclick = async () => { const er = $('#p-err'); er.textContent = '';
  if (!pres.length) { er.textContent = 'Agrega al menos un tratamiento.'; return; }
  try {
    const nombre = $('#p-pac').value.trim(), r = await C.rpc('presupuesto_guardar', { p_paciente: nombre, p_doctor: $('#p-doc').value ? +$('#p-doc').value : null, p_descuento: Math.round(+$('#p-desc').value || 0), p_items: pres.map(l => ({ tarifario_id: l.id, cant: l.cant })), p_seguimiento: $('#p-seg').value || null, p_clienta: presClienta });
    window.open(wa('', `Presupuesto de ${DEMO.cliente} para ${nombre}:\n` + pres.map(l => `${l.cant} × ${l.nombre}`).join('\n') + (+$('#p-desc').value ? `\nDescuento: ${Math.round(+$('#p-desc').value)} %` : '') + `\nTotal: ${usd(r.total)}\n(Sujeto a valoración. Válido por 15 días.)`), '_blank', 'noopener');
    aviso(`Presupuesto guardado: ${usd(r.total)}.`); pres = []; presClienta = null; $('#p-pac').value = ''; $('#p-desc').value = 0; $('#p-seg').value = ''; pintarPres(); pintarListaPres();
  } catch (e) { falla(er, e); } };
const puedePres = () => ['admin', 'doctor'].includes((YO || {}).rol);   // recepción ve los presupuestos pero no los crea ni los decide (la base lo exige también, migración 012)
async function pintarListaPres() {
  const c = $('#pl-lista');
  try {
    const l = await C.rpc('presupuestos_lista', { p_estado: plEstado || null }), E = { enviado: ['En espera', 'esp'], aceptado: ['Aceptado', 'ok'], rechazado: ['Rechazado', 'mal'] };
    c.innerHTML = l.length ? l.map(p => `<article class="sol"><h3>${esc(p.paciente)} · ${usd(p.total)}</h3>
      <div class="meta"><span>${esc(fechaCorta(p.creado))}</span><span>${esc(docNombre(p.doctor_id))}</span>${p.seguimiento ? `<span>Seguimiento: ${esc(fechaCorta(p.seguimiento))}</span>` : ''}<span class="pill ${E[p.estado][1]}">${E[p.estado][0]}</span></div>
      <div class="meta">${(p.items || []).map(i => `${i.cant} × ${esc(i.descripcion)}`).join(' · ')}${p.descuento ? ` · desc. ${p.descuento} %` : ''}</div>
      ${p.estado === 'enviado' && puedePres() ? `<div class="acciones"><button type="button" class="btn" data-ok="${p.id}">Lo aceptó</button><button type="button" class="btn btn-linea" data-no="${p.id}">Lo rechazó</button></div>` : ''}</article>`).join('') : '<p class="vacio">Todavía no hay presupuestos.</p>';
    const marcar = async (id, est) => { try { await C.rpc('presupuesto_estado', { p_id: id, p_estado: est }); aviso('Presupuesto actualizado.'); pintarListaPres(); } catch (e) { falla(null, e); } };
    $$('[data-ok]', c).forEach(b => b.onclick = () => marcar(+b.dataset.ok, 'aceptado')); $$('[data-no]', c).forEach(b => b.onclick = () => marcar(+b.dataset.no, 'rechazado'));
  } catch (e) { c.innerHTML = `<p class="vacio">${esc(msgErr(e))}</p>`; }
}
$$('#pl-filtro .cb').forEach(b => b.onclick = () => { plEstado = b.dataset.e; $$('#pl-filtro .cb').forEach(x => x.setAttribute('aria-pressed', x === b)); pintarListaPres(); });

const CARGAR = { 't-solicitudes': pintarSolicitudes, 't-agenda': () => { pintarFiltroDocs(); prepararNuevaCita(); cargarAgenda(); }, 't-caja': pintarCaja, 't-presupuestos': () => { const pp = puedePres(), d = $('#v-presupuestos .dos'); d.firstElementChild.hidden = !pp; d.style.gridTemplateColumns = pp ? '' : '1fr'; $('#p-solover').hidden = pp; pintarListaPres(); } };
/* Las pantallas que solo existen en el panel del dueño (resumen, doctores, tarifario, tratamientos, horario, cuentas) se registran aquí desde sus archivos */
/* Atajos que usa la ficha del paciente: abrir la agenda o los presupuestos ya con el paciente */
function nuevaCitaPara(p) { ir($('#t-agenda')); setTimeout(() => { $('#nc-form').hidden = false; $('#nc-abrir').setAttribute('aria-expanded', true); $('#nc-nombre').value = p.nombre; $('#nc-tel').value = tel09(p.telefono); $('#nc-nombre').focus(); }, 400); }
function presupuestoPara(p) { ir($('#t-presupuestos')); presClienta = p.id; $('#p-pac').value = p.nombre; pintarPres(); }
window.CLPANEL = { cargar: CARGAR, nuevaCita: nuevaCitaPara, presupuestoPara, ir: id => ir($(id)), yo: () => YO, puedePres, puedeProforma: () => !!(YO && YO.rol), tel09, base: () => cargarBase(), docs: () => DOCS, tar: () => TAR, set horario(h) { HORARIO = h; }, get horario() { return HORARIO; }, falla };

/* ---------- arranque ---------- */
async function cargarBase() {
  [DOCS, TAR] = await Promise.all([C.rpc('doctores_lista'), C.rpc('tarifario_lista')]);
  const op = (l, f) => l.map(f).join('');
  $('#c-doc').innerHTML = '<option value="">Sin doctor</option>' + op(DOCS.filter(d => d.activo), d => `<option value="${d.id}">${esc(d.nombre)}</option>`);
  $('#p-doc').innerHTML = '<option value="">Sin doctor</option>' + op(DOCS.filter(d => d.activo), d => `<option value="${d.id}">${esc(d.nombre)}</option>`);
  $('#p-item').innerHTML = op(TAR.filter(t => t.activo), t => `<option value="${t.id}">${esc(t.nombre)} · ${usd(t.precio)}</option>`);
  ag.docs = new Set(DOCS.filter(d => d.activo).map(d => d.id));
}
async function iniciar(yo) {
  YO = yo; $('#s-rol').textContent = { admin: 'Administración', doctor: 'Doctor', recepcion: 'Recepción' }[yo.rol] || yo.rol; $('#s-nombre').textContent = yo.nombre;
  { const d = $('#s-dueno'); if (d) d.hidden = yo.rol !== 'admin'; }
  $('#s-salir').onclick = () => { C.staff.salir(); location.reload(); };
  try { await cargarBase(); } catch (e) { aviso(msgErr(e), 'mal'); }
  try { const cfg = await C.rpc('config_admin'); const hs = (cfg.horario || []).filter(h => h.abre); if (hs.length) HORARIO = { paso: +(cfg.config || {}).paso_min || 30, h0: Math.min(...hs.map(h => +h.abre.slice(0, 2))), h1: Math.max(...hs.map(h => Math.ceil(+h.cierra.slice(0, 2) + (+h.cierra.slice(3, 5) ? .5 : 0)))) }; } catch (e) { /* horario por defecto 8–17 */ }
  pintarPres(); ir(tabs[0]);
}
CLUI.puerta({ soloAdmin: !!$('#v-resumen'), alEntrar: iniciar }).then(yo => { if (yo && !YO) iniciar(yo); });
