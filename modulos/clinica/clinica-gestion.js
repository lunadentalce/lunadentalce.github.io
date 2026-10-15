/* clinica-gestion.js · pantallas de configuración del panel del dueño (solo administración): doctores, tarifario, tratamientos, horario y cuentas del equipo.
   Cada cambio llama a una función SQL que vuelve a comprobar que la cuenta es admin; esta pantalla solo la ve ese rol, pero la regla vive en la base. */
(() => {
  const { esc, $, $$, aviso, msgErr } = CLUI, C = CLINICA, P = window.CLPANEL;
  const falla = (id, e) => { const el = $(id); if (el) el.textContent = msgErr(e); aviso(msgErr(e), 'mal'); };
  const limpiar = id => { const el = $(id); if (el) el.textContent = ''; };
  const DIAS = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];

  /* ---- Doctores ---- */
  function pintarDoctores() {
    limpiar('#doc-err');
    const D = P.docs();
    $('#aj-doc').innerHTML = D.map(d => `<tr data-id="${d.id}"><td><input value="${esc(d.nombre)}" maxlength="80" aria-label="Nombre"></td><td><input value="${esc(d.especialidad || '')}" maxlength="80" aria-label="Especialidad"></td><td><input type="color" value="${esc(d.color)}" aria-label="Color"></td><td><input type="checkbox" ${d.activo ? 'checked' : ''} aria-label="Activo"></td><td><button type="button" class="mini" data-gd="${d.id}">Guardar</button></td></tr>`).join('')
      + `<tr data-id=""><td><input placeholder="Nuevo doctor" maxlength="80" aria-label="Nombre del nuevo doctor"></td><td><input placeholder="Especialidad" maxlength="80" aria-label="Especialidad"></td><td><input type="color" value="#B8933A" aria-label="Color"></td><td><input type="checkbox" checked aria-label="Activo"></td><td><button type="button" class="mini" data-gd="">Añadir</button></td></tr>`;
    $$('[data-gd]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), [n, e, c, a] = $$('input', tr);
      try { await C.rpc('doctor_guardar', { p_id: tr.dataset.id ? +tr.dataset.id : null, p_nombre: n.value, p_especialidad: e.value, p_color: c.value, p_activo: a.checked }); aviso('Doctor guardado.'); await P.base(); pintarDoctores(); } catch (x) { falla('#doc-err', x); } });
  }

  /* ---- Tarifario ---- */
  function pintarTarifario() {
    limpiar('#tar-err');
    const T = P.tar();
    $('#aj-tar').innerHTML = T.map(t => `<tr data-id="${t.id}"><td><input value="${esc(t.nombre)}" maxlength="80" aria-label="Tratamiento"></td><td class="n"><input type="number" step="0.01" min="0" value="${t.precio}" aria-label="Precio"></td><td><input type="checkbox" ${t.activo ? 'checked' : ''} aria-label="Activo"></td><td><button type="button" class="mini" data-gt="${t.id}">Guardar</button></td></tr>`).join('')
      + `<tr data-id=""><td><input placeholder="Nuevo tratamiento" maxlength="80" aria-label="Nuevo tratamiento"></td><td class="n"><input type="number" step="0.01" min="0" placeholder="0.00" aria-label="Precio"></td><td><input type="checkbox" checked aria-label="Activo"></td><td><button type="button" class="mini" data-gt="">Añadir</button></td></tr>`;
    $$('[data-gt]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), [n, p, a] = $$('input', tr);
      try { await C.rpc('tarifario_guardar', { p_id: tr.dataset.id ? +tr.dataset.id : null, p_nombre: n.value, p_precio: parseFloat(p.value), p_activo: a.checked }); aviso('Tarifario guardado.'); await P.base(); pintarTarifario(); } catch (x) { falla('#tar-err', x); } });
  }

  /* ---- Tratamientos (duración en la agenda), horario y cuentas: salen de config_admin ---- */
  let CFG = null;
  async function cargarCfg() { CFG = await C.rpc('config_admin'); return CFG; }

  async function pintarTratamientos() {
    limpiar('#sv-err');
    try { await cargarCfg(); } catch (e) { return falla('#sv-err', e); }
    const fila = s => `<tr data-id="${s ? s.id : ''}" data-cat="${esc(s ? s.categoria : 'Tratamientos')}" data-desc="${esc(s && s.descripcion || '')}" data-precio="${esc(s && s.precio || '')}" data-fid="${s ? s.fidelidad : false}"><td><input value="${esc(s ? s.nombre : '')}" ${s ? '' : 'placeholder="Nuevo tratamiento"'} maxlength="80" aria-label="Nombre"></td><td class="n"><input type="number" min="15" max="240" step="5" value="${s ? s.duracion_min : 40}" aria-label="Duración en minutos"></td><td><input type="checkbox" ${!s || s.activo ? 'checked' : ''} aria-label="Activo"></td><td><button type="button" class="mini" data-gs>${s ? 'Guardar' : 'Añadir'}</button></td></tr>`;
    $('#aj-sv').innerHTML = CFG.servicios.map(fila).join('') + fila(null);
    $$('[data-gs]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), [n, d, a] = $$('input', tr);
      try { await C.rpc('servicio_guardar', { p_id: tr.dataset.id ? +tr.dataset.id : null, p_nombre: n.value, p_categoria: tr.dataset.cat, p_descripcion: tr.dataset.desc || null, p_duracion: parseInt(d.value), p_precio: tr.dataset.precio || null, p_fidelidad: tr.dataset.fid === 'true', p_activo: a.checked }); aviso('Tratamiento guardado.'); pintarTratamientos(); } catch (x) { falla('#sv-err', x); } });
  }

  async function pintarHorario() {
    limpiar('#hor-err');
    try { await cargarCfg(); } catch (e) { return falla('#hor-err', e); }
    $('#cfg-cab').value = CFG.config.capacidad;
    $('#aj-hor').innerHTML = CFG.horario.map(h => `<tr data-dia="${h.dia}"><td><b>${DIAS[h.dia - 1]}</b></td><td><input type="checkbox" ${h.abre ? 'checked' : ''} aria-label="${DIAS[h.dia - 1]}: atiende"></td>
      <td><input type="time" value="${h.abre || '09:00'}" aria-label="Abre"></td><td><input type="time" value="${h.cierra || '18:00'}" aria-label="Cierra"></td>
      <td><input type="time" value="${h.pausa_ini || ''}" aria-label="Pausa desde"></td><td><input type="time" value="${h.pausa_fin || ''}" aria-label="Pausa hasta"></td><td><button type="button" class="mini" data-gh="${h.dia}">Guardar</button></td></tr>`).join('');
    $$('[data-gh]').forEach(b => b.onclick = async () => { const tr = b.closest('tr'), dia = +tr.dataset.dia, [at, ab, ci, pi, pf] = $$('input', tr);
      try {
        if (!at.checked) await C.rpc('horario_guardar', { p_dia: dia, p_abre: '', p_cierra: '' });
        else {
          if ((pi.value && !pf.value) || (!pi.value && pf.value)) throw new Error('Para la pausa escribe la hora de inicio y la de fin, o deja las dos vacías.');
          await C.rpc('horario_pausa_guardar', { p_dia: dia, p_ini: '', p_fin: '' }).catch(() => {});   // se quita antes para que el nuevo horario no choque con la pausa anterior
          await C.rpc('horario_guardar', { p_dia: dia, p_abre: ab.value, p_cierra: ci.value });
          if (pi.value) await C.rpc('horario_pausa_guardar', { p_dia: dia, p_ini: pi.value, p_fin: pf.value });
        }
        aviso(`${DIAS[dia - 1]} guardado.`); pintarHorario(); const c2 = await C.rpc('config_admin'); const hs = c2.horario.filter(x => x.abre);
        if (hs.length) P.horario = { paso: +c2.config.paso_min || 30, h0: Math.min(...hs.map(x => +x.abre.slice(0, 2))), h1: Math.max(...hs.map(x => Math.ceil(+x.cierra.slice(0, 2) + (+x.cierra.slice(3, 5) ? .5 : 0)))) };
      } catch (x) { falla('#hor-err', x); } });
  }
  $('#cfg-guardar').onclick = async () => { try { await cargarCfg(); await C.rpc('config_guardar', { p_capacidad: parseInt($('#cfg-cab').value), p_meta: CFG.config.sellos_meta }); aviso('Cupos guardados.'); } catch (x) { falla('#hor-err', x); } };

  async function pintarCuentas() {
    limpiar('#eq-err');
    try { await cargarCfg(); } catch (e) { return falla('#eq-err', e); }
    const L = CFG.equipo || [];
    $('#aj-eq').innerHTML = L.map(m => `<tr><td>${esc(m.nombre)}${m.yo ? ' <span class="pill">tú</span>' : ''}</td><td>${esc(m.email)}</td><td>${{ admin: 'Administración', doctor: 'Doctor', recepcion: 'Recepción' }[m.rol] || esc(m.rol)}</td><td>${m.yo ? '' : `<button type="button" class="mini" data-q="${esc(m.user_id)}" data-n="${esc(m.nombre)}">Quitar acceso</button>`}</td></tr>`).join('') || '<tr><td colspan="4">Sin cuentas.</td></tr>';
    $$('[data-q]', $('#aj-eq')).forEach(b => b.onclick = async () => { if (!confirm(`¿Quitar el acceso de ${b.dataset.n}? Su usuario sigue existiendo en Supabase pero ya no podrá entrar a los paneles.`)) return;
      try { await C.rpc('equipo_quitar', { p_user: b.dataset.q }); aviso('Acceso quitado.'); pintarCuentas(); } catch (x) { falla('#eq-err', x); } });
  }
  $('#eq-form').onsubmit = async e => { e.preventDefault(); limpiar('#eq-err');
    try { await C.rpc('equipo_guardar', { p_email: $('#eq-mail').value.trim(), p_nombre: $('#eq-nombre').value.trim(), p_rol: $('#eq-rol').value }); aviso('Cuenta agregada.'); e.target.reset(); pintarCuentas(); } catch (x) { falla('#eq-err', x); } };

  Object.assign(P.cargar, { 't-doctores': pintarDoctores, 't-tarifario': pintarTarifario, 't-tratamientos': pintarTratamientos, 't-horario': pintarHorario, 't-cuentas': pintarCuentas });
})();
