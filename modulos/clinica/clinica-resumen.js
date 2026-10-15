/* clinica-resumen.js · pantalla «Resumen» del panel del dueño: cifras del periodo contra el periodo anterior, gráficas, imprimir y CSV. */
(() => {
const { esc, $, $$, usd, hoy, suma, dif, fechaCorta, fechaLarga, pct, msgErr, aviso } = CLUI, C = CLINICA;
let R = null, rango = { d: '', h: '' }, timer = null;
const DIAS = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
const mesIni = s => s.slice(0, 8) + '01';
const finMes = s => { const d = new Date(s.slice(0, 8) + '01T12:00:00Z'); d.setUTCMonth(d.getUTCMonth() + 1, 0); return d.toISOString().slice(0, 10); };

function preset(p) {
  const h = hoy();
  if (p === 'mes') return [mesIni(h), h];
  if (p === 'ant') { const u = suma(mesIni(h), -1); return [mesIni(u), u]; }
  return [suma(h, 1 - +p), h];
}
function delta(a, b, dinero) {
  if (!b) return a ? '<span class="up">▲ nuevo</span> vs periodo anterior' : 'Sin datos del periodo anterior';
  const d = Math.round((a - b) / b * 100); const cls = d > 0 ? 'up' : d < 0 ? 'down' : '';
  return `<span class="${cls}">${d > 0 ? '▲' : d < 0 ? '▼' : '='} ${Math.abs(d)} %</span> vs periodo anterior (${dinero ? usd(b) : b})`;
}
function pintar(r) {
  const c = r.citas, s = r.solicitudes, k = r.caja, p = r.presupuestos, a = r.anterior;
  const neto = k.ingresos - k.egresos, inasist = pct(c.no_vino, c.atendidas + c.no_vino), conv = pct(s.agendadas, s.recibidas), acep = pct(p.aceptados, p.aceptados + p.rechazados);
  const ticket = k.cobros ? k.ingresos / k.cobros : 0;
  $('#kpis').innerHTML = [
    ['Ingresos', usd(k.ingresos), delta(k.ingresos, a.ingresos, true)],
    ['Neto (ingresos − egresos)', usd(neto), `Egresos ${usd(k.egresos)}${k.cobros ? ` · ticket promedio ${usd(ticket)}` : ''}`],
    ['Citas atendidas', c.atendidas, delta(c.atendidas, a.citas_atendidas) + (c.total ? ` · ${c.total} en agenda` : '')],
    ['Inasistencia', inasist == null ? '—' : inasist + ' %', `${c.no_vino} no vinieron · ${c.canceladas} canceladas`],
    ['Pacientes nuevos', r.pacientes.nuevos, delta(r.pacientes.nuevos, a.nuevos) + ` · ${r.pacientes.total} en total`],
    ['Solicitudes de la web', s.recibidas, `${conv == null ? 'Sin solicitudes' : conv + ' % ya agendadas'} · ${s.pendientes} por atender ahora`],
    ['Presupuestos aceptados', usd(p.monto_aceptado), delta(p.monto_aceptado, a.monto_aceptado, true) + ` · ${p.aceptados} de ${p.enviados} enviados`],
    ['Aceptación de presupuestos', acep == null ? '—' : acep + ' %', `${p.aceptados} aceptados · ${p.rechazados} rechazados`]
  ].map(([t, v, n]) => `<div class="kd"><small>${t}</small><b>${v}</b><span>${n}</span></div>`).join('');
  serie(k.serie);
  const emb = (a, b, t) => `<div><span>${t}</span><b>${a}${b != null ? ` <small style="font:600 .8rem var(--fx-font-txt)">de ${b}</small>` : ''}</b></div>`;
  $('#g-embudo').innerHTML = emb(s.recibidas, null, 'Solicitudes recibidas') + emb(s.agendadas, s.recibidas, 'Agendadas') + emb(c.atendidas, c.total, 'Citas atendidas') + emb(p.aceptados, p.enviados, 'Presupuestos aceptados') + (p.enviados ? `<div><span>Monto aceptado</span><b>${usd(p.monto_aceptado)} <small style="font:600 .8rem var(--fx-font-txt)">de ${usd(p.monto_enviado)}</small></b></div>` : '');
  barras('#g-doc', c.por_doctor.map(d => [d.doctor, d.citas, d.color, `${d.citas} (${d.atendidas} atendidas)`]));
  barras('#g-docing', k.por_doctor.map(d => [d.doctor, +d.ingresos, d.color, usd(d.ingresos)]));
  barras('#g-trat', c.por_tratamiento.map(t => [t.nombre, t.n, null, t.n]));
  barras('#g-dias', c.por_dia_semana.filter(d => d.dia < 7 || d.n).map(d => [DIAS[d.dia - 1], d.n, null, d.n]));
  barras('#g-franja', [['Mañana', c.por_franja.manana, null, c.por_franja.manana], ['Tarde', c.por_franja.tarde, null, c.por_franja.tarde]]);
  $('#g-seg').innerHTML = p.seguimientos.length ? p.seguimientos.map(x => `<li><span><b>${esc(x.paciente)}</b> · ${usd(x.total)}</span><span>Seguimiento: ${esc(fechaCorta(x.seguimiento))}${x.dias_vencido ? ` (hace ${x.dias_vencido} ${x.dias_vencido === 1 ? 'día' : 'días'})` : ' (hoy)'}</span></li>`).join('') : '<li style="background:#d7f0e2">Nada vencido: todos los presupuestos tienen respuesta o su seguimiento está al día.</li>';
}
function barras(sel, filas) {
  const m = Math.max(1, ...filas.map(f => f[1]));
  $(sel).innerHTML = filas.length ? filas.map(([n, v, col, txt]) => `<div class="hb-f"><span title="${esc(n)}">${esc(n)}</span><span class="p"><i style="width:${Math.max(2, v / m * 100)}%${col ? `;--c:${esc(col)}` : ''}"></i></span><b>${esc(txt)}</b></div>`).join('') : '<p class="vacio">Sin datos en este periodo.</p>';
}
function serie(s) {
  let datos = s; if (s.length > 62) { datos = []; for (let i = 0; i < s.length; i += 7) { const g = s.slice(i, i + 7); datos.push({ dia: g[0].dia, ing: g.reduce((q, x) => q + +x.ing, 0), egr: g.reduce((q, x) => q + +x.egr, 0) }); } }
  const W = 760, H = 230, pl = 46, pb = 26, pt = 10, n = datos.length, max = Math.max(1, ...datos.map(x => Math.max(+x.ing, +x.egr))), bw = (W - pl) / n, sc = v => (H - pb - pt) * (v / max);
  const marcas = [0, .5, 1].map(f => max * f);
  let g = marcas.map(v => `<line class="eje" x1="${pl}" x2="${W}" y1="${H - pb - sc(v)}" y2="${H - pb - sc(v)}"/><text x="${pl - 6}" y="${H - pb - sc(v) + 4}" text-anchor="end">${v >= 1000 ? Math.round(v / 100) / 10 + 'k' : Math.round(v)}</text>`).join('');
  datos.forEach((x, i) => { const bx = pl + i * bw + bw * .12, w = Math.max(1.5, bw * .38);
    g += `<rect x="${bx}" y="${H - pb - sc(+x.ing)}" width="${w}" height="${sc(+x.ing)}" rx="2" fill="var(--fx-deep)"><title>${esc(fechaCorta(x.dia))}: ingresos ${usd(x.ing)}</title></rect><rect x="${bx + w + 1}" y="${H - pb - sc(+x.egr)}" width="${w}" height="${sc(+x.egr)}" rx="2" fill="var(--fx-accent)"><title>${esc(fechaCorta(x.dia))}: egresos ${usd(x.egr)}</title></rect>`;
    if (n <= 12 || i % Math.ceil(n / 8) === 0) g += `<text x="${pl + i * bw + bw / 2}" y="${H - 8}" text-anchor="middle">${esc(x.dia.slice(8))}/${esc(x.dia.slice(5, 7))}</text>`; });
  const tot = datos.reduce((q, x) => q + +x.ing, 0);
  $('#g-serie').innerHTML = `<svg class="serie" viewBox="0 0 ${W} ${H}" role="img" aria-label="Ingresos y egresos por día. Ingresos del periodo: ${usd(tot)}">${g}</svg>`;
}

async function cargar(silencioso) {
  const er = $('#d-err'); er.textContent = '';
  if (!rango.d || !rango.h || rango.h < rango.d) { er.textContent = 'Elige un periodo válido: la fecha final no puede ser anterior a la inicial.'; return; }
  try { R = await C.rpc('dueno_resumen', { p_desde: rango.d, p_hasta: rango.h }); pintar(R);
    $('#r-txt').textContent = `Del ${fechaLarga(rango.d)} al ${fechaLarga(rango.h)}`; { const act = $('#r-act'); if (act) act.textContent = 'Actualizado ' + new Date().toLocaleTimeString('es-EC', { hour: '2-digit', minute: '2-digit', timeZone: CLUI.TZ }) + ' · se refresca solo cada minuto'; }
  } catch (e) { if (!silencioso) er.textContent = msgErr(e); }
}
function fijar(d, h) { rango = { d, h }; $('#r-desde').value = d; $('#r-hasta').value = h; $('#r-desde').max = $('#r-hasta').max = suma(hoy(), 30); cargar(); }
$$('#r-pre .cb').forEach(b => b.onclick = () => { $$('#r-pre .cb').forEach(x => x.setAttribute('aria-pressed', x === b)); fijar(...preset(b.dataset.p)); });
$('#r-ok').onclick = () => { $$('#r-pre .cb').forEach(x => x.setAttribute('aria-pressed', false)); rango = { d: $('#r-desde').value, h: $('#r-hasta').value }; cargar(); };
$('#r-print').onclick = () => window.print();
$('#r-csv').onclick = () => {
  if (!R) return; const f = [['Dia', 'Ingresos', 'Egresos'], ...R.caja.serie.map(x => [x.dia, x.ing, x.egr])];
  const resumen = [['Resumen', R.desde + ' a ' + R.hasta], ['Citas atendidas', R.citas.atendidas], ['No vinieron', R.citas.no_vino], ['Canceladas', R.citas.canceladas], ['Pacientes nuevos', R.pacientes.nuevos], ['Solicitudes recibidas', R.solicitudes.recibidas], ['Solicitudes agendadas', R.solicitudes.agendadas],
    ['Presupuestos enviados', R.presupuestos.enviados], ['Presupuestos aceptados', R.presupuestos.aceptados], ['Monto aceptado', R.presupuestos.monto_aceptado], [], ...f];
  const csv = resumen.map(r => r.map(v => `"${String(v ?? '').replace(/"/g, '""')}"`).join(',')).join('\n');
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' })); a.download = `reporte-${R.desde}_${R.hasta}.csv`; a.click(); URL.revokeObjectURL(a.href);
};

let iniciado = false;
function abrir() {
  if (!iniciado) { iniciado = true; const b = $('#r-pre .cb'); b.setAttribute('aria-pressed', true); fijar(...preset('mes')); clearInterval(timer);
    timer = setInterval(() => { if (!document.hidden && !$('#v-resumen').hidden) cargar(true); }, 60000); }
  else cargar(true);
}
window.CLPANEL.cargar['t-resumen'] = abrir;
})();
