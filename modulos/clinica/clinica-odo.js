/* clinica-odo.js · odontograma por superficies (modelo clínico de 5 caras por diente, numeración FDI). Lo usan la ficha del paciente (clinica-pacientes.js)
   y la demo (plantillas/clinica.html). No habla con la base: recibe las marcas y avisa qué se quiere guardar.
   Cada diente es un cuadrado con 5 superficies: O oclusal/incisal (centro), V vestibular, L lingual/palatina, M mesial, D distal. La vestibular queda hacia afuera del
   dibujo (arriba en la arcada superior, abajo en la inferior); mesial es el lado hacia la línea media.
   Marcas: un movimiento sin superficie (s = null) es del DIENTE COMPLETO; con superficie, solo esa cara. Una marca de diente completo posterior reemplaza las de cara anteriores.
   Dos tratamientos por diente: el diente completo tiene dos capas. La 1.ª (la de siempre) reemplaza todo lo anterior del diente; la 2.ª (capa 2) se suma a la 1.ª sin reemplazarla (endodoncia + corona). Una marca de capa 1 posterior vuelve a empezar el diente y retira la 2.ª.
   Estilos incluidos aquí (se inyectan una vez). Solo variables --fx-* con respaldo; los colores de estado clínico son semánticos.
   Uso: const od = CLODO.montar(elemento, { filas, escribir, superficies, temporales, nota, guardar: async (diente, cambios, nota) => {...}, msg: e => texto });
        od.actualizar(filas)  ·  filas = [{ id, diente, superficie|null, estado, nota, dia }] (el último estado de cada diente y de cada cara). */
