/* clinica-api.js · puente entre las páginas (solicitud de cita, panel del equipo, panel del dueño) y la base. Mismo código para la demo y para producción.
   modo "demo": todo corre en el navegador (clinica-mock.js, datos de ejemplo, se guarda en localStorage).
   modo "supabase": llama a las funciones SQL de modulos/clinica/supabase/migrations por la API REST de Supabase (sin librerías).
     El paciente llama con la clave anon (solo existe solicitar_cita). El equipo inicia sesión con correo y clave (Authentication) y llama con su JWT;
     cada función comprueba por dentro la tabla staff del schema (no basta con "tener sesión").
   Configuración en config.js:  DEMO.clinica = { modo: 'supabase', url: 'https://xxxx.supabase.co', anonKey: '…', schema: 'luna_dental' }
   Nunca va la clave service_role aquí (CLAUDE.md §4.11): solo la anon, que es pública por diseño. */
(() => {
  const D = window.DEMO || {}, K = D.clinica || {};
  const modo = K.modo === 'supabase' ? 'supabase' : 'demo';
  const P = (D.claveDemo || 'clinica') + '_';
  const ls = { get: k => { try { return localStorage.getItem(P + k); } catch (e) { return null; } }, set: (k, v) => { try { v === null ? localStorage.removeItem(P + k) : localStorage.setItem(P + k, v); } catch (e) {} } };
  const conectado = modo === 'demo' || !!(K.url && K.anonKey && K.schema);

  async function http(url, opts) {
    let r;
    try { r = await fetch(url, opts); } catch (e) { throw new Error('Sin conexión. Revisa tu internet e intenta de nuevo.'); }
    const t = await r.text(); let j = null; try { j = t ? JSON.parse(t) : null; } catch (e) {}
    if (!r.ok) { const er = new Error((j && (j.message || j.msg || j.error_description)) || 'No se pudo completar la acción.'); er.estado = r.status; throw er; }
    return j;
  }
  const cab = extra => Object.assign({ apikey: K.anonKey, Authorization: 'Bearer ' + (ls.get('jwt') || K.anonKey), 'Content-Type': 'application/json', 'Content-Profile': K.schema, 'Accept-Profile': K.schema }, extra || {});

  async function renovar() {
    const rt = ls.get('refresh'); if (!rt) throw new Error('Tu sesión terminó. Vuelve a entrar.');
    const j = await http(`${K.url}/auth/v1/token?grant_type=refresh_token`, { method: 'POST', headers: { apikey: K.anonKey, 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: rt }) })
      .catch(() => { ls.set('jwt', null); ls.set('refresh', null); throw new Error('Tu sesión terminó. Vuelve a entrar.'); });
    ls.set('jwt', j.access_token); if (j.refresh_token) ls.set('refresh', j.refresh_token);
  }

  async function rpc(fn, args) {
    if (modo === 'demo') return window.CLINICA_MOCK.rpc(fn, args || {});
    if (!conectado) throw new Error('Falta conectar la base de datos (config.js).');
    const llamar = () => http(`${K.url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: cab(), body: JSON.stringify(args || {}) });
    try { return await llamar(); }
    catch (e) { if (ls.get('jwt') && /JWT expired|jwt/i.test(e.message) && ls.get('refresh')) { await renovar(); return llamar(); } throw e; }
  }

  /* Sesión del equipo. Demo: se elige un rol. Producción: correo y clave de Supabase Authentication. */
  const staff = {
    async sesion() {
      if (modo === 'demo') return window.CLINICA_MOCK.sesion();
      if (!conectado || !ls.get('jwt')) return null;
      try { return await rpc('yo'); } catch (e) { ls.set('jwt', null); ls.set('refresh', null); return null; }
    },
    async entrar(a, b) {
      if (modo === 'demo') return window.CLINICA_MOCK.entrar(a);
      if (!conectado) throw new Error('Falta conectar la base de datos (config.js).');
      const j = await http(`${K.url}/auth/v1/token?grant_type=password`, { method: 'POST', headers: { apikey: K.anonKey, 'Content-Type': 'application/json' }, body: JSON.stringify({ email: a, password: b }) })
        .catch(() => { throw new Error('Correo o clave incorrectos.'); });
      ls.set('jwt', j.access_token); ls.set('refresh', j.refresh_token || null);
      const yo = await rpc('yo').catch(() => null);
      if (!yo) { ls.set('jwt', null); ls.set('refresh', null); throw new Error('Esa cuenta no es del equipo de la clínica.'); }
      return yo;
    },
    salir() { if (modo === 'demo') window.CLINICA_MOCK.salir(); ls.set('jwt', null); ls.set('refresh', null); },
  };

  /* Solicitud de cita del paciente: los tratamientos se mandan por id; aquí se traducen desde el nombre que eligió en la carta. */
  async function solicitar(d) {
    const lista = await rpc('servicios_lista');
    const ids = d.servicios.map(n => { const s = lista.find(x => x.nombre.trim().toLowerCase() === String(n).trim().toLowerCase()); if (!s) throw new Error('Uno de los tratamientos ya no está disponible. Recarga la página.'); return s.id; });
    return rpc('solicitar_cita', { p_nombre: d.nombre, p_telefono: d.telefono, p_servicios: ids, p_dia: d.dia, p_franja: d.franja, p_menor: !!d.menor, p_representante: d.representante || null, p_consentimiento: d.consentimiento === true });
  }

  window.CLINICA = { modo, conectado, rpc, staff, solicitar };
})();
