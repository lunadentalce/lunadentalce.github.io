/* Motor de pedido · nivel 1 (Esencial): carta → carrito → para llevar / a domicilio → WhatsApp prellenado.
   Sin base de datos. Guarda una copia de prueba en el navegador para el panel de la demo (nivel 2 simulado).
   Requiere: config.js (window.DEMO) y menu.js (window.MENU). Uso: Pedido.pintarCarta('#carta') */
(() => {
  const D = window.DEMO, M = window.MENU;
  const $ = (s, r = document) => r.querySelector(s);
  const esc = t => String(t ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const R = D.modo === 'reserva';   // opt-in (spa, clínicas): sin para llevar/domicilio; reserva por WhatsApp con día y franja
  const CL = R && D.clinica && window.CLINICA ? window.CLINICA : null;   // clínica con base: la solicitud se guarda (solicitar_cita) y luego sale por WhatsApp
  const plata = c => (R && !c) ? 'A consultar' : '$' + (c / 100).toFixed(2);
  const wa = (n, t) => `https://wa.me/${String(n).replace(/\D/g, '')}?text=${encodeURIComponent(t)}`;
  const marca = t => `<span class="pd-marca">[CONFIRMAR${t ? ': ' + esc(t) : ''}]</span>`;

  const items = new Map(), extras = new Map(M.extras.map(e => [e.id, e]));
  M.categorias.forEach(c => c.items.forEach(i => items.set(i.id, { ...i, conExtras: c.extras })));

  const carrito = [];           // { id, extras: [ids], cant }
  const datos = { tipo: R ? 'reserva' : '', dia: '', franja: 'Mañana', nombre: '', telefono: '', menor: false, representante: '', consentimiento: false, retiro: 'Lo antes posible', direccion: '', referencia: '', ubicacion: '', nota: '', sector: '', cuando: 'ahora', hora: '' };
  /* Nivel 3 (Premium): la página activa D.sectores (envío por sector) y D.programar (pedido para más tarde). */
  const sectores = () => Array.isArray(D.sectores) ? D.sectores : null;
  const envioActual = () => {
    if (datos.tipo !== 'domicilio') return 0;
    const sc = sectores(); if (sc) { const x = sc.find(z => z.nombre === datos.sector); return x ? x.costo : null; }
    return D.envio;
  };
  const precioLinea = l => (items.get(l.id).precio + l.extras.reduce((s, x) => s + extras.get(x).precio, 0)) * l.cant;
  const subtotal = () => carrito.reduce((s, l) => s + precioLinea(l), 0);
  const unidades = () => carrito.reduce((s, l) => s + l.cant, 0);

  /* ---------- Carta ---------- */
  const itemHtml = (i, c) => `
              <li class="pd-item${i.foto ? ' con-foto' : ''}">
                ${i.foto ? `<img class="pd-foto" src="${esc(i.foto.src)}" alt="${esc(i.foto.alt)}" width="${esc(i.foto.w)}" height="${esc(i.foto.h)}" loading="lazy">` : ''}
                <div class="pd-info">
                  <h3>${esc(i.nombre)}</h3>
                  ${i.lema ? `<p class="pd-lema">${esc(i.lema)}</p>` : ''}
                  <p class="pd-desc">${i.desc ? esc(i.desc) : c.extras ? marca('ingredientes') : ''}${i.confirmar ? ' ' + marca(i.confirmar) : ''}</p>
                </div>
                <div class="pd-acc">
                  <span class="pd-precio">${plata(i.precio)}</span>
                  <button type="button" class="pd-btn pd-btn-add" data-add="${i.id}" aria-label="Agregar ${esc(i.nombre)}">Agregar</button>
                </div>
              </li>`;
  const temporadaHtml = t => t ? `<div class="pd-temporada${t.foto ? ' con-foto' : ''}" data-reveal>
        ${t.foto ? `<img src="${esc(t.foto)}" alt="${esc(t.alt || t.nombre)}" width="${esc(t.fotoW)}" height="${esc(t.fotoH)}" loading="lazy">` : ''}
        <div><span class="pd-sello">${esc(t.nota)}</span>
        <h3>${esc(t.nombre)}</h3>
        <p>${marca(t.confirmar)}</p></div>
      </div>` : '';
  const titulo = c => `<h2 id="cat-${c.id}"><span class="fino">${esc(c.antes || 'Carta')}</span> <span class="grueso">${esc(c.nombre)}</span></h2>`;

  function pintarCarta(sel) {
    const raiz = $(sel);
    if (M.vista === 'pestanas') pintarPestanas(raiz);
    else raiz.innerHTML = `
      ${temporadaHtml(M.temporada)}
      ${M.categorias.map(c => `
        <section class="pd-cat" aria-labelledby="cat-${c.id}">
          ${titulo(c)}
          <ul class="pd-lista" data-stagger>${c.items.map(i => itemHtml(i, c)).join('')}
          </ul>
        </section>`).join('')}`;
    raiz.addEventListener('click', e => {
      const b = e.target.closest('[data-add]'); if (!b) return;
      const it = items.get(b.dataset.add);
      it.conExtras ? abrirExtras(it) : agregar(it.id, []);
    });
    montarBarra();
  }

  /* Carta larga: menu.vista = "pestanas" → una categoría a la vez, pestaña inicial con los platos marcados destacado:true y buscador */
  function pintarPestanas(raiz) {
    const plano = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
    const dest = M.categorias.flatMap(c => c.items.filter(i => i.destacado).map(i => ({ i, c })));
    const tabs = [...(dest.length ? [{ id: 'destacados', nombre: M.destacados || 'Especialidades', antes: 'La casa recomienda', lista: dest, estrella: true }] : []),
      ...M.categorias.map(c => ({ ...c, lista: c.items.map(i => ({ i, c })) }))];
    let activa = tabs[0].id, q = '';
    raiz.innerHTML = `${temporadaHtml(M.temporada)}
      <div class="pd-barra-carta">
        <label class="pd-buscar"><span class="pd-solo-lector">Buscar un plato</span><input type="search" id="pd-buscar" placeholder="Buscar un plato (ej. camarón, sopa, arroz)" autocomplete="off"></label>
        <div class="pd-tabs" role="tablist" aria-label="Categorías de la carta">${tabs.map(t => `<button type="button" role="tab" class="pd-tab" data-tab="${t.id}">${t.estrella ? '★ ' : ''}${esc(t.nombre)}</button>`).join('')}</div>
      </div>
      <section class="pd-cat" id="pd-panel" aria-live="polite"></section>`;
    const panel = $('#pd-panel', raiz), tabsEl = $('.pd-tabs', raiz);
    const pintar = (subir) => {
      const hay = q.trim();
      tabsEl.querySelectorAll('.pd-tab').forEach(b => { const on = !hay && b.dataset.tab === activa; b.classList.toggle('on', on); b.setAttribute('aria-selected', on); if (on) tabsEl.scrollTo({ left: b.offsetLeft - 16, behavior: 'smooth' }); });
      if (hay) {
        const k = plano(hay), r = M.categorias.flatMap(c => c.items.filter(i => plano(i.nombre + ' ' + (i.desc || '')).includes(k)).map(i => ({ i, c })));
        panel.innerHTML = `<h2 class="pd-res"><span class="grueso">${r.length ? r.length + (r.length === 1 ? ' plato' : ' platos') : 'Sin resultados'}</span></h2>` +
          (r.length ? `<ul class="pd-lista pd-in">${r.map(x => itemHtml(x.i, x.c)).join('')}</ul>` : `<p class="pd-vacio">No encontramos ese plato. Prueba con otra palabra o elige una categoría.</p>`);
      } else {
        const t = tabs.find(x => x.id === activa);
        panel.innerHTML = `${titulo(t)}<ul class="pd-lista pd-in">${t.lista.map(x => itemHtml(x.i, x.c)).join('')}</ul>`;
      }
      if (subir) { const top = raiz.getBoundingClientRect().top; if (top < 0) raiz.scrollIntoView({ block: 'start' }); }
    };
    tabsEl.addEventListener('click', e => { const b = e.target.closest('[data-tab]'); if (!b) return; activa = b.dataset.tab; q = ''; $('#pd-buscar', raiz).value = ''; pintar(true); });
    $('#pd-buscar', raiz).addEventListener('input', e => { q = e.target.value; pintar(false); });
    pintar(false);
  }

  function abrirProducto(id) {
    const it = items.get(id); if (!it) return;
    it.conExtras ? abrirExtras(it) : agregar(it.id, []);
  }

  function agregar(id, xs) {
    const clave = id + '|' + [...xs].sort().join(',');
    const l = carrito.find(l => l.id + '|' + [...l.extras].sort().join(',') === clave);
    l ? l.cant++ : carrito.push({ id, extras: xs, cant: 1 });
    montarBarra(); actualizarBarra(true);
  }

  /* ---------- Hoja (dialog nativo: foco atrapado y Esc incluidos) ---------- */
  let hoja;
  function abrirHoja(html, alPintar) {
    if (!hoja) {
      hoja = document.createElement('dialog'); hoja.className = 'pd-hoja'; hoja.setAttribute('data-lenis-prevent', '');
      hoja.addEventListener('click', e => { if (e.target === hoja) hoja.close(); });
      document.body.append(hoja);
    }
    hoja.innerHTML = `<button type="button" class="pd-cerrar" aria-label="Cerrar">×</button>${html}`;
    $('.pd-cerrar', hoja).onclick = () => hoja.close();
    if (!hoja.open) hoja.showModal();
    alPintar && alPintar(hoja);
  }

  function abrirExtras(it) {
    const sel = new Set();
    const total = () => it.precio + [...sel].reduce((s, x) => s + extras.get(x).precio, 0);
    abrirHoja(`
      <h2 class="pd-hoja-tit">${esc(it.nombre)}</h2>
      <p class="pd-sub">¿Le subimos el nivel? Extras opcionales</p>
      <div class="pd-extras">${M.extras.map(x => `
        <label class="pd-chip"><input type="checkbox" value="${x.id}"><span>${esc(x.nombre)} <b>+${plata(x.precio)}</b></span></label>`).join('')}
      </div>
      <button type="button" class="pd-btn pd-btn-full" id="pd-ok">Agregar · <span id="pd-tot">${plata(it.precio)}</span></button>`,
      h => {
        h.querySelectorAll('input').forEach(c => c.onchange = () => { c.checked ? sel.add(c.value) : sel.delete(c.value); $('#pd-tot', h).textContent = plata(total()); });
        $('#pd-ok', h).onclick = () => { agregar(it.id, [...sel]); h.close(); };
      });
  }

  /* ---------- Barra fija inferior ---------- */
  let barra;
  function montarBarra() {
    if (barra) return;
    barra = document.createElement('div'); barra.className = 'pd-barra'; barra.hidden = true;
    barra.innerHTML = `<button type="button" class="pd-btn pd-btn-full" id="pd-ver">
      <span class="pd-cuenta" aria-live="polite"></span><span>${R ? 'Ver reserva' : 'Ver pedido'}</span>${R ? '' : '<span class="pd-sum"></span>'}</button>`;
    document.body.append(barra);
    $('#pd-ver').onclick = abrirPedido;
  }
  function actualizarBarra(salto) {
    barra.hidden = !carrito.length;
    $('.pd-cuenta', barra).textContent = unidades();
    const sm = $('.pd-sum', barra); if (sm) sm.textContent = plata(subtotal());
    if (salto) { const c = $('.pd-cuenta', barra); c.classList.remove('pd-salto'); void c.offsetWidth; c.classList.add('pd-salto'); }
  }

  /* ---------- Revisar pedido + tipo + datos ---------- */
  function abrirPedido() {
    const hayDom = D.domicilio !== false;
    const lineas = carrito.map((l, n) => {
      const it = items.get(l.id);
      return `<li class="pd-linea">
        <div><b>${esc(it.nombre)}</b>${l.extras.length ? `<small>+ ${l.extras.map(x => esc(extras.get(x).nombre)).join(', ')}</small>` : ''}</div>
        <div class="pd-cant">
          <button type="button" class="pd-mini" data-menos="${n}" aria-label="Quitar uno de ${esc(it.nombre)}">−</button>
          <span>${l.cant}</span>
          <button type="button" class="pd-mini" data-mas="${n}" aria-label="Sumar uno de ${esc(it.nombre)}">+</button>
        </div>
        <span class="pd-precio">${plata(precioLinea(l))}</span></li>`;
    }).join('');
    abrirHoja(`
      <h2 class="pd-hoja-tit">${R ? 'Tu reserva' : 'Tu pedido'}</h2>
      <ul class="pd-lineas">${lineas}</ul>
      ${R ? '' : `<p class="pd-subtotal">Subtotal <b>${plata(subtotal())}</b></p>`}
      <div id="pd-totales"></div>

      ${R ? '' : `<fieldset class="pd-tipo"><legend>¿Cómo lo quieres?</legend>
        <label class="pd-op"><input type="radio" name="tipo" value="llevar" ${datos.tipo === 'llevar' ? 'checked' : ''}><span>Para llevar<small>Retiras en el local</small></span></label>
        ${hayDom ? `<label class="pd-op"><input type="radio" name="tipo" value="domicilio" ${datos.tipo === 'domicilio' ? 'checked' : ''}><span>A domicilio<small>${D.envio == null ? 'Envío por confirmar' : 'Envío ' + plata(D.envio)}${D.domicilio === 'confirmar' ? ' ' + marca('¿hace domicilio?') : ''}</small></span></label>` : ''}
      </fieldset>`}

      <div class="pd-campos" id="pd-campos"></div>
      <p class="pd-error" id="pd-error" role="alert"></p>
      <button type="button" class="pd-btn pd-btn-full" id="pd-enviar">${R ? 'Reservar por WhatsApp' : 'Enviar pedido por WhatsApp'}</button>`,
      h => {
        h.querySelectorAll('[data-mas]').forEach(b => b.onclick = () => { carrito[b.dataset.mas].cant++; actualizarBarra(); abrirPedido(); });
        h.querySelectorAll('[data-menos]').forEach(b => b.onclick = () => {
          const l = carrito[b.dataset.menos]; l.cant--; if (!l.cant) carrito.splice(b.dataset.menos, 1);
          actualizarBarra(); carrito.length ? abrirPedido() : h.close();
        });
        h.querySelectorAll('input[name=tipo]').forEach(r => r.onchange = () => { datos.tipo = r.value; pintarCampos(h); pintarTotales(h); });
        pintarCampos(h);
        $('#pd-enviar', h).onclick = () => enviar(h);
      });
  }

  function pintarTotales(h) {
    const c = $('#pd-totales', h); if (!c) return;
    const e = envioActual();
    if (datos.tipo !== 'domicilio' || !sectores()) { c.innerHTML = ''; return; }
    c.innerHTML = `<p class="pd-fila">Envío${datos.sector ? ' a ' + esc(datos.sector) : ''} <b>${e == null ? 'elige tu sector' : plata(e)}</b></p>
      <p class="pd-subtotal pd-total">Total <b>${e == null ? '—' : plata(subtotal() + e)}</b></p>`;
  }

  function campo(id, etiqueta, extra = '') {
    return `<label class="pd-campo"><span>${etiqueta}</span><input id="pd-${id}" value="${esc(datos[id])}" ${extra}></label>`;
  }
  function pintarCampos(h) {
    const c = $('#pd-campos', h);
    if (!datos.tipo) { c.innerHTML = ''; return; }
    if (CL) {
      const hoy = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Guayaquil' });
      c.innerHTML = campo('nombre', 'Nombre y apellido del paciente', 'autocomplete="name" maxlength="80" required') +
        campo('telefono', 'Tu celular (para confirmar la cita)', 'type="tel" inputmode="tel" autocomplete="tel" placeholder="09xxxxxxxx" maxlength="14" required') +
        campo('dia', '¿Qué día prefieres?', `type="date" min="${hoy}" required`) +
        `<label class="pd-campo"><span>Horario preferido</span><select id="pd-franja">${[['Mañana', 'Mañana'], ['Tarde', 'Tarde'], ['Cualquiera', 'Cualquier horario']].map(([v, t]) => `<option value="${v}" ${v === datos.franja ? 'selected' : ''}>${t}</option>`).join('')}</select></label>` +
        `<label class="pd-chk"><input type="checkbox" id="pd-menor" ${datos.menor ? 'checked' : ''}><span>La cita es para un menor de edad</span></label>` +
        (datos.menor ? campo('representante', 'Nombre de quien autoriza (madre, padre o representante)', 'autocomplete="off" maxlength="80" required') : '') +
        campo('nota', 'Nota (opcional)', 'maxlength="140" placeholder="Algo que debamos saber"') +
        `<label class="pd-chk"><input type="checkbox" id="pd-consent" ${datos.consentimiento ? 'checked' : ''}><span>${esc(D.clinica.consentimiento || 'Acepto que se usen mis datos para gestionar mi cita.')} <a href="${esc(D.clinica.privacidad || 'privacidad.html')}" target="_blank" rel="noopener">Política de privacidad</a></span></label>`;
      c.querySelectorAll('input:not([type=checkbox]), select').forEach(i => i.oninput = i.onchange = () => { datos[i.id.slice(3)] = i.value.trim(); });
      $('#pd-menor', c).onchange = e => { datos.menor = e.target.checked; if (!datos.menor) datos.representante = ''; pintarCampos(h); };
      $('#pd-consent', c).onchange = e => { datos.consentimiento = e.target.checked; };
      return;
    }
    if (R) {
      c.innerHTML = campo('nombre', 'Tu nombre', 'autocomplete="given-name" required') +
        campo('dia', '¿Qué día prefieres?', 'placeholder="Ej.: viernes o la próxima semana"') +
        `<label class="pd-campo"><span>Horario preferido</span><select id="pd-franja">${['Mañana', 'Tarde', 'Noche'].map(o => `<option ${o === datos.franja ? 'selected' : ''}>${o}</option>`).join('')}</select></label>` +
        campo('nota', 'Nota (opcional)', 'placeholder="Algo que debamos saber"');
      c.querySelectorAll('input, select').forEach(i => i.oninput = i.onchange = () => { datos[i.id.slice(3)] = i.value.trim(); });
      return;
    }
    c.innerHTML = campo('nombre', 'Tu nombre', 'autocomplete="given-name" required') +
      (datos.tipo === 'llevar'
        ? `<label class="pd-campo"><span>¿Cuándo pasas?</span><select id="pd-retiro">${['Lo antes posible', 'En 30 minutos', 'En 1 hora'].map(o => `<option ${o === datos.retiro ? 'selected' : ''}>${o}</option>`).join('')}</select></label>`
        : (sectores() ? `<label class="pd-campo"><span>Sector</span><select id="pd-sector"><option value="">Elige tu sector</option>${sectores().map(z => `<option ${z.nombre === datos.sector ? 'selected' : ''} value="${esc(z.nombre)}">${esc(z.nombre)} · envío ${plata(z.costo)}</option>`).join('')}</select></label>` : '') +
          campo('direccion', 'Dirección', 'autocomplete="street-address" required') +
          campo('referencia', 'Referencia (casa, color, junto a…)') +
          `<button type="button" class="pd-btn pd-btn-sec" id="pd-ubi">${datos.ubicacion ? 'Ubicación agregada ✓' : 'Usar mi ubicación'}</button><p class="pd-sub" id="pd-ubi-estado"></p>`) +
      (D.programar ? `<fieldset class="pd-tipo pd-cuando"><legend>¿Para cuándo?</legend>
        <label class="pd-op"><input type="radio" name="cuando" value="ahora" ${datos.cuando === 'ahora' ? 'checked' : ''}><span>Ahora<small>Lo preparamos ya</small></span></label>
        <label class="pd-op"><input type="radio" name="cuando" value="programar" ${datos.cuando === 'programar' ? 'checked' : ''}><span>Más tarde<small>Tú eliges la hora</small></span></label></fieldset>
        ${datos.cuando === 'programar' ? `<label class="pd-campo"><span>Hora</span><input id="pd-hora" type="time" value="${esc(datos.hora)}" required></label>` : ''}` : '') +
      campo('nota', 'Nota para la cocina (opcional)', 'placeholder="Sin cebolla, salsa aparte…"');
    c.querySelectorAll('input:not([type=radio]), select').forEach(i => i.oninput = i.onchange = () => { datos[i.id.slice(3)] = i.value.trim(); if (i.id === 'pd-sector') pintarTotales(h); });
    c.querySelectorAll('input[name=cuando]').forEach(r => r.onchange = () => { datos.cuando = r.value; pintarCampos(h); });
    const u = $('#pd-ubi', h); if (u) u.onclick = () => ubicar(h);
  }

  function ubicar(h) {
    const est = $('#pd-ubi-estado', h);
    if (!navigator.geolocation) { est.textContent = 'Tu navegador no comparte ubicación. Escribe una referencia clara.'; return; }
    est.textContent = 'Buscando tu ubicación…';
    navigator.geolocation.getCurrentPosition(
      p => { datos.ubicacion = `https://maps.google.com/?q=${p.coords.latitude.toFixed(6)},${p.coords.longitude.toFixed(6)}`; est.textContent = 'Listo: el repartidor recibirá el punto en el mapa.'; $('#pd-ubi', h).textContent = 'Ubicación agregada ✓'; },
      () => { est.textContent = 'No se pudo obtener la ubicación. Revisa el permiso del navegador o escribe una referencia.'; },
      { enableHighAccuracy: true, timeout: 10000 });
  }

  function mensaje() {
    if (CL) return [D.saludoPedido || `Hola ${D.cliente}, quiero reservar desde la web`, '',
      ...carrito.map(l => `${l.cant} × ${items.get(l.id).nombre}`), '',
      `Paciente: ${datos.nombre}`, datos.menor ? `Autoriza: ${datos.representante}` : null, `Celular: ${datos.telefono}`,
      `Día preferido: ${new Date(datos.dia + 'T12:00:00Z').toLocaleDateString('es-EC', { weekday: 'long', day: 'numeric', month: 'long', timeZone: 'UTC' })}`, `Horario preferido: ${datos.franja}`,
      datos.nota ? `Nota: ${datos.nota}` : null, datos.ref ? `Solicitud N.º ${datos.ref}` : null].filter(x => x !== null).join('\n');
    if (R) return [D.saludoPedido || `Hola ${D.cliente}, quiero reservar desde la web`, '',
      ...carrito.map(l => `${l.cant} × ${items.get(l.id).nombre}`), '',
      `Nombre: ${datos.nombre}`, datos.dia ? `Día preferido: ${datos.dia}` : null, `Horario preferido: ${datos.franja}`,
      datos.nota ? `Nota: ${datos.nota}` : null].filter(x => x !== null).join('\n');
    const l = carrito.map(l => {
      const it = items.get(l.id);
      return `${l.cant} × ${it.nombre} — ${plata(precioLinea(l))}` + (l.extras.length ? `\n   + ${l.extras.map(x => extras.get(x).nombre).join(', ')}` : '');
    }).join('\n');
    const dom = datos.tipo === 'domicilio', e = envioActual();
    const cuenta = !dom ? `Total: ${plata(subtotal())}`
      : e == null ? `Subtotal: ${plata(subtotal())} + envío por confirmar`
      : `Subtotal: ${plata(subtotal())} + envío ${plata(e)} = Total: ${plata(subtotal() + e)}`;
    return [
      D.saludoPedido || `Hola ${D.cliente}, quiero hacer un pedido desde la web`, '', l, '',
      cuenta,
      `Tipo: ${dom ? 'A domicilio' : 'Para llevar'}`,
      D.programar && datos.cuando === 'programar' ? `Programado para las ${datos.hora}` : null,
      dom && datos.sector ? `Sector: ${datos.sector}` : null,
      `Nombre: ${datos.nombre}`,
      dom ? `Dirección: ${datos.direccion}` : `Retiro: ${datos.retiro}`,
      dom && datos.referencia ? `Referencia: ${datos.referencia}` : null,
      dom && datos.ubicacion ? `Ubicación: ${datos.ubicacion}` : null,
      datos.nota ? `Nota: ${datos.nota}` : null
    ].filter(x => x !== null).join('\n');
  }

  const FR = { Mañana: 'manana', Tarde: 'tarde', Cualquiera: 'cualquiera' };
  async function enviarClinica(h, err) {
    const hoy = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Guayaquil' });
    const falta = datos.nombre.length < 2 ? 'Escribe el nombre y apellido del paciente.' : !/^(09\d{8}|593\d{9})$/.test(datos.telefono.replace(/[\s-]/g, '')) ? 'Escribe un celular válido, por ejemplo 0991234567.'
      : !datos.dia || datos.dia < hoy ? 'Elige un día desde hoy.' : datos.menor && datos.representante.length < 2 ? 'Escribe el nombre de quien autoriza al menor de edad.'
      : !datos.consentimiento ? 'Para enviar tu solicitud, acepta el tratamiento de tus datos.' : '';
    if (falta) { err.textContent = falta; return; }
    err.textContent = ''; const b = $('#pd-enviar', h); b.disabled = true; b.textContent = 'Enviando…';
    try {
      const r = await CL.solicitar({ nombre: datos.nombre, telefono: datos.telefono.replace(/[\s-]/g, ''), servicios: carrito.map(l => items.get(l.id).nombre), dia: datos.dia, franja: FR[datos.franja] || 'cualquiera', menor: datos.menor, representante: datos.representante, consentimiento: datos.consentimiento });
      datos.ref = r && r.ref; datos.guardada = true; window.track && window.track('solicitud_enviada');
    } catch (e) {
      b.disabled = false; b.textContent = 'Reservar por WhatsApp';
      err.innerHTML = `${esc(e.message)} <button type="button" class="pd-btn pd-btn-sec" id="pd-solo-wa">Escribirnos por WhatsApp sin guardar</button>`;
      $('#pd-solo-wa', h).onclick = () => { datos.ref = null; window.open(wa(D.waCliente, mensaje()), '_blank', 'noopener'); };
      return;
    }
    window.open(wa(D.waCliente, mensaje()), '_blank', 'noopener');
    abrirHoja(`
      <div class="pd-listo" aria-hidden="true">✓</div>
      <h2 class="pd-hoja-tit">Recibimos tu solicitud</h2>
      <p class="pd-sub">Se abrió WhatsApp con tu mensaje: envíalo para que ${esc(D.corto || D.cliente)} te confirme el día y la hora. Solicitud N.º ${esc(datos.ref)}.</p>
      <button type="button" class="pd-btn pd-btn-full" id="pd-nuevo">Hacer otra solicitud</button>`,
      hh => { $('#pd-nuevo', hh).onclick = () => { carrito.length = 0; Object.assign(datos, { nombre: '', telefono: '', dia: '', menor: false, representante: '', consentimiento: false, nota: '', ref: null }); actualizarBarra(); hh.close(); }; });
  }

  function enviar(h) {
    const err = $('#pd-error', h);
    if (CL) return enviarClinica(h, err);
    const falta = R ? (!datos.nombre ? 'Escribe tu nombre para saber de quién es la reserva.' : '') : !datos.tipo ? 'Elige si lo quieres para llevar o a domicilio.'
      : !datos.nombre ? 'Escribe tu nombre para saber de quién es el pedido.'
      : datos.tipo === 'domicilio' && sectores() && !datos.sector ? 'Elige tu sector para calcular el envío.'
      : datos.tipo === 'domicilio' && !datos.direccion ? 'Escribe la dirección de entrega.'
      : D.programar && datos.cuando === 'programar' && !datos.hora ? 'Elige la hora a la que quieres tu pedido.' : '';
    if (falta) { err.textContent = falta; return; }
    err.textContent = '';
    window.open(wa(D.waCliente, mensaje()), '_blank', 'noopener');
    guardarPrueba();
    abrirHoja(`
      <div class="pd-listo" aria-hidden="true">✓</div>
      <h2 class="pd-hoja-tit">${R ? 'Tu reserva se abrió en WhatsApp' : 'Tu pedido se abrió en WhatsApp'}</h2>
      <p class="pd-sub">${R ? `Envía el mensaje. ${D.corto || D.cliente} te confirma el día y la hora.` : `Envía el mensaje para confirmarlo. ${D.corto || D.cliente} te responde con el tiempo${datos.tipo === 'domicilio' ? (envioActual() == null ? ' y el costo de envío' : ' de entrega') : ' de retiro'}.`}</p>
      <button type="button" class="pd-btn pd-btn-full" id="pd-nuevo">${R ? 'Hacer otra reserva' : 'Hacer otro pedido'}</button>`,
      hh => { $('#pd-nuevo', hh).onclick = () => { carrito.length = 0; actualizarBarra(); hh.close(); }; });
  }

  /* Copia local solo para mostrar el panel "lo que ve el negocio" en la presentación (no es la base real). */
  function guardarPrueba() {
    try {
      const k = D.claveDemo, lista = JSON.parse(localStorage.getItem(k) || '[]');
      lista.push({ fecha: new Date().toISOString(), tipo: datos.tipo, total: subtotal(), envio: envioActual() || 0,
        sector: datos.tipo === 'domicilio' ? datos.sector : '', nombre: datos.nombre, dia: datos.dia, franja: datos.franja, nota: datos.nota,
        programado: D.programar && datos.cuando === 'programar' ? datos.hora : '',
        lineas: carrito.map(l => ({ id: l.id, nombre: items.get(l.id).nombre, cant: l.cant, extras: l.extras })) });
      localStorage.setItem(k, JSON.stringify(lista.slice(-50)));
    } catch (e) { /* sin almacenamiento: el pedido igual sale por WhatsApp */ }
  }

  window.Pedido = { pintarCarta, abrirProducto, mensaje, carrito, datos, plata, esc, items };
})();
