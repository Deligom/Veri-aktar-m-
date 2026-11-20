import Foundation

/// Her sayfaya (iframe'ler dahil) enjekte edilen ve video adreslerini yakalayan betik.
/// <video>/<source> etiketlerini, og:video meta etiketlerini ve fetch/XHR isteklerini izler.
enum DetectorScript {
    static let source = #"""
    (function () {
      if (window.__indirLoaded) { return; }
      window.__indirLoaded = true;

      var seen = {};
      var VIDEO_RE = /\.(mp4|m4v|mov|webm|mkv|3gp|m3u8)(\?|#|$)/i;
      var SKIP_RE = /\.(ts|m4s|aac|mp3|vtt|srt|jpg|jpeg|png|gif|webp|svg|js|css|json|html?)(\?|#|$)/i;

      function abs(u) {
        try { return new URL(u, location.href).href; } catch (e) { return null; }
      }

      function report(u, type) {
        if (!u || typeof u !== 'string') { return; }
        if (/^(blob|data):/i.test(u)) { return; }
        u = abs(u);
        if (!u || !/^https?:/i.test(u)) { return; }
        if (SKIP_RE.test(u.split('?')[0]) && !/mpegurl/i.test(type || '')) { return; }
        if (/video\/mp2t/i.test(type || '')) { return; }
        if (seen[u]) { return; }
        seen[u] = 1;
        try {
          window.webkit.messageHandlers.indir.postMessage({
            url: u,
            type: type || '',
            title: (window.top === window) ? (document.title || '') : '',
            page: location.href
          });
        } catch (e) {}
      }

      function check(u, type) {
        if (!u || typeof u !== 'string') { return; }
        if (VIDEO_RE.test(u)) { report(u, type); }
      }

      // Sayfanın yaptığı tüm ağ isteklerinin listesi (kancalardan kaçanları da yakalar)
      try { if (performance.setResourceTimingBufferSize) { performance.setResourceTimingBufferSize(3000); } } catch (e) {}
      var perfIndex = 0;
      function scanPerf() {
        try {
          var list = performance.getEntriesByType('resource');
          for (; perfIndex < list.length; perfIndex++) { check(list[perfIndex].name, ''); }
        } catch (e) {}
      }
      try {
        performance.addEventListener('resourcetimingbufferfull', function () {
          scanPerf();
          try { performance.clearResourceTimings(); } catch (e) {}
          perfIndex = 0;
        });
      } catch (e) {}

      function isPlaylistText(t) {
        return typeof t === 'string' && t.replace(/^\uFEFF/, '').slice(0, 7) === '#EXTM3U';
      }

      function scan() {
        scanPerf();
        try {
          var els = document.querySelectorAll('video, video source');
          for (var i = 0; i < els.length; i++) {
            var el = els[i];
            var s = el.currentSrc || el.src || el.getAttribute('src');
            if (s) { report(s, el.getAttribute('type') || 'video'); }
          }
          var metas = document.querySelectorAll(
            'meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"], meta[name="twitter:player:stream"]'
          );
          for (var j = 0; j < metas.length; j++) {
            var c = metas[j].getAttribute('content');
            if (c) { check(c, 'video'); }
          }
          var links = document.querySelectorAll('a[href]');
          for (var k = 0; k < links.length && k < 2000; k++) {
            check(links[k].getAttribute('href'), '');
          }
        } catch (e) {}
      }

      // fetch kancası
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          var u = null;
          try { u = (typeof input === 'string') ? input : (input && input.url); check(u, ''); } catch (e) {}
          var p = origFetch.apply(this, arguments);
          try {
            p.then(function (r) {
              try {
                var ct = (r.headers.get('content-type') || '').toLowerCase();
                var ru = r.url || u;
                if (/mpegurl|^video\//.test(ct)) { report(ru, ct); return; }
                // Uzantısız akış listeleri: içeriği "#EXTM3U" ile başlıyor mu?
                if (r.type === 'opaque' || /image|font|css|javascript|html|json|audio|video/.test(ct)) { return; }
                if (ru && SKIP_RE.test(String(ru).split('?')[0])) { return; }
                var len = parseInt(r.headers.get('content-length') || '0', 10);
                if (len > 3000000) { return; }
                r.clone().text().then(function (t) {
                  if (isPlaylistText(t)) { report(ru, 'application/x-mpegurl'); }
                }).catch(function () {});
              } catch (e) {}
            }).catch(function () {});
          } catch (e) {}
          return p;
        };
      }

      // XHR kancası
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { this.__indirUrl = String(url); check(this.__indirUrl, ''); } catch (e) {}
        return origOpen.apply(this, arguments);
      };
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var x = this;
        try {
          x.addEventListener('load', function () {
            try {
              var ct = (x.getResponseHeader('content-type') || '').toLowerCase();
              var xu = x.responseURL || x.__indirUrl;
              if (/mpegurl|^video\//.test(ct)) { report(xu, ct); return; }
              if ((x.responseType === '' || x.responseType === 'text') && isPlaylistText(x.responseText)) {
                report(xu, 'application/x-mpegurl');
              } else if (x.responseType === 'arraybuffer' && x.response && x.response.byteLength >= 7
                         && x.response.byteLength < 3000000) {
                var head = new Uint8Array(x.response, 0, 7);
                if (String.fromCharCode.apply(null, head) === '#EXTM3U') { report(xu, 'application/x-mpegurl'); }
              }
            } catch (e) {}
          });
        } catch (e) {}
        return origSend.apply(this, arguments);
      };

      document.addEventListener('play', function (e) {
        var t = e.target;
        if (t && t.tagName === 'VIDEO') {
          var s = t.currentSrc || t.src;
          if (s) { report(s, 'video'); }
          scan();
        }
      }, true);
      document.addEventListener('loadedmetadata', function () { scan(); }, true);
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);

      var pending = false;
      function schedule() {
        if (pending) { return; }
        pending = true;
        setTimeout(function () { pending = false; scan(); }, 800);
      }
      try {
        new MutationObserver(schedule).observe(document.documentElement || document, { childList: true, subtree: true });
      } catch (e) {}
      setInterval(scan, 4000);

      // Uygulamadan "yeniden tara" isteği: bu çerçeveyi ve alt çerçeveleri baştan tara
      function rescan() {
        seen = {};
        perfIndex = 0;
        scan();
        try {
          for (var f = 0; f < window.frames.length; f++) { window.frames[f].postMessage({ __indirRescan: 1 }, '*'); }
        } catch (e) {}
      }
      window.__indirRescan = rescan;
      window.addEventListener('message', function (e) {
        try { if (e.data && e.data.__indirRescan) { rescan(); } } catch (err) {}
      });
    })();
    """#
}
