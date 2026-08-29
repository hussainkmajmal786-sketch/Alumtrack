/* <campus-map> — Leaflet + OSM tiles, Apple-Maps-style treatment.
   Attributes: mode="light|dark", progress="0..1" (bus position along route)
   Owns its own container + library loading so mount timing never races. */
(function () {
  const CSS_URL = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
  const CSS_INT = 'sha384-sHL9NAb7lN7rfvG5lfHpm643Xkcjzp4jFvuavGOndn6pjVqS6ny56CAt3nsEVT4H';
  const JS_URL = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js';
  const JS_INT = 'sha384-cxOPjt7s7Iz04uaHJceBmS+qpjv2JkIHNVcuOrM+YHwZOmJGBXI00mdUXEq65HTH';

  // Real coordinates: Kottayam KSRTC stand -> College of Engineering Kidangoor
  const STOPS = [
    { name: 'Kottayam KSRTC', ll: [9.5926, 76.5222] },
    { name: 'Malam', ll: [9.6140, 76.5540] },
    { name: 'Oravakal', ll: [9.6265, 76.5695] },
    { name: 'Ayarkunnam', ll: [9.6390, 76.5850] },
    { name: 'Manthadi', ll: [9.6480, 76.6015] },
    { name: 'Kidangoor Junction', ll: [9.6600, 76.6175] },
    { name: 'CEK Kidangoor', ll: [9.6655, 76.6285] },
  ];

  let libPromise = null;
  function loadLeaflet() {
    if (window.L) return Promise.resolve(window.L);
    if (libPromise) return libPromise;
    libPromise = new Promise((resolve, reject) => {
      if (!document.querySelector('link[data-leaflet]')) {
        const link = document.createElement('link');
        link.rel = 'stylesheet';
        link.href = CSS_URL;
        link.integrity = CSS_INT;
        link.crossOrigin = 'anonymous';
        link.setAttribute('data-leaflet', '');
        document.head.appendChild(link);
      }
      const s = document.createElement('script');
      s.src = JS_URL;
      s.integrity = JS_INT;
      s.crossOrigin = 'anonymous';
      s.onload = () => resolve(window.L);
      s.onerror = () => reject(new Error('leaflet failed'));
      document.head.appendChild(s);
    });
    return libPromise;
  }

  const lerp = (a, b, t) => a + (b - a) * t;

  function pointAt(progress) {
    const t = Math.max(0, Math.min(1, progress)) * (STOPS.length - 1);
    const i = Math.min(STOPS.length - 2, Math.floor(t));
    const f = t - i;
    return [lerp(STOPS[i].ll[0], STOPS[i + 1].ll[0], f), lerp(STOPS[i].ll[1], STOPS[i + 1].ll[1], f)];
  }

  const FILTERS = {
    light: 'saturate(0.58) brightness(1.07) contrast(0.93)',
    dark: 'invert(1) hue-rotate(180deg) saturate(0.5) brightness(0.72) contrast(1.06)',
  };

  class CampusMap extends HTMLElement {
    static get observedAttributes() { return ['mode', 'progress']; }

    connectedCallback() {
      if (this._built) return;
      this._built = true;
      this.style.display = 'block';
      this.style.position = 'absolute';
      this.style.inset = '0';
      this.style.overflow = 'hidden';
      // Leaflet panes use z-index 200-700; contain them so the frosted top bar
      // and bottom sheet stay above the map.
      this.style.zIndex = '0';
      this._host = document.createElement('div');
      this._host.style.cssText = 'position:absolute;inset:0;background:' + (this.mode === 'dark' ? '#141416' : '#e8e6e1');
      this.appendChild(this._host);
      this._fallback();
      loadLeaflet().then((L) => this._init(L)).catch(() => {});
    }

    get mode() { return this.getAttribute('mode') === 'dark' ? 'dark' : 'light'; }
    get progress() { return parseFloat(this.getAttribute('progress') || '0.45'); }

    attributeChangedCallback(name) {
      if (!this._built) return;
      if (name === 'mode') this._applyMode();
      if (name === 'progress') this._placeBus();
    }

    /* Plain gradient + label while tiles load or if the network is unavailable. */
    _fallback() {
      const f = document.createElement('div');
      f.style.cssText =
        'position:absolute;inset:0;display:grid;place-items:center;font:500 12px/1 -apple-system,system-ui,sans-serif;' +
        'letter-spacing:.02em;color:' + (this.mode === 'dark' ? 'rgba(235,235,245,.35)' : 'rgba(60,60,67,.4)') + ';';
      f.textContent = 'Loading map…';
      this._fb = f;
      this._host.appendChild(f);
    }

    _init(L) {
      const map = L.map(this._host, {
        zoomControl: false,
        attributionControl: true,
        zoomSnap: 0.25,
        preferCanvas: false,
      });
      this._map = map;
      if (this._fb) this._fb.remove();

      this._tiles = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '© OpenStreetMap contributors',
        maxZoom: 19,
        detectRetina: true,
      }).addTo(map);
      // A blocked or offline tile source should degrade to the plain map surface,
      // never a wall of error placeholders.
      this._tiles.on('tileerror', (e) => { if (e.tile) e.tile.style.visibility = 'hidden'; });

      const line = STOPS.map((s) => s.ll);
      this._casing = L.polyline(line, { color: '#ffffff', weight: 11, opacity: 0.9, lineCap: 'round', lineJoin: 'round' }).addTo(map);
      this._route = L.polyline(line, { color: '#007AFF', weight: 6, opacity: 1, lineCap: 'round', lineJoin: 'round' }).addTo(map);

      STOPS.forEach((s, i) => {
        const end = i === 0 || i === STOPS.length - 1;
        L.marker(s.ll, {
          interactive: false,
          keyboard: false,
          icon: L.divIcon({
            className: '',
            iconSize: end ? [14, 14] : [9, 9],
            iconAnchor: end ? [7, 7] : [4.5, 4.5],
            html:
              '<div style="width:100%;height:100%;border-radius:50%;background:#fff;box-shadow:0 0 0 ' +
              (end ? '3.5px #007AFF' : '2.5px rgba(0,122,255,.85)') + ',0 1px 3px rgba(0,0,0,.3)"></div>',
          }),
        }).addTo(map);
      });

      this._bus = L.marker(pointAt(this.progress), {
        interactive: false,
        keyboard: false,
        icon: L.divIcon({
          className: '',
          iconSize: [34, 34],
          iconAnchor: [17, 17],
          html:
            '<div style="position:relative;width:34px;height:34px">' +
            '<div style="position:absolute;inset:0;border-radius:50%;background:rgba(0,122,255,.22);animation:cm-pulse 2.4s ease-out infinite"></div>' +
            '<div style="position:absolute;inset:8px;border-radius:50%;background:#007AFF;border:2.5px solid #fff;box-shadow:0 2px 8px rgba(0,0,0,.35)"></div>' +
            '</div>',
        }),
      }).addTo(map);

      if (!document.getElementById('cm-kf')) {
        const st = document.createElement('style');
        st.id = 'cm-kf';
        st.textContent =
          '@keyframes cm-pulse{0%{transform:scale(.55);opacity:.9}70%{transform:scale(1.5);opacity:0}100%{opacity:0}}' +
          '.leaflet-container{background:transparent;font-family:-apple-system,system-ui,sans-serif}' +
          '.leaflet-control-attribution{font-size:8.5px;padding:1px 5px;border-radius:6px 0 0 0;background:rgba(255,255,255,.6);backdrop-filter:blur(8px)}' +
          '.leaflet-control-attribution a{color:inherit}';
        document.head.appendChild(st);
      }

      this.recenter(false);
      this._applyMode();
      setTimeout(() => map.invalidateSize(), 60);
      this._ro = new ResizeObserver(() => map.invalidateSize());
      this._ro.observe(this);
    }

    _applyMode() {
      const dark = this.mode === 'dark';
      this._host.style.background = dark ? '#141416' : '#e8e6e1';
      if (!this._map) return;
      const pane = this._map.getPane('tilePane');
      if (pane) pane.style.filter = FILTERS[dark ? 'dark' : 'light'];
      const acc = dark ? '#0A84FF' : '#007AFF';
      this._route.setStyle({ color: acc });
      this._casing.setStyle({ color: dark ? 'rgba(20,20,22,.85)' : '#ffffff' });
      const attr = document.querySelector('.leaflet-control-attribution');
      if (attr) {
        attr.style.background = dark ? 'rgba(28,28,30,.6)' : 'rgba(255,255,255,.6)';
        attr.style.color = dark ? 'rgba(235,235,245,.5)' : 'rgba(60,60,67,.6)';
      }
    }

    _placeBus() {
      if (this._bus) this._bus.setLatLng(pointAt(this.progress));
    }

    /* Frames the live segment of the route, biased upward so the bottom sheet
       does not cover the bus. */
    recenter(animate = true) {
      if (!this._map) return;
      const L = window.L;
      const p = pointAt(this.progress);
      const b = L.latLngBounds([STOPS[2].ll, STOPS[4].ll]).extend(p).pad(0.35);
      this._map.fitBounds(b, {
        paddingTopLeft: [16, 40],
        paddingBottomRight: [16, 250],
        animate,
        duration: 0.6,
      });
    }
  }

  if (!customElements.get('campus-map')) customElements.define('campus-map', CampusMap);
  window.CAMPUS_STOPS = STOPS;
})();
