/* Download Center — fetches project files from the site and saves them locally.
   Also builds a ZIP of everything using JSZip. */

(function () {
  'use strict';

  // ---- File manifest -------------------------------------------------------
  var FILES = [
    {
      path: 'index.html',
      label: 'Poori website (single-file app: HTML + CSS + JS)',
      icon: 'fa-brands fa-html5',
      color: 'text-orange-400'
    },
    {
      path: 'supabase/nexaura-schema.sql',
      label: 'Database schema — tables, RLS policies, functions',
      icon: 'fa-solid fa-database',
      color: 'text-emerald-400'
    },
    {
      path: 'README.md',
      label: 'Project documentation & feature list',
      icon: 'fa-solid fa-book-open',
      color: 'text-sky-400'
    },
    {
      path: 'SETUP.md',
      label: 'Setup / installation instructions',
      icon: 'fa-solid fa-screwdriver-wrench',
      color: 'text-amber-400'
    },
    {
      path: 'GITHUB.md',
      label: 'GitHub repo aur deployment guide',
      icon: 'fa-brands fa-github',
      color: 'text-slate-300'
    },
    {
      path: 'netlify.toml',
      label: 'Netlify deploy configuration',
      icon: 'fa-solid fa-gears',
      color: 'text-teal-400'
    },
    {
      path: '.gitignore',
      label: 'Git ignore rules',
      icon: 'fa-solid fa-eye-slash',
      color: 'text-fuchsia-400'
    }
  ];

  var listEl = document.getElementById('file-list');
  var statusEl = document.getElementById('status-text');
  var zipBtn = document.getElementById('download-all-btn');
  var zipLabel = document.getElementById('download-all-label');
  var eachBtn = document.getElementById('download-each-btn');
  var progWrap = document.getElementById('progress-wrap');
  var progBar = document.getElementById('progress-bar');

  var cache = {}; // path -> Blob

  // ---- Helpers -------------------------------------------------------------
  function humanSize(bytes) {
    if (bytes === null || bytes === undefined) return '—';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
  }

  function baseName(path) {
    var parts = path.split('/');
    return parts[parts.length - 1];
  }

  function setStatus(text) {
    statusEl.textContent = text;
  }

  function setProgress(done, total) {
    if (total <= 0) return;
    progWrap.classList.remove('hidden');
    progBar.style.width = Math.round((done / total) * 100) + '%';
  }

  function hideProgress() {
    setTimeout(function () {
      progWrap.classList.add('hidden');
      progBar.style.width = '0%';
    }, 900);
  }

  function saveBlob(blob, filename) {
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
  }

  function fetchFile(path) {
    if (cache[path]) return Promise.resolve(cache[path]);
    return fetch(path, { cache: 'no-store' }).then(function (res) {
      if (!res.ok) throw new Error('HTTP ' + res.status);
      return res.blob();
    }).then(function (blob) {
      cache[path] = blob;
      return blob;
    });
  }

  // ---- Render rows ---------------------------------------------------------
  function renderRows() {
    FILES.forEach(function (file, i) {
      var li = document.createElement('li');
      li.className = 'row-anim rounded-2xl border border-slate-800 bg-slate-900/50 hover:bg-slate-900 p-4 flex flex-col sm:flex-row sm:items-center gap-4';
      li.id = 'row-' + i;

      var iconBox = document.createElement('div');
      iconBox.className = 'shrink-0 h-11 w-11 rounded-xl bg-slate-800 flex items-center justify-center';
      var icon = document.createElement('i');
      icon.className = file.icon + ' ' + file.color + ' text-lg';
      icon.setAttribute('aria-hidden', 'true');
      iconBox.appendChild(icon);

      var info = document.createElement('div');
      info.className = 'flex-1 min-w-0';
      var name = document.createElement('p');
      name.className = 'font-semibold text-slate-100 break-all';
      name.textContent = file.path;
      var desc = document.createElement('p');
      desc.className = 'text-xs text-slate-400 mt-0.5';
      desc.textContent = file.label;
      info.appendChild(name);
      info.appendChild(desc);

      var size = document.createElement('span');
      size.className = 'text-xs font-mono text-slate-500 sm:w-20 sm:text-right';
      size.id = 'size-' + i;
      size.textContent = 'checking…';

      var btn = document.createElement('button');
      btn.type = 'button';
      btn.id = 'btn-' + i;
      btn.className = 'shrink-0 inline-flex items-center justify-center gap-2 rounded-lg bg-slate-800 hover:bg-indigo-600 px-4 py-2 text-sm font-semibold text-slate-100 transition';
      btn.innerHTML = '<i class="fa-solid fa-download"></i> Download';
      btn.addEventListener('click', function () { downloadOne(file, i); });

      li.appendChild(iconBox);
      li.appendChild(info);
      li.appendChild(size);
      li.appendChild(btn);
      listEl.appendChild(li);
    });
  }

  function markUnavailable(i) {
    var sizeEl = document.getElementById('size-' + i);
    var btn = document.getElementById('btn-' + i);
    if (sizeEl) {
      sizeEl.textContent = 'N/A';
      sizeEl.className = 'text-xs font-mono text-rose-400 sm:w-20 sm:text-right';
    }
    if (btn) {
      btn.disabled = true;
      btn.className = 'shrink-0 inline-flex items-center gap-2 rounded-lg bg-slate-800/50 px-4 py-2 text-sm font-semibold text-slate-500 cursor-not-allowed';
      btn.innerHTML = '<i class="fa-solid fa-ban"></i> Not available';
    }
  }

  // ---- Probe sizes ---------------------------------------------------------
  function probeAll() {
    var done = 0;
    var jobs = FILES.map(function (file, i) {
      return fetchFile(file.path).then(function (blob) {
        var sizeEl = document.getElementById('size-' + i);
        if (sizeEl) sizeEl.textContent = humanSize(blob.size);
      }).catch(function () {
        markUnavailable(i);
      }).then(function () {
        done++;
        setProgress(done, FILES.length);
      });
    });

    return Promise.all(jobs).then(function () {
      var ok = Object.keys(cache).length;
      setStatus(ok + ' / ' + FILES.length + ' files taiyar hain.');
      hideProgress();
    });
  }

  // ---- Actions -------------------------------------------------------------
  function downloadOne(file, i) {
    var btn = document.getElementById('btn-' + i);
    if (btn) btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Ho raha hai';
    fetchFile(file.path).then(function (blob) {
      saveBlob(blob, baseName(file.path));
      if (btn) btn.innerHTML = '<i class="fa-solid fa-check"></i> Ho gaya';
      setStatus(baseName(file.path) + ' download ho gayi.');
      setTimeout(function () {
        if (btn) btn.innerHTML = '<i class="fa-solid fa-download"></i> Download';
      }, 2200);
    }).catch(function () {
      markUnavailable(i);
      setStatus(file.path + ' hasil nahi ho saki.');
    });
  }

  function downloadEach() {
    eachBtn.disabled = true;
    var available = FILES.filter(function (f) { return cache[f.path]; });
    setStatus(available.length + ' files alag alag download ho rahi hain…');
    available.forEach(function (f, idx) {
      setTimeout(function () {
        saveBlob(cache[f.path], baseName(f.path));
        setProgress(idx + 1, available.length);
        if (idx === available.length - 1) {
          setStatus('Sab files download ho gayin.');
          hideProgress();
          eachBtn.disabled = false;
        }
      }, idx * 500);
    });
  }

  function downloadZip() {
    if (typeof JSZip === 'undefined') {
      setStatus('ZIP library load nahi hui — meherbani kar ke page refresh karein.');
      return;
    }
    zipBtn.disabled = true;
    zipLabel.textContent = 'ZIP ban rahi hai…';
    setStatus('Files ZIP mein add ho rahi hain…');

    var zip = new JSZip();
    var done = 0;
    var jobs = FILES.map(function (file, i) {
      return fetchFile(file.path).then(function (blob) {
        zip.file(file.path, blob);
      }).catch(function () {
        markUnavailable(i);
      }).then(function () {
        done++;
        setProgress(done, FILES.length + 1);
      });
    });

    Promise.all(jobs).then(function () {
      setStatus('ZIP compress ho rahi hai…');
      return zip.generateAsync({ type: 'blob', compression: 'DEFLATE' }, function (meta) {
        progBar.style.width = Math.round(80 + meta.percent * 0.2) + '%';
      });
    }).then(function (blob) {
      var stamp = new Date().toISOString().slice(0, 10);
      saveBlob(blob, 'website-files-' + stamp + '.zip');
      setStatus('ZIP download ho gayi (' + humanSize(blob.size) + '). Ab isay AI Drive par upload kar dein.');
      zipLabel.textContent = 'Download All (ZIP)';
      zipBtn.disabled = false;
      hideProgress();
    }).catch(function (err) {
      setStatus('ZIP banane mein masla: ' + err.message);
      zipLabel.textContent = 'Download All (ZIP)';
      zipBtn.disabled = false;
      hideProgress();
    });
  }

  // ---- Init ----------------------------------------------------------------
  renderRows();
  zipBtn.addEventListener('click', downloadZip);
  eachBtn.addEventListener('click', downloadEach);
  probeAll();
})();
