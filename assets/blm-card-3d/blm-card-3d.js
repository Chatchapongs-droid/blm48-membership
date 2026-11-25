/*!
 * <blm-card-3d> — layered 3D holo card (Pokémon TCG Pocket style) for the BLM48 Membership app
 * No dependencies. Works in plain HTML, React, Next.js, Vue.
 *
 *   <script src="/blm-card-3d/blm-card-3d.js"></script>
 *   <blm-card-3d src="/blm-card-3d/cards/emmy-ssr-yukata/card.json" style="width:320px"></blm-card-3d>
 *
 * Attributes
 *   src          URL of the card's card.json (layer files are loaded relative to it)
 *   static       no tilt interaction (still animates sparkle/petals gently)
 *   no-sway      don't auto-sway when idle
 *   no-flip      tap does not flip the card
 *   flipped      start showing the back
 * Methods
 *   el.flip()            flip the card
 *   el.enableGyro()      call from a tap/click on iOS to ask for motion permission
 * Events
 *   'cardflip'  (detail: {flipped})   'cardready'
 */
(() => {
  if (customElements.get('blm-card-3d')) return;
  const SCRIPT_URL = (document.currentScript && document.currentScript.src) || location.href;
  const W = 950, POP = 100;                      // logical card width, room above card for pop-out
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const rng = s => () => (s = (s * 16807) % 2147483647) / 2147483647;
  const mk = (w, h, f) => { const c = document.createElement('canvas'); c.width = w; c.height = h; f(c.getContext('2d'), w, h); return c; };
  function rr(x, cx, y, w, h, r, keep) { if (!keep) x.beginPath(); x.moveTo(cx + r, y); x.arcTo(cx + w, y, cx + w, y + h, r); x.arcTo(cx + w, y + h, cx, y + h, r); x.arcTo(cx, y + h, cx, y, r); x.arcTo(cx, y, cx + w, y, r); x.closePath(); }
  function star(x, cx, cy, r, a, col) { x.globalAlpha = a; x.fillStyle = col; x.beginPath(); x.arc(cx, cy, r * .45, 0, 7); x.fill(); x.fillRect(cx - r * 2.6, cy - .6, r * 5.2, 1.2); x.fillRect(cx - .6, cy - r * 2.6, 1.2, r * 5.2); }
  // shared sprites
  const PET = ['#ffc9dc', '#ffb3cf', '#ffe1ec', '#ffd0e2'].map(col => mk(80, 80, x => {
    x.translate(40, 40); x.fillStyle = col; x.beginPath(); x.moveTo(0, -30); x.bezierCurveTo(26, -26, 30, 10, 0, 30); x.bezierCurveTo(-30, 10, -26, -26, 0, -30); x.fill();
    x.globalCompositeOperation = 'destination-out'; x.beginPath(); x.moveTo(-6, -32); x.lineTo(0, -20); x.lineTo(6, -32); x.fill();
    x.globalCompositeOperation = 'source-atop'; const g = x.createRadialGradient(0, 8, 0, 0, 8, 30); g.addColorStop(0, 'rgba(255,255,255,.55)'); g.addColorStop(1, 'rgba(255,255,255,0)'); x.fillStyle = g; x.fillRect(-40, -40, 80, 80);
  }));
  const PETB = PET.map(p => mk(120, 120, x => { x.filter = 'blur(6px)'; x.drawImage(p, 20, 20); }));
  let fontsLoaded = null;
  function loadFonts() {
    if (fontsLoaded) return fontsLoaded;
    const base = new URL('fonts/', SCRIPT_URL).href;
    const faces = [['500', 'poppins-latin-500-normal.woff2'], ['600', 'poppins-latin-600-normal.woff2']].map(([w, f]) => new FontFace('BLMCardP', `url(${base}${f})`, { weight: w }));
    fontsLoaded = Promise.all(faces.map(f => f.load().then(ff => document.fonts.add(ff)).catch(() => {})));
    return fontsLoaded;
  }
  const CSS = `:host{display:block;position:relative;aspect-ratio:950/1450;-webkit-tap-highlight-color:transparent;touch-action:pan-y;user-select:none}
  .stage{position:absolute;inset:0;perspective:calc(var(--w,320px)*2.4)}
  .card{position:absolute;inset:0;transform-style:preserve-3d;will-change:transform}
  .face{position:absolute;inset:0;width:100%;height:100%;backface-visibility:hidden;-webkit-backface-visibility:hidden}
  .back{transform:rotateY(180deg) translateZ(var(--t,2px))}.front{transform:translateZ(var(--t,2px))}
  .edge{position:absolute;left:0;top:6.897%;width:100%;height:93.103%;border-radius:4.2%/2.96%;background:linear-gradient(135deg,#f3e1a6,#b9924a 45%,#f7e7b4 70%,#a8833f)}
  .shadow{position:absolute;left:10%;right:10%;bottom:-3%;height:7%;border-radius:50%;background:radial-gradient(closest-side,rgba(0,0,0,.22),rgba(0,0,0,0));filter:blur(8px);pointer-events:none}`;

  class BLMCard3D extends HTMLElement {
    static get observedAttributes() { return ['src', 'flipped']; }
    constructor() {
      super();
      const r = this.attachShadow({ mode: 'open' });
      r.innerHTML = `<style>${CSS}</style><div class="shadow" part="shadow"></div><div class="stage"><div class="card"><canvas class="face front" part="front"></canvas><canvas class="face back" part="back"></canvas></div></div>`;
      this.$card = r.querySelector('.card'); this.$front = r.querySelector('.front'); this.$back = r.querySelector('.back'); this.$shadow = r.querySelector('.shadow');
      for (let i = 1; i <= 6; i++) { const e = document.createElement('div'); e.className = 'edge'; e.style.transform = `translateZ(${(2 - i * .6).toFixed(2)}px)`; this.$card.insertBefore(e, this.$card.firstChild); }
      this.tx = 0; this.ty = 0; this.gx = 0; this.gy = 0; this.fv = 0; this.flipped = false; this.idle = 9; this.visible = true; this.t0 = performance.now();
      this._loop = this._loop.bind(this);
    }
    connectedCallback() {
      this._ro = new ResizeObserver(() => this._resize()); this._ro.observe(this);
      this._io = new IntersectionObserver(es => { this.visible = es[0].isIntersecting; if (this.visible) this._kick(); }); this._io.observe(this);
      const set = (e, drag) => { const b = this.getBoundingClientRect(); this.gx = clamp(((e.clientX - b.left) / b.width - .5) * 2.2, -1, 1); this.gy = clamp(((e.clientY - b.top) / b.height - .5) * 2.2, -1, 1); this.idle = 0; };
      this.addEventListener('pointermove', e => { if (!this.hasAttribute('static')) set(e); });
      this.addEventListener('pointerdown', e => { this._down = performance.now(); if (!this.hasAttribute('static')) set(e); });
      this.addEventListener('pointerleave', () => { this.gx = this.gy = 0; });
      this.addEventListener('click', () => { if (!this.hasAttribute('no-flip') && performance.now() - (this._down || 0) < 300) this.flip(); });
      this._onOri = e => { if (e.gamma == null || this.hasAttribute('static')) return; this.gx = clamp(e.gamma / 30, -1, 1); this.gy = clamp((e.beta - 45) / 30, -1, 1); this.idle = 0; };
      if (window.DeviceOrientationEvent && typeof DeviceOrientationEvent.requestPermission !== 'function') addEventListener('deviceorientation', this._onOri);
      this.flipped = this.hasAttribute('flipped'); this.fv = this.flipped ? 1 : 0;
      if (this.getAttribute('src')) this._load(this.getAttribute('src'));
    }
    disconnectedCallback() { this._ro && this._ro.disconnect(); this._io && this._io.disconnect(); removeEventListener('deviceorientation', this._onOri); cancelAnimationFrame(this._raf); this._raf = 0; }
    attributeChangedCallback(n, o, v) { if (!this.isConnected || o === v) return; if (n === 'src' && v) this._load(v); if (n === 'flipped') { this.flipped = v !== null; } }
    flip() { this.flipped = !this.flipped; this.dispatchEvent(new CustomEvent('cardflip', { detail: { flipped: this.flipped } })); this._kick(); }
    enableGyro() {
      const D = window.DeviceOrientationEvent; if (!D) return Promise.resolve(false);
      if (typeof D.requestPermission === 'function') return D.requestPermission().then(s => { if (s === 'granted') { addEventListener('deviceorientation', this._onOri); return true; } return false; }).catch(() => false);
      addEventListener('deviceorientation', this._onOri); return Promise.resolve(true);
    }
    async _load(src) {
      const url = new URL(src, location.href); const M = await (await fetch(url)).json(); const base = new URL('.', url);
      const img = p => new Promise(res => { const i = new Image(); i.crossOrigin = 'anonymous'; i.onload = () => res(i); i.onerror = () => res(null); i.src = new URL(p, base).href; });
      const L = {}; await Promise.all(Object.entries(M.layers).map(async ([k, p]) => { L[k] = await img(p); }));
      await loadFonts();
      this.M = M; this.L = L; this.CH = M.height; this.H = M.height + POP; this.B = 22; this.R = 40;
      const r1 = rng(11), r2 = rng(23), r3 = rng(77), r4 = rng(91), CT = POP, CH = this.CH, B = this.B;
      this.petMid = [...Array(16)].map(() => ({ x: r1() * W, y: CT + r1() * CH, s: 14 + r1() * 16, a: r1() * 6, v: r1() * 4 | 0, ph: r1() * 6 }));
      this.petFront = [...Array(7)].map((_, i) => ({ x: [60, 880, 120, 900, 700, 40, 820][i], y: CT + [160, 220, 1100, 980, 1280, 660, 600][i], s: 44 + r2() * 34, a: r2() * 6, v: r2() * 4 | 0, ph: r2() * 6 }));
      this.GL = [...Array(M.glitter || 1500)].map(() => ({ x: B + r3() * (W - 2 * B), y: CT + B + r3() * (CH - 2 * B), nx: r3() * 2 - 1, ny: r3() * 2 - 1, s: 1.2 + r3() * 2.8, h: r3() * 360 }));
      this.FR = [...Array(420)].map(() => { const side = r4() * 4 | 0, p = r4(); let x, y; if (side == 0) { x = p * W; y = CT + r4() * B } else if (side == 1) { x = p * W; y = CT + CH - r4() * B } else if (side == 2) { x = r4() * B; y = CT + p * CH } else { x = W - r4() * B; y = CT + p * CH } return { x, y, nx: r4() * 2 - 1, ny: r4() * 2 - 1, s: 1 + r4() * 2 }; });
      this.style.aspectRatio = `${W}/${this.H}`;
      this._resize(); this._drawBack(); this.dispatchEvent(new Event('cardready')); this._kick();
    }
    _resize() {
      if (!this.M) return; const w = this.clientWidth || 320; this.style.setProperty('--w', w + 'px');
      const k = Math.min(1.6, w * Math.min(3, devicePixelRatio || 1) / W); this.k = k;
      for (const c of [this.$front, this.$back]) { c.width = Math.round(W * k); c.height = Math.round(this.H * k); }
      this._drawBack(); this._kick();
    }
    _kick() { if (!this._raf && this.visible && this.M) this._raf = requestAnimationFrame(this._loop); }
    _loop(now) {
      this._raf = 0; if (!this.visible || !this.isConnected) return;
      const t = (now - this.t0) / 1000; this.idle += 1 / 60;
      let ax = this.gx, ay = this.gy;
      const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
      if (this.idle > 2.5 && !this.hasAttribute('no-sway') && !reduce) { ax = Math.sin(t * .8) * .55; ay = Math.sin(t * 1.1 + .5) * .4; }
      this.tx += (ax - this.tx) * .09; this.ty += (ay - this.ty) * .09; this.fv += ((this.flipped ? 1 : 0) - this.fv) * .1;
      const ry = this.tx * 24 + this.fv * 180, rx = -this.ty * 16;
      this.$card.style.transform = `rotateX(${rx.toFixed(2)}deg) rotateY(${ry.toFixed(2)}deg)`;
      this.$shadow.style.transform = `translateX(${(this.tx * 6).toFixed(1)}%) scaleX(${(Math.abs(Math.cos(ry * Math.PI / 180)) * .8 + .2).toFixed(3)})`;
      const yy = ((ry % 360) + 360) % 360;
      if (yy < 90 || yy > 270) this._drawFront(clamp(Math.sin(ry * Math.PI / 180) / .47, -1.3, 1.3), clamp(-Math.sin(rx * Math.PI / 180) / .34, -1.3, 1.3), t);
      this._raf = requestAnimationFrame(this._loop);
    }
    _frameGrad(x, tx, ty) { const CT = POP, CH = this.CH, o = (tx + ty) * 300; const g = x.createLinearGradient(-200 + o, CT - 200 + o, W + 200 + o, CT + CH + 200 + o);
      [['#f7e7b6', 0], ['#c9a252', .18], ['#fff4cf', .32], ['#b8913f', .48], ['#ffe9a8', .62], ['#c29b4b', .8], ['#fbeec4', 1]].forEach(([c, s]) => g.addColorStop(s, c)); return g; }
    _frame(x, tx, ty) { const CT = POP, CH = this.CH, B = this.B, R = this.R;
      x.save(); rr(x, 0, CT, W, CH, R); rr(x, B, CT + B, W - 2 * B, CH - 2 * B, R - 14, 1); x.fillStyle = this._frameGrad(x, tx, ty); x.fill('evenodd');
      x.strokeStyle = 'rgba(255,255,255,.75)'; x.lineWidth = 2; rr(x, B - 6, CT + B - 6, W - 2 * B + 12, CH - 2 * B + 12, R - 10); x.stroke();
      x.strokeStyle = 'rgba(120,86,30,.45)'; x.lineWidth = 1.5; rr(x, B, CT + B, W - 2 * B, CH - 2 * B, R - 14); x.stroke(); x.restore(); }
    _drawFront(tx, ty, t) {
      const x = this.$front.getContext('2d'), M = this.M, L = this.L, D = M.depth, CT = POP, CH = this.CH, B = this.B, R = this.R, H = this.H;
      x.setTransform(this.k, 0, 0, this.k, 0, 0); x.clearRect(0, 0, W, H); x.globalAlpha = 1; x.globalCompositeOperation = 'source-over';
      x.save(); rr(x, 0, CT, W, CH, R); x.clip();
      x.save(); rr(x, B, CT + B, W - 2 * B, CH - 2 * B, R - 14); x.clip();
      const bs = 1.1; if (L.bg) x.drawImage(L.bg, (W - W * bs) / 2 + tx * D.bg, CT + (CH - CH * bs) / 2 + ty * D.bg * .72, W * bs, CH * bs);
      // holo foil
      x.save(); x.globalCompositeOperation = 'overlay'; x.globalAlpha = M.holo ?? .36;
      const ang = .9 + tx * .5, off = (tx * .6 + ty * .4) * 600, cx = W / 2, cy = CT + CH / 2;
      const hg = x.createLinearGradient(cx - Math.cos(ang) * 900 + off, cy - Math.sin(ang) * 900 + off, cx + Math.cos(ang) * 900 + off, cy + Math.sin(ang) * 900 + off);
      ['#ff8fc8', '#ffe08a', '#9dffcf', '#8fd8ff', '#c9a2ff', '#ff8fc8', '#ffe08a', '#9dffcf'].forEach((c, i, a) => hg.addColorStop(i / (a.length - 1), c));
      x.fillStyle = hg; x.fillRect(0, CT, W, CH); x.restore();
      // glitter (each facet catches light at its own angle)
      x.save(); x.globalCompositeOperation = 'lighter';
      for (const g of this.GL) { const d = Math.hypot(g.nx - tx * 1.1, g.ny - ty * 1.1); if (d > .3) continue; const k = Math.pow(1 - d / .3, 2); star(x, g.x - tx * 26, g.y - ty * 19, g.s * (.8 + k * 1.3), k, `hsl(${g.h + tx * 120},100%,${80 + k * 15}%)`); }
      x.restore(); x.globalAlpha = 1;
      for (const p of this.petMid) { const sx = p.x - tx * 6 + Math.sin(t * .7 + p.ph) * 8, sy = p.y - ty * 4 + ((t * 14 + p.ph * 40) % 60) - 30; x.save(); x.translate(sx, sy); x.rotate(p.a + t * .4); x.globalAlpha = .75; x.drawImage(PET[p.v], -p.s, -p.s, p.s * 2, p.s * 2); x.restore(); }
      x.globalAlpha = 1; x.restore();
      this._frame(x, tx, ty);
      x.save(); x.globalCompositeOperation = 'lighter'; for (const g of this.FR) { const d = Math.hypot(g.nx - tx * 1.1, g.ny - ty * 1.1); if (d > .3) continue; const k = Math.pow(1 - d / .3, 2); star(x, g.x, g.y, g.s * (.7 + k), k, '#fff6d8'); } x.restore();
      x.restore();
      // person — pops out over the top frame
      if (L.person) { x.save(); x.beginPath(); x.rect(B, CT + B, W - 2 * B, CH - 2 * B); x.rect(0, 0, W, CT + B + 300); x.clip('nonzero');
        const ps = M.personScale || 1.11; x.drawImage(L.person, (W - W * ps) / 2 + tx * D.person, CT + CH - CH * ps + ty * D.person * .64 - 6, W * ps, CH * ps); x.restore(); }
      // gold signature + glints
      if (L.sign) { const sx = tx * D.sign, sy = ty * D.sign * .7; x.save(); rr(x, B, CT + B, W - 2 * B, CH - 2 * B, R - 14); x.clip(); x.drawImage(L.sign, sx, CT + sy, W, CH);
        x.globalCompositeOperation = 'lighter'; const P = M.signPoints || []; for (let i = 0; i < P.length; i++) { const ph = (i * .618) % 1 * 6.28; const k = Math.pow(Math.max(0, Math.sin(ph + tx * 5 + ty * 3 + t * .6)), 8); if (k < .05) continue; star(x, P[i][0] + sx, CT + P[i][1] + sy, 1.6 + k * 2, k, '#fff3c0'); }
        x.restore(); }
      // logo + text
      const lx = tx * D.ui, ly = ty * D.ui * .73; x.save(); if (L.title) x.drawImage(L.title, 54 + lx, CT + 44 + ly, 240, 240 * L.title.height / L.title.width);
      x.fillStyle = '#fff'; x.font = '500 15px BLMCardP, Poppins, sans-serif'; if ('letterSpacing' in x) x.letterSpacing = '4px'; if (M.text && M.text.sub) x.fillText(M.text.sub, 66 + lx, CT + 262 + ly);
      x.font = '500 18px BLMCardP, Poppins, sans-serif'; if ('letterSpacing' in x) x.letterSpacing = '2px'; if (M.text && M.text.copyright) x.fillText(M.text.copyright, 50 + lx * .6, CT + CH - 46 + ly * .6); x.restore();
      if (M.rarity) this._badge(x, W - B - 150 + tx * 20, CT + B + 26 + ty * 14, tx, M.rarity);
      x.save(); rr(x, 0, CT, W, CH, R); x.clip();
      for (const p of this.petFront) { const sx = p.x + tx * D.petals + Math.sin(t * .5 + p.ph) * 14, sy = p.y + ty * D.petals * .73 + Math.cos(t * .4 + p.ph) * 10; x.save(); x.translate(sx, sy); x.rotate(p.a + t * .25); x.globalAlpha = .8; x.drawImage(PETB[p.v], -p.s * 1.5, -p.s * 1.5, p.s * 3, p.s * 3); x.restore(); }
      x.restore();
      // glossy sleeve glare
      x.save(); rr(x, 0, CT, W, CH, R); x.clip(); x.globalCompositeOperation = 'soft-light';
      const gx = W * (.5 - tx * .6), gy = CT + CH * (.5 - ty * .6); const gl = x.createRadialGradient(gx, gy, 0, gx, gy, 900);
      gl.addColorStop(0, 'rgba(255,255,255,.55)'); gl.addColorStop(.4, 'rgba(255,255,255,.15)'); gl.addColorStop(1, 'rgba(255,255,255,0)'); x.fillStyle = gl; x.fillRect(0, 0, W, H);
      x.globalCompositeOperation = 'screen'; x.globalAlpha = .13; const sw = x.createLinearGradient(gx - 300, gy - 300, gx + 300, gy + 300); sw.addColorStop(0, 'rgba(255,255,255,0)'); sw.addColorStop(.5, 'rgba(255,255,255,.9)'); sw.addColorStop(1, 'rgba(255,255,255,0)'); x.fillStyle = sw; x.fillRect(0, 0, W, H); x.restore();
    }
    _badge(x, bx, by, tx, label) { x.save(); x.translate(bx, by); rr(x, 0, 0, 130, 58, 29); const g = x.createLinearGradient(0, 0, 130, 58), o = clamp(.5 + tx * .4);
      g.addColorStop(0, '#fff1c4'); g.addColorStop(clamp(o - .3), '#d6ad55'); g.addColorStop(o, '#fffbe6'); g.addColorStop(clamp(o + .3), '#c79a43'); g.addColorStop(1, '#f5dd96');
      x.fillStyle = g; x.fill(); x.lineWidth = 2; x.strokeStyle = 'rgba(255,255,255,.9)'; x.stroke();
      x.font = '600 30px BLMCardP, Poppins, sans-serif'; if ('letterSpacing' in x) x.letterSpacing = '4px'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillStyle = '#7a5418'; x.fillText(label, 67, 31); x.fillStyle = '#fffdf2'; x.fillText(label, 65, 29); x.restore(); }
    _drawBack() {
      if (!this.M) return; const x = this.$back.getContext('2d'), L = this.L, CT = POP, CH = this.CH, B = this.B, R = this.R;
      x.setTransform(this.k || 1, 0, 0, this.k || 1, 0, 0); x.clearRect(0, 0, W, this.H);
      x.save(); rr(x, 0, CT, W, CH, R); x.clip();
      const g = x.createLinearGradient(0, CT, W, CT + CH); g.addColorStop(0, '#2f6a45'); g.addColorStop(.5, '#3f8a55'); g.addColorStop(1, '#24543a'); x.fillStyle = g; x.fillRect(0, CT, W, CH);
      if (L.clover) { x.globalAlpha = .12; for (let yy = CT + 30; yy < CT + CH; yy += 96) for (let xx = ((yy / 96 | 0) % 2) * 48 + 20; xx < W; xx += 96) x.drawImage(L.clover, xx, yy, 52, 39); x.globalAlpha = 1; }
      const rg = x.createRadialGradient(W / 2, CT + CH / 2, 60, W / 2, CT + CH / 2, 700); rg.addColorStop(0, 'rgba(255,255,230,.28)'); rg.addColorStop(1, 'rgba(255,255,230,0)'); x.fillStyle = rg; x.fillRect(0, CT, W, CH);
      if (L.title) x.drawImage(L.title, W / 2 - 300, CT + 380, 600, 600 * L.title.height / L.title.width);
      x.font = '500 22px BLMCardP, Poppins, sans-serif'; if ('letterSpacing' in x) x.letterSpacing = '8px'; x.textAlign = 'center'; x.fillStyle = '#fff'; if (this.M.text && this.M.text.sub) x.fillText(this.M.text.sub, W / 2 + 4, CT + 920);
      if (L.blm48) x.drawImage(L.blm48, W / 2 - 110, CT + 1110, 220, 220 * L.blm48.height / L.blm48.width);
      x.restore(); this._frame(x, .2, .1);
    }
  }
  customElements.define('blm-card-3d', BLMCard3D);
})();