(() => {
  const ESTADOS = [['sano', 'Sano', '#FFFFFF'], ['caries', 'Caries', '#C9435A'], ['resina', 'Resina', '#4A78C2'], ['endodoncia', 'Endodoncia', '#2E8B6F'], ['corona', 'Corona', '#E0A030'],
    ['brackets', 'Brackets', '#6B5BA8'], ['implante', 'Implante', '#17A2B8'], ['protesis', 'Prótesis', '#8D6E63'], ['ausente', 'Ausente', '#8E8F94']];
  const ESTADO = Object.fromEntries(ESTADOS.map(e => [e[0], e]));
  const POR_CARA = ['sano', 'caries', 'resina'];   // se marcan por superficie; los demás son del diente completo
  const SUP = [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28], INF = [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38];
  const TSUP = [55, 54, 53, 52, 51, 61, 62, 63, 64, 65], TINF = [85, 84, 83, 82, 81, 71, 72, 73, 74, 75];
  const CARA = { O: 'Oclusal / incisal', V: 'Vestibular', L: 'Lingual / palatina', M: 'Mesial', D: 'Distal' };
  const PTS = { top: '0,0 40,0 28,12 12,12', bottom: '0,40 40,40 28,28 12,28', left: '0,0 12,12 12,28 0,40', right: '40,0 40,40 28,28 28,12', c: '12,12 28,12 28,28 12,28' };
  const TXT = { top: [20, 7], bottom: [20, 36], left: [6, 21], right: [34, 21], c: [20, 21] };
  const esc = t => String(t ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const color = e => (ESTADO[e] || ESTADO.sano)[2];

  /* qué superficie queda en cada posición del dibujo según el cuadrante FDI (1,2,5,6 = arcada superior; 1,4,5,8 = lado derecho del paciente = izquierda del dibujo) */
  const mapa = n => { const q = Math.floor(n / 10), sup = [1, 2, 5, 6].includes(q), izq = [1, 4, 5, 8].includes(q);
    return { top: sup ? 'V' : 'L', bottom: sup ? 'L' : 'V', left: izq ? 'D' : 'M', right: izq ? 'M' : 'D', c: 'O' }; };

  /* filas (último estado por diente completo y por cara) → { diente: { todo, caras:{V,…} } } resolviendo el orden por id */
  function resolver(filas) {
    const r = {};
    (filas || []).slice().sort((a, b) => (a.id ?? 0) - (b.id ?? 0)).forEach(f => {
      const d = r[f.diente] || (r[f.diente] = { todo: null, todo2: null, caras: {} });
      if (!f.superficie && f.capa === 2) d.todo2 = f;
      else if (!f.superficie) { d.todo = f; d.todo2 = null; d.caras = {}; } else d.caras[f.superficie] = f;
    });
    return r;
  }
  const aplicar = (st, cola) => { const d = { todo: st ? st.todo : null, todo2: st ? st.todo2 : null, caras: Object.assign({}, st ? st.caras : {}) };
    (cola || []).forEach(c => { if (c.s === '*' && c.capa === 2) d.todo2 = { estado: c.e }; else if (c.s === '*') { d.todo = { estado: c.e }; d.todo2 = null; d.caras = {}; } else d.caras[c.s] = { estado: c.e }; }); return d; };
  const estadoCara = (st, s) => (st && ((st.caras[s] || {}).estado || (st.todo || {}).estado)) || 'sano';
  const resumen = st => { if (!st) return 'sin registro'; const p = [];
    if (st.todo && st.todo.estado !== 'sano') p.push(ESTADO[st.todo.estado][1] + ' (diente completo)');
    if (st.todo2 && st.todo2.estado !== 'sano') p.push(ESTADO[st.todo2.estado][1] + ' (2.º tratamiento del diente completo)');
    const por = {}; Object.entries(st.caras).forEach(([s, f]) => (por[f.estado] = por[f.estado] || []).push(CARA[s].split(' ')[0].toLowerCase()));
    Object.entries(por).forEach(([e, l]) => p.push(`${ESTADO[e][1].toLowerCase()} en ${l.join(', ')}`));
    return p.length ? p.join('; ') : 'sano'; };

  function svg(n, st, o) {
    o = o || {}; const m = mapa(n), ausente = !!(st && st.todo && st.todo.estado === 'ausente' && !Object.keys(st.caras).length);
    const polis = Object.entries(PTS).map(([pos, pts]) => { const s = m[pos], e = ausente ? 'sano' : estadoCara(st, s), fondo = ausente ? '#ECECEE' : color(e);
      const pend = o.cola && o.cola.some(c => c.s === s || c.s === '*');
      const base = `<polygon points="${pts}" fill="${fondo}" ${pend ? 'fill-opacity=".6"' : ''}${o.editor ? ` data-s="${s}" class="od-f"` : ''}/>`;
      if (!o.editor) return base;
      return `<g role="button" tabindex="0" class="od-fg" data-s="${s}" aria-label="${esc(CARA[s])}: ${esc(ESTADO[e][1])}${pend ? ' (cambio pendiente)' : ''}">${base}<text x="${TXT[pos][0]}" y="${TXT[pos][1]}" text-anchor="middle" dominant-baseline="central" class="od-l" fill="${['caries', 'brackets', 'protesis', 'implante', 'ausente', 'endodoncia'].includes(e) ? '#fff' : '#111'}">${s}</text></g>`; }).join('');
    const x = ausente ? '<path d="M3 3 37 37M37 3 3 37" stroke="#555" stroke-width="2" fill="none"/>' : '';
    const seg = st && st.todo2 && st.todo2.estado !== 'sano' && !ausente ? `<rect x="-.2" y="-.2" width="40.4" height="40.4" rx="3" fill="none" stroke="${color(st.todo2.estado)}" stroke-width="3.4"/>` : '';
    return `<svg viewBox="-1 -1 42 42" class="od-svg${o.editor ? ' od-grande' : ''}" aria-hidden="${o.editor ? 'false' : 'true'}" focusable="false">${polis}${x}${seg}</svg>`;
  }

  const CSS = `.od{--t:clamp(24px,calc((100vw - 64px)/17.5),50px);display:grid;gap:18px}
.od-cuadro{display:grid;gap:22px;justify-items:center;padding:16px 8px;border-radius:16px;background:#fff;border:1px solid color-mix(in srgb,var(--fx-ink,#111) 12%,transparent);overflow-x:auto}
.od-bloque{display:grid;gap:6px}
.od-fila{display:flex;gap:16px;justify-content:center}
.od-mitad{display:flex;gap:3px}
.od-d{width:var(--t);padding:0;border:0;background:none;display:grid;gap:3px;justify-items:center;cursor:pointer;color:var(--fx-ink,#111);font:600 calc(var(--t) * .36 + 1px)/1 var(--fx-font-txt,sans-serif);border-radius:6px}
.od-d .od-svg{width:100%;height:auto;display:block}
.od-d .od-svg polygon{stroke:var(--fx-ink,#111);stroke-width:1.4;stroke-linejoin:round}
.od-d[aria-pressed="true"]{outline:3px solid var(--fx-deep,#111);outline-offset:2px;background:color-mix(in srgb,var(--fx-accent,#c4c7cc) 30%,transparent)}
.od-d:focus-visible{outline:3px solid var(--fx-deep,#111);outline-offset:2px}
.od-d.pend .od-n::after{content:"•";color:#C9435A;margin-left:1px}
.od-inf .od-d{grid-template-rows:auto auto}
.od-tit{font:700 .8rem/1 var(--fx-font-txt,sans-serif);letter-spacing:.06em;text-transform:uppercase;color:color-mix(in srgb,var(--fx-ink,#111) 60%,#fff);text-align:center;margin-bottom:4px}
.od-ed{display:grid;gap:18px;grid-template-columns:minmax(0,230px) minmax(0,1fr);align-items:start;padding:18px;border-radius:16px;background:#fff;border:1px solid color-mix(in srgb,var(--fx-ink,#111) 12%,transparent)}
@media (max-width:640px){.od{--t:min(38px,calc((100vw - 72px)/8.6))}.od-fila{flex-direction:column;align-items:center;gap:12px}.od-ed{grid-template-columns:1fr}.od-grande{max-width:230px;margin-inline:auto}}
.od-grande{width:100%;height:auto;display:block}
.od-grande polygon{stroke:var(--fx-ink,#111);stroke-width:.9;stroke-linejoin:round;cursor:pointer;transition:opacity .15s}
.od-fg{outline:none}.od-fg:focus-visible polygon{stroke:var(--fx-deep,#111);stroke-width:2.2}
@media (hover:hover){.od-fg:hover polygon{opacity:.8}}
.od-l{font:700 6px var(--fx-font-txt,sans-serif);pointer-events:none}
.od-ed h3{font:800 1.3rem/1.1 var(--fx-font-disp,sans-serif);letter-spacing:-.01em;margin:0 0 4px;text-transform:none}
.od-caras{list-style:none;margin:8px 0 0;padding:0;display:grid;gap:4px;font:500 .92rem/1.3 var(--fx-font-txt,sans-serif)}
.od-caras li{display:flex;gap:8px;align-items:center}.od-caras i{width:12px;height:12px;border-radius:3px;border:1px solid rgba(0,0,0,.35);flex:none;background:var(--c)}
.od-ayuda{font:400 .85rem/1.4 var(--fx-font-txt,sans-serif);color:color-mix(in srgb,var(--fx-ink,#111) 65%,#fff);margin:8px 0 0}
.od-acc{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px;align-items:end}
.od-acc .campo{flex:1 1 200px;margin:0}
.od-err{min-height:1.2em;margin:8px 0 0;color:#B3261E;font:600 .9rem var(--fx-font-txt,sans-serif)}
.od-seg{display:flex;align-items:center;gap:8px;margin:0;font:600 .9rem/1.3 var(--fx-font-txt,sans-serif)}.od-seg input{width:20px;height:20px}
.od-pend{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:12px 14px;border-radius:14px;background:color-mix(in srgb,var(--fx-accent,#c4c7cc) 22%,#fff);border:1px dashed color-mix(in srgb,var(--fx-ink,#111) 35%,transparent)}
.od-pend[hidden]{display:none}.od-pend>b{font:800 .92rem var(--fx-font-txt,sans-serif);margin-right:4px}
.od-pend .od-chip{min-height:36px;padding:0 12px;border-radius:999px;border:1.5px solid var(--fx-ink,#111);background:#fff;color:var(--fx-ink,#111);font:700 .84rem var(--fx-font-txt,sans-serif);cursor:pointer}
.od-pend .btn{min-height:40px;padding:0 16px;font-size:.9rem;margin-left:auto}
.od-aviso{padding:10px 14px;border-radius:12px;background:var(--fx-marca-bg,#fff3c4);color:var(--fx-marca-ink,#5a3b00);font:600 .88rem/1.4 var(--fx-font-txt,sans-serif)}
@media (prefers-reduced-motion:reduce){.od-grande polygon{transition:none}}`;
  const inyectar = () => { if (!document.getElementById('od-css')) { const s = document.createElement('style'); s.id = 'od-css'; s.textContent = CSS; document.head.append(s); } };

  function montar(raiz, op) {
    inyectar();
    op = Object.assign({ filas: [], escribir: true, superficies: true, temporales: false, nota: true, aviso: '', msg: e => (e && e.message) || String(e) }, op);
    let filas = op.filas, sel = 16, selE = 'caries', temp = op.temporales, nota = '', err = '', cola = {}, enviando = false, seg = false;
    const avisa = () => { if (op.alCambiar) op.alCambiar(); };
    const hayCola = () => Object.keys(cola).filter(n => (cola[n] || []).length);
    const q = (s, r) => (r || raiz).querySelector(s), qq = (s, r) => [...(r || raiz).querySelectorAll(s)];

    const diente = (n, st, arriba) => { const c = cola[n] || [], v = aplicar(st, c);
      return `<button type="button" class="od-d${c.length ? ' pend' : ''}" data-n="${n}" aria-pressed="${n === sel}" aria-label="Diente ${n}: ${esc(resumen(aplicar(st, c)))}${c.length ? ' (cambios sin guardar)' : ''}">${arriba ? `<span class="od-n">${n}</span>${svg(n, v)}` : `${svg(n, v)}<span class="od-n">${n}</span>`}</button>`; };
    const arco = (a, R, arriba) => { const h = a.length / 2; return `<div class="od-fila ${arriba ? 'od-sup' : 'od-inf'}"><div class="od-mitad">${a.slice(0, h).map(n => diente(n, R[n], arriba)).join('')}</div><div class="od-mitad">${a.slice(h).map(n => diente(n, R[n], arriba)).join('')}</div></div>`; };

    function pintar() {
      const R = resolver(filas), st = R[sel], v = aplicar(st, cola[sel]), cl = cola[sel] || [], porCara = op.superficies && POR_CARA.includes(selE);
      raiz.classList.add('od');
      raiz.innerHTML = `${op.aviso ? `<p class="od-aviso">${esc(op.aviso)}</p>` : ''}
        <div class="ctrl no-print"><button type="button" class="cb" id="od-temp" aria-pressed="${temp}">Dientes temporales (niños)</button></div>
        <div class="od-cuadro" role="group" aria-label="Odontograma, numeración FDI">
          <div class="od-bloque"><p class="od-tit">Dientes permanentes</p>${arco(SUP, R, true)}${arco(INF, R, false)}</div>
          ${temp ? `<div class="od-bloque"><p class="od-tit">Dientes temporales</p>${arco(TSUP, R, true)}${arco(TINF, R, false)}</div>` : ''}
        </div>
        <div class="estados no-print" id="od-estados" role="group" aria-label="Estado que vas a marcar">${ESTADOS.map(([k, n, c]) => `<button type="button" class="cb" data-e="${k}" aria-pressed="${k === selE}"><i style="--c:${c}"></i>${n}</button>`).join('')}</div>
        <label class="od-seg no-print"><input type="checkbox" id="od-seg" ${seg ? 'checked' : ''}><span>Es el <b>2.º tratamiento</b> de este diente (se suma al primero, no lo reemplaza)</span></label>
        <div class="od-pend no-print" id="od-pend" role="status" ${hayCola().length ? '' : 'hidden'}><b>Por guardar:</b>${hayCola().map(n => `<button type="button" class="od-chip" data-pn="${n}">${n} · ${cola[n].length} ${cola[n].length === 1 ? 'cambio' : 'cambios'}</button>`).join('')}<button type="button" class="btn" id="od-guardar-todo" ${op.escribir && !enviando ? '' : 'disabled'}>${enviando ? 'Guardando…' : `Guardar todo (${hayCola().reduce((t, n) => t + cola[n].length, 0)})`}</button></div>
        <div class="od-ed">
          <div>${svg(sel, v, { editor: true, cola: cl })}</div>
          <div>
            <h3>Diente ${sel}</h3>
            <p class="od-ayuda" style="margin-top:0">${esc(resumen(v))}${st && st.todo && st.todo.dia ? ` · último registro ${esc(st.todo.dia)}` : ''}</p>
            <ul class="od-caras">${Object.entries(CARA).map(([s, nom]) => `<li><i style="--c:${color(estadoCara(v, s))}"></i><b>${s}</b> ${nom}: ${esc(ESTADO[estadoCara(v, s)][1])}${cl.some(c => c.s === s || c.s === '*') ? ' · <em>sin guardar</em>' : ''}</li>`).join('')}</ul>
            <p class="od-ayuda no-print">${op.superficies ? (porCara ? `Toca una superficie del diente para marcarla como <b>${esc(ESTADO[selE][1].toLowerCase())}</b>.` : `<b>${esc(ESTADO[selE][1])}</b> es del diente completo: toca cualquier superficie para aplicarlo.`) : `Marca el diente completo: toca cualquier superficie. (Para marcar por superficie falta actualizar la base de datos con la migración 011.)`} Se guarda con el botón; cada cambio queda en el historial.</p>
            <div class="od-acc no-print">
              ${op.nota ? `<div class="campo"><label for="od-nota">Nota (opcional)</label><input id="od-nota" maxlength="200" value="${esc(nota)}" placeholder="ej.: lesión cervical, revisar en el control"></div>` : ''}
              ${porCara ? '<button type="button" class="btn btn-linea" id="od-todo">Todo el diente</button>' : ''}
              <button type="button" class="btn btn-linea" id="od-deshacer" ${cl.length ? '' : 'disabled'}>Deshacer</button>
              <button type="button" class="btn" id="od-guardar" ${cl.length && op.escribir && !enviando ? '' : 'disabled'}>${enviando ? 'Guardando…' : cl.length ? `Guardar ${cl.length} ${cl.length === 1 ? 'cambio' : 'cambios'}` : 'Guardar'}</button>
            </div>
            <p class="od-err" id="od-err" role="alert">${esc(err)}</p>
          </div>
        </div>`;
      qq('.od-d').forEach(b => b.onclick = () => { sel = +b.dataset.n; err = ''; pintar(); if (op.alElegir) op.alElegir(sel); q(`.od-d[data-n="${sel}"]`).focus(); });
      qq('#od-estados .cb').forEach(b => b.onclick = () => { selE = b.dataset.e; pintar(); });
      q('#od-temp').onclick = () => { temp = !temp; pintar(); };
      const tocar = g => marca(op.superficies && POR_CARA.includes(selE) ? g.dataset.s : '*');
      qq('.od-fg').forEach(g => { g.onclick = () => tocar(g); g.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); tocar(g); } }; });
      const t = q('#od-todo'); if (t) t.onclick = () => marca('*');
      q('#od-seg').onchange = e => { seg = e.target.checked; };
      qq('[data-pn]').forEach(b => b.onclick = () => { sel = +b.dataset.pn; pintar(); if (op.alElegir) op.alElegir(sel); });
      const gt = q('#od-guardar-todo'); if (gt) gt.onclick = () => guardarTodo();
      q('#od-deshacer').onclick = () => { cola[sel] = []; err = ''; pintar(); avisa(); };
      const i = q('#od-nota'); if (i) i.oninput = () => { nota = i.value; };
      q('#od-guardar').onclick = guardar;
    }
    function marca(s) {   // una cara se marca una vez (la nueva reemplaza a la anterior de esa cara); el diente completo reemplaza todo lo pendiente
      const c = s === '*' ? (seg ? (cola[sel] || []).filter(x => !(x.s === '*' && x.capa === 2)) : []) : (cola[sel] || []).filter(x => x.s !== s);
      c.push({ s, e: selE, capa: s === '*' && seg ? 2 : 1 }); cola[sel] = c; err = ''; pintar(); avisa(); const g = s === '*' ? null : q(`.od-fg[data-s="${s}"]`); if (g) g.focus();
    }
    async function guardar() {
      const cl = cola[sel] || []; if (!cl.length || enviando) return;
      enviando = true; err = ''; pintar();
      try { await op.guardar(sel, cl.map(c => ({ superficie: c.s === '*' ? null : c.s, estado: c.e, capa: c.capa || 1 })), nota.trim()); cola[sel] = []; nota = ''; }
      catch (e) { err = op.msg(e); }
      enviando = false; pintar(); avisa();
    }
    async function guardarTodo() {   // guarda, diente por diente y en orden, todo lo que quedó por guardar; si uno falla se detiene y lo demás sigue pendiente
      if (enviando) return true;
      enviando = true; err = ''; pintar();
      let ok = true;
      for (const n of hayCola()) {
        try { await op.guardar(+n, cola[n].map(c => ({ superficie: c.s === '*' ? null : c.s, estado: c.e, capa: c.capa || 1 })), nota.trim()); cola[n] = []; }
        catch (e) { err = `Diente ${n}: ${op.msg(e)}`; ok = false; break; }
      }
      if (ok) nota = '';
      enviando = false; pintar(); avisa(); return ok;
    }
    pintar();
    return { actualizar(f) { filas = f || []; pintar(); }, seleccionar(n) { sel = n; pintar(); }, diente: () => sel, guardarTodo,
      pendientes: () => hayCola().flatMap(n => cola[n].map(c => ({ diente: +n, superficie: c.s === '*' ? null : c.s, estado: c.e, capa: c.capa || 1 }))) };
  }

  window.CLODO = { ESTADOS, ESTADO, POR_CARA, CARA, SUP, INF, TSUP, TINF, mapa, resolver, aplicar, resumen, svg, montar };
})();
