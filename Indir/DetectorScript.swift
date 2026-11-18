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
        if (SKIP_RE.test(u.split('?')[0])) { return; }
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

      function scan() {
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
                var ct = r.headers.get('content-type') || '';
                if (/mpegurl|^video\//i.test(ct)) { report(r.url || u, ct); }
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
              var ct = x.getResponseHeader('content-type') || '';
              if (/mpegurl|^video\//i.test(ct)) { report(x.responseURL || x.__indirUrl, ct); }
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
    })();
    """#
}
