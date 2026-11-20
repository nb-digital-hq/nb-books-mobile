// La página que aloja un capítulo en la vista web. No carga nada de fuera: el
// marcado llega ya saneado por el motor de NB Books, las imágenes como `data:`,
// y la navegación fuera del documento está bloqueada en la vista. Lo que hace
// aquí el JavaScript es lo mismo que hace la superficie de lectura del PC:
// paginar, situar un Locator por su cita, avisar por dónde se va y qué se
// selecciona, y pintar las marcas.

const String kLectorHtml = r'''<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
:root { --fondo:#fffdf8; --texto:#1b1b1b; --tenue:#6b6b6b; --acento:#b5651d;
  --tam:18px; --interlineado:1.6; --margen:22px; --fuente:Georgia, 'Noto Serif', serif;
  --alinear:left; }
html, body { margin:0; padding:0; background:var(--fondo); color:var(--texto);
  -webkit-touch-callout:none; -webkit-tap-highlight-color:transparent;
  -webkit-text-size-adjust:100%; overflow:hidden; height:100%; }
#marco { position:absolute; inset:0; overflow-x:hidden; overflow-y:auto;
  -webkit-overflow-scrolling:touch; }
body.paginado #marco { overflow:hidden; }
#lienzo { box-sizing:border-box; padding:calc(var(--margen) + 8px) var(--margen) 48px;
  font-family:var(--fuente); font-size:var(--tam); line-height:var(--interlineado);
  text-align:var(--alinear); hyphens:auto; -webkit-hyphens:auto; word-wrap:break-word; }
body.paginado #lienzo { height:100%; column-fill:auto; }
#lienzo img, #lienzo svg { max-width:100%; height:auto; break-inside:avoid; }
body.paginado #lienzo img { max-height:calc(100vh - 80px); object-fit:contain; }
#lienzo h1, #lienzo h2, #lienzo h3 { line-height:1.25; text-align:left; }
#lienzo a { color:inherit; }
/* Los colores del libro no mandan sobre los de la lectura: un texto negro
   fijado por el libro sobre el fondo de noche no se leería, y un fondo blanco
   suyo taparía el papel elegido. Las marcas propias van aparte. */
#lienzo, #lienzo *:not(mark):not(img):not(svg):not(svg *) {
  color:var(--texto) !important; background-color:transparent !important;
  border-color:color-mix(in srgb, var(--texto) 25%, transparent) !important; }
#lienzo p { margin:0 0 0.8em; }
mark.nb { background:color-mix(in srgb, var(--acento) 32%, transparent); color:inherit;
  border-radius:2px; }
mark.nb.subrayado { background:none; text-decoration:underline; text-decoration-color:var(--acento);
  text-decoration-thickness:2px; text-underline-offset:3px; }
mark.nb.nota { border-bottom:2px dotted var(--acento); }
::selection { background:color-mix(in srgb, var(--acento) 40%, transparent); }
</style></head>
<body><div id="marco"><div id="lienzo"></div></div>
<script>
(function () {
  const ANCLABLES = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, dd, dt, figcaption, td, th';
  const marco = document.getElementById('marco');
  const lienzo = document.getElementById('lienzo');
  let paginado = false;
  let destinoPagina = null, finDePaso = null;
  let reposo = null;
  // Un destino que llegó antes de que la vista tuviera tamaño: con ancho cero
  // no hay páginas que contar, y se aplica en cuanto lo tiene.
  let destinoPendiente = null;

  function enviar(m) { try { NB.postMessage(JSON.stringify(m)); } catch (e) {} }
  // Los bloques que no envuelven a otros: un diario dentro de una cita se
  // cuenta por sus párrafos, no como un bloque que lo contiene todo.
  function hojas() {
    return Array.from(lienzo.querySelectorAll(ANCLABLES)).filter(b => !b.querySelector(ANCLABLES));
  }
  function normal(t) { return (t || '').replace(/\s+/g, ' ').trim().toLowerCase(); }

  function ancho() { return marco.clientWidth; }
  function paginas() { return paginado ? Math.max(1, Math.round(lienzo.scrollWidth / ancho())) : 1; }
  function paginaActual() { return paginado ? Math.round(marco.scrollLeft / ancho()) : 0; }

  // Cada página mide exactamente el ancho de la vista: la columna es el ancho
  // menos los dos márgenes y el hueco entre columnas es esos dos márgenes, así
  // que pasar página es desplazar un ancho justo y nunca se arrastra media línea.
  function ajustarColumnas() {
    if (!paginado) { lienzo.style.columnWidth = ''; lienzo.style.columnGap = ''; return; }
    const m = parseFloat(getComputedStyle(lienzo).paddingLeft) || 0;
    lienzo.style.columnWidth = (ancho() - 2 * m) + 'px';
    lienzo.style.columnGap = (2 * m) + 'px';
  }

  function primerBloqueVisible() {
    const m = marco.getBoundingClientRect();
    for (const b of lienzo.querySelectorAll(ANCLABLES)) {
      // Un bloque que envuelve a otros (un diario dentro de una cita) siempre
      // está a la vista: contarlo anclaba la posición al principio del capítulo.
      if (b.querySelector(ANCLABLES)) continue;
      const c = b.getBoundingClientRect();
      const dentro = paginado ? (c.left >= m.left - 1 && c.left < m.right && c.width > 0)
                              : (c.bottom > m.top && c.top < m.bottom);
      if (dentro && (b.textContent || '').trim().length >= 8) return b;
    }
    return null;
  }

  function progresion() {
    if (paginado) { const n = paginas(); return n <= 1 ? 0 : paginaActual() / (n - 1); }
    const h = marco.scrollHeight - marco.clientHeight;
    return h <= 0 ? 0 : marco.scrollTop / h;
  }

  function publicar() {
    const b = primerBloqueVisible();
    enviar({ tipo: 'posicion', cita: b ? b.textContent.trim().slice(0, 400) : null,
             progresion: progresion(), pagina: paginaActual(), paginas: paginas() });
  }
  function alMoverse() { clearTimeout(reposo); reposo = setTimeout(publicar, 300); }
  marco.addEventListener('scroll', alMoverse, { passive: true });

  // Las imágenes cambian la altura al cargar: se vuelve a situar cuando llegan.
  function trasImagenes(f) {
    const imgs = Array.from(lienzo.querySelectorAll('img'));
    let quedan = imgs.filter(i => !i.complete).length;
    if (quedan === 0) { f(); return; }
    imgs.forEach(i => { if (!i.complete) i.addEventListener('load', () => { if (--quedan === 0) f(); },
                                                           { once: true }); });
    setTimeout(f, 600);
  }

  window.nb = {
    estilo(o) {
      const r = document.documentElement.style;
      r.setProperty('--fondo', o.fondo); r.setProperty('--texto', o.texto);
      r.setProperty('--acento', o.acento); r.setProperty('--tam', o.tam + 'px');
      r.setProperty('--interlineado', o.interlineado); r.setProperty('--margen', o.margen + 'px');
      r.setProperty('--fuente', o.fuente); r.setProperty('--alinear', o.justificar ? 'justify' : 'left');
      paginado = !!o.paginado;
      document.body.classList.toggle('paginado', paginado);
      ajustarColumnas();
    },
    cargar(html, destino) {
      lienzo.innerHTML = html;
      marco.scrollTop = 0; marco.scrollLeft = 0;
      ajustarColumnas();
      trasImagenes(() => { window.nb.situar(destino); });
      window.nb.situar(destino);
    },
    situar(d) {
      d = d || {};
      if (ancho() === 0) { destinoPendiente = d; return; }
      destinoPendiente = null;
      const cita = normal(d.cita);
      let destino = null;
      if (cita.length >= 4) {
        const bloques = hojas();
        let mejor = Infinity;
        bloques.forEach((b, i) => {
          const t = normal(b.textContent);
          if (!(t.startsWith(cita.slice(0, 120)) || (cita.startsWith(t.slice(0, 40)) && t.length >= 8))) return;
          const dist = Math.abs(i / bloques.length - (d.progresion || 0));
          if (dist < mejor) { mejor = dist; destino = b; }
        });
      }
      if (destino) {
        if (paginado) {
          const x = destino.getBoundingClientRect().left - lienzo.getBoundingClientRect().left;
          marco.scrollLeft = Math.floor(x / ancho()) * ancho();
        } else {
          marco.scrollTop = destino.offsetTop - 12;
        }
      } else if (d.alFinal) {
        if (paginado) marco.scrollLeft = (paginas() - 1) * ancho();
        else marco.scrollTop = marco.scrollHeight;
      } else if (d.progresion > 0) {
        if (paginado) marco.scrollLeft = Math.round(d.progresion * (paginas() - 1)) * ancho();
        else marco.scrollTop = d.progresion * (marco.scrollHeight - marco.clientHeight);
      }
      publicar();
    },
    // Pasa página dentro del capítulo. Devuelve si quedaba página.
    pagina(dir) {
      if (paginado) {
        // Se desliza, como una página de papel. Varios toques seguidos suman
        // sobre la página de destino, no sobre la que la animación va pasando.
        const n = (destinoPagina ?? paginaActual()) + dir;
        if (n < 0 || n >= paginas()) return false;
        destinoPagina = n;
        marco.scrollTo({ left: n * ancho(), behavior: 'smooth' });
        clearTimeout(finDePaso);
        finDePaso = setTimeout(() => { destinoPagina = null; }, 450);
        alMoverse();
        return true;
      }
      const antes = marco.scrollTop;
      marco.scrollBy({ top: dir * marco.clientHeight * 0.9, behavior: 'smooth' });
      const lim = marco.scrollHeight - marco.clientHeight;
      return dir > 0 ? antes < lim - 2 : antes > 2;
    },
    desplazar(px) {
      if (paginado) return false;
      const antes = marco.scrollTop;
      marco.scrollTop = antes + px;
      return marco.scrollTop !== antes;
    },
    // Lo que se ve, para leerlo en voz alta desde ahí.
    textoDesdeAqui() {
      const b = primerBloqueVisible();
      const todos = hojas();
      const i = b ? todos.indexOf(b) : 0;
      return todos.slice(Math.max(0, i)).map(x => x.textContent.trim()).filter(t => t).join('\n');
    },
    marcar(lista) {
      lienzo.querySelectorAll('mark.nb').forEach(m => {
        const p = m.parentNode; while (m.firstChild) p.insertBefore(m.firstChild, m); p.removeChild(m);
      });
      lienzo.normalize();
      for (const a of lista) marcarUna(a);
    },
    soltarSeleccion() { const s = window.getSelection(); if (s) s.removeAllRanges(); }
  };

  // Envuelve la cita en el capítulo. Se compara sin espacios: una cita que
  // cruza dos párrafos lleva un espacio entre ellos en el Locator y ninguno en
  // el documento. Si la frase aparece varias veces, gana la que va precedida
  // del contexto del Locator, que es la que se anotó.
  function marcarUna(a) {
    // Fuera también los caracteres invisibles que algunos libros ponen entre
    // palabras: el Locator y la página no siempre los conservan igual.
    const plegar = t => (t || '').replace(/[\s\u00ad\u200b-\u200d\u2060\ufeff]+/g, '');
    const objetivo = plegar(a.cita);
    if (objetivo.length < 2) return;
    const antes = plegar(a.antes);
    const walker = document.createTreeWalker(lienzo, NodeFilter.SHOW_TEXT);
    const pos = []; let comp = '';
    while (walker.nextNode()) {
      const n = walker.currentNode, d = n.data;
      for (let k = 0; k < d.length; k++) {
        if (!/[\s\u00ad\u200b-\u200d\u2060\ufeff]/.test(d[k])) { comp += d[k]; pos.push([n, k]); }
      }
    }
    let i = -1, mejor = -1;
    for (let at = comp.indexOf(objetivo); at >= 0; at = comp.indexOf(objetivo, at + 1)) {
      if (i < 0) i = at;
      if (antes && comp.slice(Math.max(0, at - antes.length), at) === antes) { mejor = at; break; }
    }
    if (mejor >= 0) i = mejor;
    if (i < 0) return;
    const [nIni, oIni] = pos[i];
    const [nFin, oFin] = pos[i + objetivo.length - 1];
    // Los nodos de texto entre el primero y el último, en orden.
    const nodos = [];
    const w = document.createTreeWalker(lienzo, NodeFilter.SHOW_TEXT);
    let dentro = false;
    while (w.nextNode()) {
      const n = w.currentNode;
      if (n === nIni) dentro = true;
      if (dentro) nodos.push(n);
      if (n === nFin) break;
    }
    for (const n of nodos) {
      const desde = n === nIni ? oIni : 0;
      const hasta = n === nFin ? oFin + 1 : n.data.length;
      if (hasta <= desde || !n.data.slice(desde, hasta).trim()) continue;
      const r = document.createRange();
      r.setStart(n, desde); r.setEnd(n, hasta);
      const m = document.createElement('mark');
      m.className = 'nb ' + (a.tipo === 'underline' ? 'subrayado' : a.tipo === 'note' ? 'nota' : '');
      m.dataset.id = a.id;
      try { r.surroundContents(m); } catch (e) {}
    }
  }

  // Selección propia: pulsar y mantener elige la palabra, y arrastrar sin
  // soltar la extiende hasta donde está el dedo. Es lo que hace un lector de
  // libros, y no depende del menú contextual del sistema, que en la vista web
  // incrustada cancelaba la selección nada más empezarla.
  let x0 = null, y0 = null, t0 = 0, temporizador = null, seleccionando = false, ancla = null;

  function rangoEn(x, y) { return document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null; }

  function empezarSeleccion(x, y) {
    const r = rangoEn(x, y);
    if (!r || !lienzo.contains(r.startContainer)) return;
    const s = window.getSelection();
    s.removeAllRanges();
    s.setBaseAndExtent(r.startContainer, r.startOffset, r.startContainer, r.startOffset);
    s.modify('move', 'backward', 'word');
    s.modify('extend', 'forward', 'word');
    ancla = { nodo: s.anchorNode, off: s.anchorOffset };
    seleccionando = true;
    try { navigator.vibrate && navigator.vibrate(15); } catch (e) {}
  }

  function extenderHasta(x, y) {
    const r = rangoEn(x, y);
    if (!r || !ancla || !lienzo.contains(r.startContainer)) return;
    const s = window.getSelection();
    s.setBaseAndExtent(ancla.nodo, ancla.off, r.startContainer, r.startOffset);
    const atras = s.anchorNode === s.focusNode ? s.focusOffset < s.anchorOffset
      : (s.anchorNode.compareDocumentPosition(s.focusNode) & Node.DOCUMENT_POSITION_PRECEDING);
    s.modify('extend', atras ? 'backward' : 'forward', 'word');
  }

  function avisarSeleccion() {
    const s = window.getSelection();
    const t = s ? s.toString().replace(/\s+/g, ' ').trim() : '';
    enviar({ tipo: 'seleccion', texto: t });
  }

  document.addEventListener('contextmenu', e => e.preventDefault());

  // Toques: los bordes pasan página y el centro muestra u oculta los controles.
  // Deslizar en horizontal pasa página en paginado.
  marco.addEventListener('touchstart', e => {
    const t = e.touches[0]; x0 = t.clientX; y0 = t.clientY; t0 = Date.now();
    clearTimeout(temporizador);
    // Antes que la pulsación larga del sistema (unos 500 ms), que si llega
    // primero cancela el toque y abre su propia selección.
    temporizador = setTimeout(() => empezarSeleccion(x0, y0), 380);
  }, { passive: true });

  marco.addEventListener('touchmove', e => {
    const t = e.touches[0];
    if (seleccionando) { e.preventDefault(); extenderHasta(t.clientX, t.clientY); return; }
    if (x0 !== null && (Math.abs(t.clientX - x0) > 10 || Math.abs(t.clientY - y0) > 10)) clearTimeout(temporizador);
  }, { passive: false });

  // Si el sistema se queda el toque (su pulsación larga, sus tiradores), el
  // toque se cancela en lugar de terminar: la selección que quede se avisa
  // igual, o no aparecería la barra para anotar.
  marco.addEventListener('touchcancel', () => {
    clearTimeout(temporizador);
    x0 = null;
    seleccionando = false;
    avisarSeleccion();
  }, { passive: true });

  // Mover los tiradores cambia la selección sin tocar el lienzo.
  let cambioDeSeleccion = null;
  document.addEventListener('selectionchange', () => {
    if (seleccionando) return;
    clearTimeout(cambioDeSeleccion);
    cambioDeSeleccion = setTimeout(avisarSeleccion, 250);
  });

  marco.addEventListener('touchend', e => {
    clearTimeout(temporizador);
    if (x0 === null) return;
    const t = e.changedTouches[0]; const dx = t.clientX - x0, dy = t.clientY - y0;
    x0 = null;
    if (seleccionando) { seleccionando = false; avisarSeleccion(); return; }
    const s = window.getSelection();
    if (s && s.toString().trim().length > 0) {
      // Tocar fuera de lo elegido lo suelta.
      s.removeAllRanges(); avisarSeleccion(); return;
    }
    if (paginado && Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) {
      enviar({ tipo: 'pasar', dir: dx < 0 ? 1 : -1 }); return;
    }
    if (Math.abs(dx) < 10 && Math.abs(dy) < 10 && Date.now() - t0 < 350) {
      const m = e.target.closest && e.target.closest('mark.nb');
      if (m) { enviar({ tipo: 'marca', id: m.dataset.id }); return; }
      const w = window.innerWidth; const zona = t.clientX < w * 0.25 ? -1 : t.clientX > w * 0.75 ? 1 : 0;
      enviar({ tipo: 'toque', zona });
    }
  }, { passive: true });

  window.addEventListener('resize', () => {
    const d = destinoPendiente || { progresion: progresion() };
    ajustarColumnas();
    window.nb.situar(d);
  });
  enviar({ tipo: 'listo' });
})();
</script></body></html>''';
