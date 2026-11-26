/*
 * Listado con estilo del servidor de paquetes — Once UI + VasakOS.
 *
 * El servidor manda el autoindex de nginx en JSON (autoindex_format json) y este
 * archivo lo convierte en una tabla interactiva. No hay backend: todo lo que se
 * ve sale del JSON que nginx ya escribe, más `vasakos.json` cuando existe en la
 * carpeta, que es el que agrega versión, arquitectura y descripción a los paquetes.
 *
 * Para las pruebas se carga con Node, que no tiene `document`: en ese caso sólo
 * se exportan las funciones puras y no se toca el DOM.
 */
(function (global) {
  'use strict';

  /** Los .sig acompañan a un archivo y `vasakos.json` es la fuente de este mismo listado. */
  const HIDDEN = /(\.sig|^vasakos\.json)$/;
  /** El índice que baja pacman. Se muestra aparte, plegado, para no tapar los paquetes. */
  const PACKAGE_INDEX = /^vasakos\.(db|files)$/;
  const PACKAGE = /\.pkg\.tar\.(zst|xz)$/;
  const KIND_FOLDER = 'carpeta';
  const KIND_PACKAGE = 'paquete';
  const KIND_INDEX = 'índice';
  const KIND_FILE = 'archivo';

  function formatBytes(bytes) {
    if (typeof bytes !== 'number' || !Number.isFinite(bytes) || bytes < 0) return '—';
    if (bytes < 1024) return bytes + ' B';
    const units = ['kB', 'MB', 'GB', 'TB'];
    let value = bytes;
    let unit = -1;
    do {
      value /= 1024;
      unit += 1;
    } while (value >= 1024 && unit < units.length - 1);
    const digits = value < 10 ? 1 : 0;
    // Solo quita ceros finales si hay parte fraccionaria: 102400 → "100 kB", 1536 → "1.5 kB"
    const fixed = value.toFixed(digits);
    return (fixed.includes('.') ? fixed.replace(/\.?0+$/, '') : fixed) + ' ' + units[unit];
  }

  function formatDate(value) {
    if (!value) return '—';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return '—';
    return new Intl.DateTimeFormat('es', { day: 'numeric', month: 'short', year: 'numeric' }).format(date);
  }

  /** `apparmor.d-tools-0.4916.0-1-x86_64.pkg.tar.zst` → nombre, versión, arquitectura. */
  function parsePackageName(filename) {
    const match = /^(.+)-([^-]+)-([^-]+)-(x86_64|any|aarch64)\.pkg\.tar\.(zst|xz)$/.exec(filename);
    if (!match) return { name: filename, version: '', arch: '' };
    return { name: match[1], version: match[2] + '-' + match[3], arch: match[4] };
  }

  /** `/repo/x86_64/vasakos/` → las migas de pan hasta ahí. La carpeta actual no se enlaza. */
  function buildCrumbs(pathname) {
    const parts = pathname.split('/').filter(Boolean);
    const crumbs = [{ label: 'repositorio', href: '/' }];
    let href = '';
    parts.forEach((part) => {
      href += '/' + part;
      crumbs.push({ label: decodeURIComponent(part), href: href + '/' });
    });
    return crumbs;
  }

  /**
   * Del JSON de nginx a carpetas y archivos con lo que hace falta para dibujarlos.
   * `index` es el `vasakos.json` de la carpeta (o null): el nombre de un paquete no
   * se puede adivinar del archivo con certeza, así que cuando está se usa ése.
   */
  function organise(entries, index) {
    if (!Array.isArray(entries)) return { folders: [], files: [] };
    const byFilename = new Map();
    const packages = index && Array.isArray(index.packages) ? index.packages : [];
    packages.forEach((pkg) => byFilename.set(pkg.filename, pkg));

    const folders = [];
    const files = [];
    entries.forEach((entry) => {
      const name = entry && entry.name;
      if (!name || name === '../' || HIDDEN.test(name)) return;
      if (entry.type === 'directory') {
        folders.push({ name, label: name, href: encodeURIComponent(name) + '/', kind: KIND_FOLDER, mtime: entry.mtime });
        return;
      }
      const href = encodeURIComponent(name);
      const pkg = byFilename.get(name);
      if (PACKAGE.test(name)) {
        const parsed = pkg || parsePackageName(name);
        files.push({
          name,
          label: parsed.name,
          href,
          kind: KIND_PACKAGE,
          version: parsed.version,
          arch: (pkg && pkg.arch) || parsed.arch || '',
          desc: pkg && pkg.desc ? pkg.desc : '',
          install: parsed.name,
          size: entry.size,
          mtime: entry.mtime,
        });
        return;
      }
      files.push({
        name,
        label: name,
        href,
        kind: PACKAGE_INDEX.test(name) ? KIND_INDEX : KIND_FILE,
        version: '',
        arch: '',
        desc: '',
        install: '',
        size: entry.size,
        mtime: entry.mtime,
      });
    });

    return { folders, files };
  }

  /** Lo que cuenta el encabezado: paquetes y su tamaño, o carpetas si no hay archivos. */
  function summarise(organised) {
    const packages = organised.files.filter((file) => file.kind === KIND_PACKAGE);
    const bytes = packages.reduce((total, file) => total + (Number.isFinite(file.size) ? file.size : 0), 0);
    return {
      packages: packages.length,
      bytes,
      folders: organised.folders.length,
      newest: organised.files.concat(organised.folders).reduce((latest, entry) => {
        const when = new Date(entry.mtime).getTime();
        return Number.isNaN(when) ? latest : Math.max(latest, when);
      }, 0),
    };
  }

  /** Sin acentos y en minúsculas: «versión» tiene que encontrarse escribiendo «version». */
  function normalise(text) {
    return String(text || '')
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .toLowerCase();
  }

  function matches(entry, query) {
    if (!query) return true;
    const haystack = [entry.name, entry.label, entry.kind, entry.version, entry.desc, entry.arch].join(' ');
    return normalise(haystack).includes(query);
  }

  const api = { formatBytes, formatDate, parsePackageName, buildCrumbs, organise, summarise, normalise, matches };
  if (typeof module === 'object' && module.exports) {
    module.exports = api;
    return;
  }
  if (!global.document) return;

  const doc = global.document;
  const state = { folders: [], files: [], query: '' };

  function el(tag, className, text) {
    const node = doc.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function icon(name, className) {
    const i = doc.createElement('i');
    i.className = 'icon icon-' + name + (className ? ' ' + className : '');
    i.setAttribute('aria-hidden', 'true');
    return i;
  }

  function renderCrumbs() {
    const nav = doc.getElementById('breadcrumb');
    if (!nav) return;
    const crumbs = buildCrumbs(global.location.pathname);
    nav.textContent = '';
    crumbs.forEach((crumb, position) => {
      const last = position === crumbs.length - 1;
      if (position > 0) nav.append(el('span', 'sep', '/'));
      if (last) {
        const current = el('span', 'here', crumb.label);
        current.setAttribute('aria-current', 'page');
        nav.append(current);
      } else {
        const link = el('a', '', crumb.label);
        link.href = crumb.href;
        nav.append(link);
      }
    });
    const heading = doc.getElementById('page-title');
    if (heading) heading.textContent = crumbs[crumbs.length - 1].label;
    doc.title = crumbs[crumbs.length - 1].label + ' · VasakOS repositorio';
  }

  function copyCommand(button, command) {
    if (!global.navigator.clipboard || !global.navigator.clipboard.writeText) return;
    global.navigator.clipboard.writeText(command).then(() => {
      const original = button.innerHTML;
      button.innerHTML = '';
      button.append('Copiado');
      button.disabled = true;
      global.setTimeout(() => {
        button.innerHTML = original;
        button.disabled = false;
      }, 1500);
    }, () => {});
  }

  function folderItem(folder) {
    const item = el('li', 'folder-item');
    const link = el('a', 'folder-link', '');
    link.href = folder.href;
    link.append(icon('folder'), folder.name);
    item.append(link, el('span', 'folder-meta', formatDate(folder.mtime)));
    return item;
  }

  function fileRow(file) {
    const row = el('tr');
    const name = el('td', 'col-name');
    const link = el('a', 'file-name' + (file.kind === KIND_PACKAGE ? ' package' : ''), '');
    link.href = file.href;
    link.title = file.name; // el archivo exacto en tooltip

    const iconClass = file.kind === KIND_PACKAGE ? 'package' :
                      file.kind === KIND_INDEX ? 'database' :
                      file.kind === KIND_FOLDER ? 'folder' : 'file';
    link.append(icon(iconClass), file.label);
    if (file.desc) link.append(el('span', 'file-desc', file.desc));
    if (file.arch) link.append(el('span', 'file-arch', file.arch));
    name.append(link);

    const version = el('td', 'col-version', file.version || '—');
    const size = el('td', 'col-size', formatBytes(file.size));
    const date = el('td', 'col-date', formatDate(file.mtime));
    const action = el('td', 'col-action');
    if (file.install) {
      const button = el('button', 'btn-copy', '');
      button.type = 'button';
      button.setAttribute('aria-label', 'Copiar el comando para instalar ' + file.install);
      button.append(icon('copy'), 'Copiar');
      button.addEventListener('click', () => copyCommand(button, 'sudo pacman -S ' + file.install));
      action.append(button);
    }
    row.append(name, version, size, date, action);
    return row;
  }

  function table(rows) {
    const wrap = el('div', 'table-wrap');
    const node = el('table', 'files-table');
    node.append(el('caption', 'sr-only', 'Archivos de esta carpeta'));
    const head = el('thead');
    const headRow = el('tr');
    ['Nombre', 'Versión', 'Tamaño', 'Fecha', ''].forEach((label) => {
      const cell = el('th', '', label);
      cell.scope = 'col';
      headRow.append(cell);
    });
    head.append(headRow);
    const body = el('tbody');
    rows.forEach((row) => body.append(row));
    node.append(head, body);
    wrap.append(node);
    return wrap;
  }

  function paint() {
    const listing = doc.getElementById('listing');
    const meta = doc.getElementById('toolbar-meta');
    if (!listing || !meta) return;

    const folders = state.folders.filter((folder) => matches(folder, state.query));
    const files = state.files.filter((file) => file.kind !== KIND_INDEX && matches(file, state.query));
    const indexes = state.files.filter((file) => file.kind === KIND_INDEX);

    if (state.query) {
      const total = folders.length + files.length;
      meta.textContent = total === 0 ? 'Nada coincide con «' + state.query.trim() + '»' : total + (total === 1 ? ' resultado' : ' resultados');
    } else {
      const summary = summarise(state);
      const parts = [];
      if (summary.packages) parts.push(summary.packages + (summary.packages === 1 ? ' paquete' : ' paquetes'));
      if (summary.folders) parts.push(summary.folders + (summary.folders === 1 ? ' carpeta' : ' carpetas'));
      if (summary.packages) parts.push(formatBytes(summary.bytes));
      if (summary.newest) parts.push('actualizado el ' + formatDate(new Date(summary.newest).toUTCString()));
      meta.textContent = parts.join(' · ');
    }

    listing.textContent = '';

    if (folders.length) {
      const section = el('section', 'group');
      section.append(el('h2', 'group-title', 'Carpetas'));
      const list = el('ul', 'folders');
      folders.forEach((folder) => list.append(folderItem(folder)));
      section.append(list);
      listing.append(section);
    }

    if (files.length) {
      const section = el('section', 'group');
      section.append(el('h2', 'group-title', 'Archivos'));
      section.append(table(files.map(fileRow)));
      listing.append(section);
    }

    if (!folders.length && !files.length && !state.query) {
      listing.append(el('p', 'empty-state', 'Esta carpeta está vacía.'));
    }

    if (indexes.length && !state.query) {
      const details = el('details', 'indexes');
      details.append(el('summary', '', 'Índice de pacman'));
      indexes.forEach((file) => {
        const p = el('p', '');
        const link = el('a', 'index-link', '');
        link.href = file.href;
        link.append(icon('database'), file.name);
        p.append(link, el('span', 'index-meta', ' · ' + formatBytes(file.size) + ' · ' + formatDate(file.mtime)));
        details.append(p);
      });
      details.append(el('p', 'index-note', 'Lo descarga pacman al actualizar; no hace falta bajarlo a mano.'));
      listing.append(details);
    }
  }

  function readIndex(entries) {
    const hasIndex = entries.some((entry) => entry && entry.name === 'vasakos.json');
    if (!hasIndex) return Promise.resolve(null);
    return global
      .fetch(new URL('vasakos.json', global.location.href).href, { cache: 'no-cache' })
      .then((response) => (response.ok ? response.json() : null))
      .catch(() => null);
  }

  function start() {
    renderCrumbs();
    const holder = doc.getElementById('entries-data');
    let entries;
    try {
      entries = JSON.parse(holder ? holder.textContent : '[]');
    } catch (error) {
      entries = [];
    }

    const paintWith = (index) => {
      const organised = organise(entries, index);
      state.folders = organised.folders;
      state.files = organised.files;
      paint();
    };

    // Sin el json de la carpeta igual se ve todo: sólo falta versión y descripción.
    paintWith(null);
    readIndex(Array.isArray(entries) ? entries : []).then((index) => {
      if (!index) return;
      const organised = organise(entries, index);
      state.folders = organised.folders;
      state.files = organised.files;
      paint();
    });

    const filter = doc.getElementById('filter-input');
    const clearBtn = doc.querySelector('.clear-btn');
    if (filter) {
      filter.addEventListener('input', () => {
        state.query = normalise(filter.value).trim();
        paint();
        if (clearBtn) clearBtn.hidden = !state.query;
      });
      if (clearBtn) {
        clearBtn.addEventListener('click', () => {
          filter.value = '';
          state.query = '';
          clearBtn.hidden = true;
          paint();
          filter.focus();
        });
      }
    }
  }

  start();
})(typeof globalThis !== 'undefined' ? globalThis : this);