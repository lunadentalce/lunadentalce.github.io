/* clinica-pdf.js · arma el PDF del presupuesto (clínica, paciente, cada tratamiento con su precio y el total) y lo envía por WhatsApp.
   Sin librerías: escribe el PDF a mano con las fuentes estándar (Helvetica) y codificación WinAnsi, así que las tildes y la ñ salen bien.
   Uso: CLPDF.presupuesto({ corto, clinica, ciudad, telefono, paciente, doctor, fecha, ref, items: [{ descripcion, cant, precio }], descuento, total, seguimiento }) → Blob (application/pdf)
        CLPDF.enviar({ blob, nombre, texto, enlace, telefono, wa }) → 'compartido' | 'enlace' | 'cancelado'
   En celular y tablet abre el menú de compartir con el PDF adjunto (WhatsApp, entre otros). Donde el navegador no puede adjuntar archivos (computador), WhatsApp recibe un mensaje con un ENLACE
   al presupuesto (presupuesto.html): ahí el paciente ve el detalle y descarga el PDF con un toque. WhatsApp no deja adjuntar un archivo desde un enlace de una página web. Todo lo que viene de la base se escribe como texto del PDF (no es HTML). */
(() => {
  const AN = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584];
  const NE = [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584];
  const CP = { '€': 0x80, '…': 0x85, '‘': 0x91, '’': 0x92, '“': 0x93, '”': 0x94, '•': 0x95, '–': 0x96, '—': 0x97 };
  const base = c => c.normalize('NFD').replace(/[̀-ͯ]/g, '');
  const ancho = (t, tam, neg) => { let w = 0; for (const ch of String(t)) { const b = base(ch).charCodeAt(0); w += (b >= 32 && b <= 126 ? (neg ? NE : AN)[b - 32] : 556); } return w * tam / 1000; };
  const bytes = t => { const o = []; for (const ch of String(t)) { const c = ch.codePointAt(0); o.push(c >= 0xA0 && c <= 0xFF ? c : c < 0x80 ? c : (CP[ch] ?? 63)); } return o; };   // WinAnsi: Latin-1 (á, ñ, ¿…) tal cual; lo demás, el equivalente o «?»
  const lit = t => { const o = [40]; bytes(t).forEach(b => { if (b === 40 || b === 41 || b === 92) o.push(92); o.push(b); }); o.push(41); return o; };
  const asc = s => Array.from(s, c => c.charCodeAt(0));
  const usd = n => '$' + (Math.round((+n || 0) * 100) / 100).toFixed(2);
  const lineas = (t, max, tam, neg) => {   // parte un texto en renglones que quepan en `max` puntos
    const out = []; let cur = '';
    String(t).split(/\s+/).filter(Boolean).forEach(p => { const prueba = cur ? cur + ' ' + p : p; if (ancho(prueba, tam, neg) <= max || !cur) cur = prueba; else { out.push(cur); cur = p; } });
    if (cur) out.push(cur); return out.length ? out : [''];
  };

  function presupuesto(d) {
    const A4 = [595.28, 841.89], M = 48, DER = A4[0] - M, NEG = '0.07 0.07 0.07', ORO = '0.76 0.60 0.27', GRIS = '0.42 0.42 0.44';
    const paginas = []; let ops, y;
    const t = (x, yy, texto, f, tam, color, alin) => { const w = ancho(texto, tam, f === 2); const xx = alin === 'der' ? x - w : alin === 'cen' ? x - w / 2 : x;
      ops.push(...asc(`BT /F${f} ${tam} Tf ${color || NEG} rg ${xx.toFixed(2)} ${yy.toFixed(2)} Td `), ...lit(texto), ...asc(' Tj ET\n')); };
    const rect = (x, yy, w, h, color) => ops.push(...asc(`${color} rg ${x.toFixed(2)} ${yy.toFixed(2)} ${w.toFixed(2)} ${h.toFixed(2)} re f\n`));
    const raya = (x1, x2, yy, color, g) => ops.push(...asc(`${color} RG ${g || 0.6} w ${x1.toFixed(2)} ${yy.toFixed(2)} m ${x2.toFixed(2)} ${yy.toFixed(2)} l S\n`));
    const nueva = (cont) => { ops = []; paginas.push(ops); if (cont) { y = A4[1] - M; t(M, y, `${d.clinica || ''} · Presupuesto de ${d.paciente || ''} (continuación)`, 1, 9, GRIS); y -= 24; } };
    const encabezadoTabla = () => { raya(M, DER, y + 12, NEG, 0.8); t(M, y, 'Tratamiento', 2, 9.5); t(DER - 190, y, 'Cant.', 2, 9.5, NEG, 'der'); t(DER - 100, y, 'Precio', 2, 9.5, NEG, 'der'); t(DER, y, 'Importe', 2, 9.5, NEG, 'der'); raya(M, DER, y - 7, NEG, 0.8); y -= 24; };

    nueva(false);
    rect(0, A4[1] - 104, A4[0], 104, NEG); rect(0, A4[1] - 107, A4[0], 3, ORO);
    t(M, A4[1] - 46, d.corto || d.clinica || 'Presupuesto', 2, 24, '1 1 1');
    if (d.corto && d.clinica && d.clinica !== d.corto) t(M, A4[1] - 66, d.clinica, 1, 9.5, '0.82 0.82 0.84');
    t(M, A4[1] - 82, [d.ciudad, d.telefono].filter(Boolean).join(' · '), 1, 9.5, '0.82 0.82 0.84');
    t(DER, A4[1] - 46, 'PRESUPUESTO' + (d.ref ? ' N.º ' + d.ref : ''), 2, 13, ORO, 'der'); t(DER, A4[1] - 66, d.fecha || '', 1, 10, '0.82 0.82 0.84', 'der');
    y = A4[1] - 146;
    t(M, y, 'Paciente', 1, 9, GRIS); t(M, y - 15, d.paciente || '', 2, 13);
    if (d.doctor) { t(DER, y, 'Doctor', 1, 9, GRIS, 'der'); t(DER, y - 15, d.doctor, 2, 13, NEG, 'der'); }
    y -= 52; encabezadoTabla();

    const items = d.items || []; let sub = 0;
    items.forEach(it => {
      const imp = (+it.cant || 1) * (+it.precio || 0); sub += imp;
      const ls = lineas(it.descripcion, DER - 190 - 40 - M - 10, 10, false), alto = (ls.length - 1) * 13 + 21;
      if (y - alto < 170) { nueva(true); encabezadoTabla(); }
      ls.forEach((l, k) => t(M, y - k * 13, l, 1, 10));
      t(DER - 190, y, String(it.cant || 1), 1, 10, NEG, 'der'); t(DER - 100, y, usd(it.precio), 1, 10, NEG, 'der'); t(DER, y, usd(imp), 1, 10, NEG, 'der');
      raya(M, DER, y - (ls.length - 1) * 13 - 7, '0.86 0.86 0.88', 0.5); y -= alto;
    });

    if (y < 210) { nueva(true); }
    const desc = Math.round(sub * (+d.descuento || 0)) / 100, total = d.total != null ? +d.total : Math.round((sub - desc) * 100) / 100;
    y -= 10; t(DER - 100, y, 'Subtotal', 1, 10.5, NEG, 'der'); t(DER, y, usd(sub), 1, 10.5, NEG, 'der'); y -= 17;
    if (+d.descuento) { t(DER - 100, y, `Descuento (${Math.round(+d.descuento)} %)`, 1, 10.5, NEG, 'der'); t(DER, y, '-' + usd(desc), 1, 10.5, NEG, 'der'); y -= 17; }
    y -= 4; rect(DER - 230, y - 28, 230, 34, NEG); t(DER - 118, y - 16, 'TOTAL', 2, 12, ORO, 'der'); t(DER - 12, y - 16, usd(total), 2, 14, '1 1 1', 'der'); y -= 62;
    const notas = ['Presupuesto sujeto a valoración del odontólogo. Puede variar si el diagnóstico cambia.', `Válido por ${d.validez || '15 días'}.`, d.seguimiento ? `Seguimiento: ${d.seguimiento}.` : '', 'Los precios son en dólares de los Estados Unidos.'].filter(Boolean);
    notas.forEach(n => lineas(n, DER - M, 9, false).forEach(l => { t(M, y, l, 1, 9, GRIS); y -= 12.5; }));
    paginas.forEach((p, i) => { ops = p; if (paginas.length > 1) t(A4[0] / 2, 28, `Página ${i + 1} de ${paginas.length}`, 1, 8.5, GRIS, 'cen'); });

    return ensamblar(paginas, A4, `Presupuesto · ${d.paciente || ''}`, d.clinica || '');
  }

  function ensamblar(paginas, A4, titulo, autor) {
    // objetos: 1 catálogo, 2 páginas, 3 y 4 fuentes, 5 info, luego (página, contenido) por cada hoja
    const objs = [null, null, null, null, null], n = paginas.length, kids = [];
    paginas.forEach((c, i) => { const po = 6 + i * 2, co = po + 1; kids.push(`${po} 0 R`);
      objs[po - 1] = asc(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4[0]} ${A4[1]}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${co} 0 R >>`);
      objs[co - 1] = [...asc(`<< /Length ${c.length} >>\nstream\n`), ...c, ...asc('\nendstream')]; });
    objs[0] = asc('<< /Type /Catalog /Pages 2 0 R >>'); objs[1] = asc(`<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${n} >>`);
    objs[2] = asc('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'); objs[3] = asc('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
    objs[4] = [...asc('<< /Title '), ...lit(titulo), ...asc(' /Author '), ...lit(autor), ...asc(' /Producer (Presupuesto) >>')];
    const out = [...asc('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n')], pos = [];
    objs.forEach((o, i) => { pos.push(out.length); out.push(...asc(`${i + 1} 0 obj\n`), ...o, ...asc('\nendobj\n')); });
    const xr = out.length; out.push(...asc(`xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`)); pos.forEach(p => out.push(...asc(String(p).padStart(10, '0') + ' 00000 n \n')));
    out.push(...asc(`trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Info 5 0 R >>\nstartxref\n${xr}\n%%EOF\n`));
    return new Blob([new Uint8Array(out)], { type: 'application/pdf' });
  }

  /* Ficha del paciente (PDF): datos, odontograma dibujado en vectores, estado por diente e historial de sesiones con sus tratamientos y totales.
     CLPDF.ficha({ corto, clinica, ciudad, telefono, paciente, historia, fecha, datos: [[etiqueta, valor]], temporales, dientes: { n: CLODO.dibujo(...) }, estados: [[diente, texto]],
                   leyenda: [[nombre, color]], sesiones: [{ dia, doctor, registro, total, nota, marcas: [texto], items: [{ lugar, descripcion, precio }] }] } */
  function ficha(d) {
    const A4 = [595.28, 841.89], M = 48, DER = A4[0] - M, NEG = '0.07 0.07 0.07', ORO = '0.76 0.60 0.27', GRIS = '0.42 0.42 0.44';
    const paginas = []; let ops, y;
    const rgb = h => { const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(h || ''); return m ? [1, 2, 3].map(k => (parseInt(m[k], 16) / 255).toFixed(3)).join(' ') : '1 1 1'; };
    const t = (x, yy, texto, f, tam, color, alin) => { const w = ancho(texto, tam, f === 2); const xx = alin === 'der' ? x - w : alin === 'cen' ? x - w / 2 : x;
      ops.push(...asc(`BT /F${f} ${tam} Tf ${color || NEG} rg ${xx.toFixed(2)} ${yy.toFixed(2)} Td `), ...lit(texto), ...asc(' Tj ET\n')); };
    const rect = (x, yy, w, h, color) => ops.push(...asc(`${color} rg ${x.toFixed(2)} ${yy.toFixed(2)} ${w.toFixed(2)} ${h.toFixed(2)} re f\n`));
    const raya = (x1, x2, yy, color, g) => ops.push(...asc(`${color} RG ${g || 0.6} w ${x1.toFixed(2)} ${yy.toFixed(2)} m ${x2.toFixed(2)} ${yy.toFixed(2)} l S\n`));
    const poligono = (pts, color) => ops.push(...asc(`${color} rg 0.07 0.07 0.07 RG 0.6 w ${pts.map((p, k) => p[0].toFixed(2) + ' ' + p[1].toFixed(2) + (k ? ' l' : ' m')).join(' ')} h B\n`));
    const linea = (x1, y1, x2, y2, color, g) => ops.push(...asc(`${color} RG ${g} w 1 J ${x1.toFixed(2)} ${y1.toFixed(2)} m ${x2.toFixed(2)} ${y2.toFixed(2)} l S 0 J\n`));
    const nueva = cont => { ops = []; paginas.push(ops); if (cont) { y = A4[1] - M; t(M, y, `${d.clinica || ''} · Ficha de ${d.paciente || ''} (continuación)`, 1, 9, GRIS); y -= 26; } };
    const espacio = h => { if (y - h < 56) nueva(true); };
    const titulo = txt => { espacio(40); t(M, y, txt, 2, 12); raya(M, DER, y - 6, ORO, 1.2); y -= 24; };

    nueva(false);
    rect(0, A4[1] - 104, A4[0], 104, NEG); rect(0, A4[1] - 107, A4[0], 3, ORO);
    t(M, A4[1] - 46, d.corto || d.clinica || 'Ficha', 2, 24, '1 1 1');
    if (d.corto && d.clinica && d.clinica !== d.corto) t(M, A4[1] - 66, d.clinica, 1, 9.5, '0.82 0.82 0.84');
    t(M, A4[1] - 82, [d.ciudad, d.telefono].filter(Boolean).join(' · '), 1, 9.5, '0.82 0.82 0.84');
    t(DER, A4[1] - 46, 'FICHA DEL PACIENTE', 2, 13, ORO, 'der'); t(DER, A4[1] - 66, d.fecha || '', 1, 10, '0.82 0.82 0.84', 'der');
    y = A4[1] - 144;
    t(M, y, 'Paciente', 1, 9, GRIS); t(M, y - 16, d.paciente || '', 2, 15);
    if (d.historia) { t(DER, y, 'Historia clínica N.º', 1, 9, GRIS, 'der'); t(DER, y - 16, d.historia, 2, 15, NEG, 'der'); }
    y -= 40;
    const datos = (d.datos || []).filter(r => r[1]);
    for (let k = 0; k < datos.length; k += 2) { espacio(32);
      [0, 1].forEach(c => { const r = datos[k + c]; if (!r) return; const x = M + c * 255; t(x, y, r[0], 1, 8.5, GRIS); lineas(r[1], 235, 10.5, false).slice(0, 2).forEach((l, q) => t(x, y - 12 - q * 12, l, 1, 10.5)); });
      y -= 40; }
    y -= 4;

    // odontograma
    titulo('Odontograma');
    const T = 23, SEP = 5.2, G = 16;   // diente de 23 pt; 16 por arcada
    const arco = (nums, yy, arriba, tam, paso, x0) => nums.forEach((n, k) => {
      const x = x0 + k * paso + (k >= nums.length / 2 ? 10 : 0), dib = (d.dientes || {})[n] || { fill: { top: '#FFFFFF', bottom: '#FFFFFF', left: '#FFFFFF', right: '#FFFFFF', c: '#FFFFFF' } }, e = tam / 40;
      const P = { top: [[0, 0], [40, 0], [28, 12], [12, 12]], bottom: [[0, 40], [40, 40], [28, 28], [12, 28]], left: [[0, 0], [12, 12], [12, 28], [0, 40]], right: [[40, 0], [40, 40], [28, 28], [28, 12]], c: [[12, 12], [28, 12], [28, 28], [12, 28]] };
      Object.keys(P).forEach(pos => poligono(P[pos].map(([px, py]) => [x + px * e, yy + tam - py * e]), rgb(dib.fill[pos])));
      if (dib.ausente) { linea(x + 3 * e, yy + tam - 3 * e, x + 37 * e, yy + tam - 37 * e, '0.33 0.33 0.33', 1.1); linea(x + 37 * e, yy + tam - 3 * e, x + 3 * e, yy + tam - 37 * e, '0.33 0.33 0.33', 1.1); }
      if (dib.extr) { linea(x + 3.5 * e, yy + tam - 3.5 * e, x + 36.5 * e, yy + tam - 36.5 * e, '0.827 0.184 0.184', 2.2); linea(x + 36.5 * e, yy + tam - 3.5 * e, x + 3.5 * e, yy + tam - 36.5 * e, '0.827 0.184 0.184', 2.2); }
      if (dib.seg) ops.push(...asc(`${rgb(dib.seg)} RG 1.6 w ${x.toFixed(2)} ${(yy).toFixed(2)} ${tam.toFixed(2)} ${tam.toFixed(2)} re S\n`));
      t(x + tam / 2, arriba ? yy + tam + 4 : yy - 9, String(n), 2, 7.5, NEG, 'cen'); });
    const bloque = (nom, sup, inf, tam, paso) => { espacio(tam * 2 + 70); const ancho = sup.length * paso + 10, x0 = M + (DER - M - ancho) / 2;
      t(A4[0] / 2, y, nom, 2, 8.5, GRIS, 'cen'); y -= 22; arco(sup, y - tam, true, tam, paso, x0); y -= tam + 26; arco(inf, y - tam, false, tam, paso, x0); y -= tam + 24; };
    bloque('DIENTES PERMANENTES', [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28], [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38], T, T + SEP);
    if (d.temporales) bloque('DIENTES TEMPORALES', [55, 54, 53, 52, 51, 61, 62, 63, 64, 65], [85, 84, 83, 82, 81, 71, 72, 73, 74, 75], T, T + SEP);
    // leyenda
    espacio(30); let lx = M;
    (d.leyenda || []).forEach(([nom, col]) => { const w = 16 + ancho(nom, 8.5, false) + 12; if (lx + w > DER) { lx = M; y -= 14; espacio(16); }
      if (nom === 'Extracción') { linea(lx, y - 1, lx + 8, y + 7, '0.827 0.184 0.184', 1.6); linea(lx + 8, y - 1, lx, y + 7, '0.827 0.184 0.184', 1.6); } else poligono([[lx, y - 1], [lx + 8, y - 1], [lx + 8, y + 7], [lx, y + 7]], rgb(col));
      t(lx + 13, y, nom, 1, 8.5, GRIS); lx += w; });
    y -= 26;

    // estado por diente
    if ((d.estados || []).length) { titulo('Estado de cada diente marcado');
      d.estados.forEach(([n, txt]) => { const ls = lineas(txt, DER - M - 60, 10, false); espacio(ls.length * 13 + 8); t(M, y, 'Diente ' + n, 2, 10); ls.forEach((l, k) => t(M + 60, y - k * 13, l, 1, 10)); y -= ls.length * 13 + 6; });
      y -= 8; }

    // historial de sesiones
    titulo('Historial de sesiones');
    if (!(d.sesiones || []).length) { t(M, y, 'Todavía no hay sesiones guardadas.', 1, 10, GRIS); y -= 20; }
    (d.sesiones || []).forEach(x => { espacio(70);
      t(M, y, x.dia || '', 2, 11); t(DER, y, usd(x.total), 2, 11, NEG, 'der'); y -= 14;
      const quien = [x.doctor ? 'Doctor/a: ' + x.doctor : '', x.registro ? 'Registró: ' + x.registro : ''].filter(Boolean).join(' · '); if (quien) { t(M, y, quien, 1, 8.5, GRIS); y -= 13; }
      if ((x.marcas || []).length) lineas('Marcas: ' + x.marcas.join('; '), DER - M, 9, false).forEach(l => { espacio(14); t(M, y, l, 1, 9, GRIS); y -= 12; });
      (x.items || []).forEach(it => { const ls = lineas(`${it.lugar}: ${it.descripcion}`, DER - M - 70, 10, false); espacio(ls.length * 13 + 6); ls.forEach((l, k) => t(M + 8, y - k * 13, l, 1, 10)); t(DER, y, usd(it.precio), 1, 10, NEG, 'der'); y -= ls.length * 13 + 3; });
      if (x.nota) lineas('Nota: ' + x.nota, DER - M, 9.5, false).forEach(l => { espacio(14); t(M, y, l, 1, 9.5, GRIS); y -= 12.5; });
      raya(M, DER, y - 2, '0.86 0.86 0.88', 0.6); y -= 16; });
    paginas.forEach((p, i) => { ops = p; if (paginas.length > 1) t(A4[0] / 2, 28, `Página ${i + 1} de ${paginas.length}`, 1, 8.5, GRIS, 'cen'); });
    return ensamblar(paginas, A4, `Ficha · ${d.paciente || ''}`, d.clinica || '');
  }

  const limpio = t => base(String(t || '')).replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '');
  /* Enlace al presupuesto: lleva los datos en el «#» de la dirección (el navegador no los manda a ningún servidor), así que se abre en cualquier teléfono y ahí se descarga el PDF. */
  const b64 = t => btoa(String.fromCharCode(...new TextEncoder().encode(t))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const deb64 = t => new TextDecoder().decode(Uint8Array.from(atob(t.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0)));
  const enlace = (d, pagina) => { const o = { n: d.paciente || '', f: d.fechaIso || '', d: d.doctor || '', i: (d.items || []).map(x => [x.descripcion, +x.cant || 1, +x.precio || 0]), x: +d.descuento || 0, t: +d.total || 0, s: d.seguimientoIso || '', r: d.ref || '' };
    return new URL(pagina || 'presupuesto.html', location.href).href.split('#')[0] + '#d=' + b64(JSON.stringify(o)); };
  const leerEnlace = hash => { try { const m = /(?:^|[#&])d=([^&]+)/.exec(hash || ''); if (!m) return null; const o = JSON.parse(deb64(m[1]));
    return { paciente: String(o.n || ''), fechaIso: String(o.f || ''), doctor: String(o.d || ''), items: (Array.isArray(o.i) ? o.i : []).slice(0, 40).map(r => ({ descripcion: String(r[0] || ''), cant: Math.max(1, Math.min(99, +r[1] || 1)), precio: Math.max(0, +r[2] || 0) })), descuento: Math.max(0, Math.min(100, +o.x || 0)), total: Math.max(0, +o.t || 0), seguimientoIso: String(o.s || ''), ref: String(o.r || '') }; } catch (e) { return null; } };
  const descargar = (blob, nombre) => { const url = URL.createObjectURL(blob), a = document.createElement('a'); a.href = url; a.download = nombre; document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000); };
  async function enviar(o) {
    const nombre = o.nombre || 'Presupuesto.pdf', file = new File([o.blob], nombre, { type: 'application/pdf' });
    const tactil = /android|iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.maxTouchPoints > 1 && /Macintosh/.test(navigator.userAgent));
    if (tactil && navigator.canShare && navigator.canShare({ files: [file] })) {
      try { await navigator.share({ files: [file], title: nombre, text: o.textoArchivo || o.texto }); return 'compartido'; }
      catch (e) { if (e && e.name === 'AbortError') return 'cancelado'; }   // otro error: se sigue con el enlace
    }
    if (o.soloArchivo) return 'descargar';
    // sin menú de compartir (computador, o un navegador que no deja adjuntar): WhatsApp recibe un mensaje con el enlace al presupuesto; ahí se ve el detalle y se descarga el PDF
    if (o.wa) window.open(o.wa(o.telefono || '', o.texto + (o.enlace ? '\n' + o.enlace : '')), '_blank', 'noopener');
    return 'enlace';
  }
  window.CLPDF = { presupuesto, ficha, enviar, enlace, leerEnlace, descargar, nombreFicha: (clinica, paciente, fecha) => `Ficha-${limpio(clinica)}-${limpio(paciente)}-${fecha || ''}.pdf`.replace(/-+\./, '.'), nombreArchivo: (clinica, paciente, fecha) => `Presupuesto-${limpio(clinica)}-${limpio(paciente)}-${fecha || ''}.pdf`.replace(/-+\./, '.'), ancho, usd };
})();
