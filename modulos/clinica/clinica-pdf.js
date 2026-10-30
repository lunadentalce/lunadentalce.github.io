/* clinica-pdf.js · arma el PDF del presupuesto (clínica, paciente, cada tratamiento con su precio y el total) y lo envía por WhatsApp.
   Sin librerías: escribe el PDF a mano con las fuentes estándar (Helvetica) y codificación WinAnsi, así que las tildes y la ñ salen bien.
   Uso: CLPDF.presupuesto({ clinica, ciudad, telefono, paciente, doctor, fecha, items: [{ descripcion, cant, precio }], descuento, total, seguimiento }) → Blob (application/pdf)
        CLPDF.enviar({ blob, nombre, texto, telefono, wa }) → 'compartido' | 'descargado' | 'cancelado'
   En celular y tablet abre el menú de compartir con el PDF adjunto (WhatsApp, entre otros); en computador descarga el PDF y abre el chat con el mensaje, para adjuntarlo.
   WhatsApp no deja adjuntar un archivo desde un enlace: por eso es el menú de compartir o adjuntar a mano. Todo lo que viene de la base se escribe como texto del PDF (no es HTML). */
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
    t(DER, A4[1] - 46, 'PRESUPUESTO', 2, 13, ORO, 'der'); t(DER, A4[1] - 66, d.fecha || '', 1, 10, '0.82 0.82 0.84', 'der');
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

    // objetos: 1 catálogo, 2 páginas, 3 y 4 fuentes, 5 info, luego (página, contenido) por cada hoja
    const objs = [null, null, null, null, null], n = paginas.length, kids = [];
    paginas.forEach((c, i) => { const po = 6 + i * 2, co = po + 1; kids.push(`${po} 0 R`);
      objs[po - 1] = asc(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${A4[0]} ${A4[1]}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${co} 0 R >>`);
      objs[co - 1] = [...asc(`<< /Length ${c.length} >>\nstream\n`), ...c, ...asc('\nendstream')]; });
    objs[0] = asc('<< /Type /Catalog /Pages 2 0 R >>'); objs[1] = asc(`<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${n} >>`);
    objs[2] = asc('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'); objs[3] = asc('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
    objs[4] = [...asc('<< /Title '), ...lit(`Presupuesto · ${d.paciente || ''}`), ...asc(' /Author '), ...lit(d.clinica || ''), ...asc(' /Producer (Presupuesto) >>')];
    const out = [...asc('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n')], pos = [];
    objs.forEach((o, i) => { pos.push(out.length); out.push(...asc(`${i + 1} 0 obj\n`), ...o, ...asc('\nendobj\n')); });
    const xr = out.length; out.push(...asc(`xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`)); pos.forEach(p => out.push(...asc(String(p).padStart(10, '0') + ' 00000 n \n')));
    out.push(...asc(`trailer\n<< /Size ${objs.length + 1} /Root 1 0 R /Info 5 0 R >>\nstartxref\n${xr}\n%%EOF\n`));
    return new Blob([new Uint8Array(out)], { type: 'application/pdf' });
  }

  const limpio = t => base(String(t || '')).replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '');
  async function enviar(o) {
    const nombre = o.nombre || 'Presupuesto.pdf', file = new File([o.blob], nombre, { type: 'application/pdf' });
    const tactil = /android|iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.maxTouchPoints > 1 && /Macintosh/.test(navigator.userAgent));
    if (tactil && navigator.canShare && navigator.canShare({ files: [file] })) {
      try { await navigator.share({ files: [file], title: nombre, text: o.texto }); return 'compartido'; }
      catch (e) { if (e && e.name === 'AbortError') return 'cancelado'; }   // otro error: se sigue con la descarga
    }
    const url = URL.createObjectURL(o.blob), a = document.createElement('a'); a.href = url; a.download = nombre; document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 30000);
    if (o.wa) window.open(o.wa(o.telefono || '', o.texto + '\n(Te adjunto el presupuesto en PDF.)'), '_blank', 'noopener');
    return 'descargado';
  }
  window.CLPDF = { presupuesto, enviar, nombreArchivo: (clinica, paciente, fecha) => `Presupuesto-${limpio(clinica)}-${limpio(paciente)}-${fecha || ''}.pdf`.replace(/-+\./, '.'), ancho, usd };
})();
