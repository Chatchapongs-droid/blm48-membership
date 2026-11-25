/*
 * Theater Lucky Draw stage: full-screen seat draw for admins to show on stream.
 * The winner is always picked by the server (admin_draw_theater_lucky); this screen only
 * plays a seat-hopping animation that lands on the seats the server already chose.
 *
 *   blm48OpenLuckyStage(event, { draw: async () => winners })   // live draw: Start calls draw()
 *   blm48OpenLuckyStage(event)                                   // replay: event.luckyWinners
 */
(function () {
  const STYLE = `
  .ls-overlay { position: fixed; inset: 0; z-index: 21000; overflow-y: auto; font-family: 'Quicksand', 'Kanit', sans-serif; color: #2b2b2b;
    background: radial-gradient(120% 70% at 50% 0%, #fff6db 0%, #ffffff 55%); opacity: 0; transition: opacity .25s; }
  .ls-overlay.show { opacity: 1; }
  .ls-wrap { max-width: 620px; margin: 0 auto; padding: calc(16px + env(safe-area-inset-top)) 12px calc(28px + env(safe-area-inset-bottom)); min-height: 100%;
    display: flex; flex-direction: column; }
  .ls-top { display: flex; align-items: flex-start; gap: 12px; }
  .ls-top .ls-head { flex: 1; min-width: 0; }
  .ls-kicker { font-size: 11px; font-weight: 700; letter-spacing: .18em; color: #a07800; text-transform: uppercase; }
  .ls-title { font-size: 16px; font-weight: 700; margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ls-close { flex: none; width: 40px; height: 40px; border-radius: 50%; border: none; background: #f1f1f3; color: #6e6e73; font-size: 18px; cursor: pointer; }
  .ls-prize { display: flex; align-items: center; gap: 10px; margin-top: 14px; padding: 8px 10px; border-radius: 14px; background: #fffaf0; border: 1px solid #f3e2b3; }
  .ls-prize img { width: 44px; height: 44px; border-radius: 10px; object-fit: cover; background: #f3efe6; flex: none; }
  .ls-prize .k { font-size: 11px; color: #8a7a55; font-weight: 600; }
  .ls-prize .v { font-size: 13.5px; font-weight: 700; color: #4a3b12; }
  .ls-readout { position: relative; text-align: center; margin: 22px 0 18px; padding: 18px 12px 16px; border-radius: 22px; background: #fff;
    border: 1.5px solid #efe6cf; box-shadow: 0 10px 30px rgba(160, 120, 0, .08); overflow: hidden; transition: border-color .3s, box-shadow .3s; }
  .ls-readout .lbl { font-size: 11px; font-weight: 700; letter-spacing: .16em; color: #9a9a9f; text-transform: uppercase; }
  .ls-seat { font-size: clamp(54px, 17vw, 88px); line-height: 1.05; font-weight: 700; color: #2b2b2b; font-variant-numeric: tabular-nums; margin-top: 4px; }
  .ls-name { font-size: 16px; font-weight: 600; color: #555; min-height: 22px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ls-readout.is-win { border-color: #e0b953; box-shadow: 0 0 0 4px rgba(224, 185, 83, .18), 0 14px 34px rgba(160, 120, 0, .18); }
  .ls-readout.is-win .ls-seat { color: #a07800; animation: lsPop .5s cubic-bezier(.2, 1.6, .4, 1); }
  .ls-readout.is-win .lbl { color: #a07800; }
  @keyframes lsPop { from { transform: scale(.7); } to { transform: scale(1); } }
  .ls-zone { margin-bottom: 14px; }
  .ls-zone-name { font-size: 12.5px; font-weight: 700; color: #767676; margin-bottom: 8px; }
  .ls-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(42px, 1fr)); gap: 6px; }
  .ls-chip { aspect-ratio: 1 / 1; border-radius: 10px; display: flex; align-items: center; justify-content: center; font-size: 12px; font-weight: 700;
    background: #fff; border: 1.5px solid #e6e6e9; color: #555; transition: background .12s, transform .12s, border-color .12s; }
  .ls-chip.is-empty { background: #f7f7f8; border-style: dashed; color: #c4c4c8; }
  .ls-chip.is-hit { background: #ffc107; border-color: #ffc107; color: #2b2b2b; transform: scale(1.12); }
  .ls-chip.is-winner { background: linear-gradient(135deg, #ffe9a3, #e0b953); border-color: #c99a2e; color: #3b2a00; transform: scale(1.12);
    box-shadow: 0 0 0 3px rgba(224, 185, 83, .3); }
  .ls-chip.is-winner::before { content: '\\f091'; font-family: 'Font Awesome 6 Free'; font-weight: 900; font-size: 9px; margin-right: 3px; }
  .ls-winners { margin-top: 6px; }
  .ls-win-row { display: flex; align-items: center; gap: 10px; padding: 10px 0; border-bottom: 1px solid #f0f0f0; animation: lsIn .35s ease; }
  .ls-win-row .n { width: 26px; height: 26px; border-radius: 50%; flex: none; display: flex; align-items: center; justify-content: center;
    background: #fff1c4; color: #8a6400; font-size: 12px; font-weight: 700; }
  .ls-win-row .who { flex: 1; min-width: 0; font-weight: 700; font-size: 14px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ls-win-row .seat { font-weight: 700; color: #a07800; font-size: 14px; }
  @keyframes lsIn { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
  .ls-actions { margin-top: auto; padding-top: 18px; }
  .ls-btn { width: 100%; border: none; border-radius: 22px; padding: 13px 22px; background: #ffc107; color: #222; font: inherit; font-weight: 700; font-size: 15px; cursor: pointer; }
  .ls-btn:disabled { opacity: .6; cursor: default; }
  .ls-btn.is-ghost { background: #f1f1f3; color: #555; }
  .ls-msg { text-align: center; font-size: 12.5px; color: #d64545; margin-top: 8px; min-height: 16px; }
  .ls-note { text-align: center; font-size: 11.5px; color: #8e8e93; margin-top: 8px; }
  .ls-burst { position: absolute; left: 50%; top: 50%; width: 0; height: 0; pointer-events: none; }
  .ls-burst i { position: absolute; left: 0; top: 0; width: 8px; height: 8px; border-radius: 2px; opacity: 0;
    animation: lsBurst 1.1s cubic-bezier(.15, .8, .3, 1) forwards; }
  @keyframes lsBurst { 0% { opacity: 1; transform: translate(0, 0) rotate(0); } 100% { opacity: 0; transform: translate(var(--dx), var(--dy)) rotate(var(--r)); } }
  @media (prefers-reduced-motion: reduce) { .ls-burst { display: none; } .ls-readout.is-win .ls-seat { animation: none; } }`;

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
  const wait = ms => new Promise(r => setTimeout(r, ms));

  // every seat of every zone; taken seats carry the holder's name (friend's name for gifted seats)
  function buildSeats(e) {
    const owner = {};
    (e.bookings || []).filter(b => b.status === 'paid').forEach(b => {
      (b.seats || []).forEach((s, i) => {
        if (!s) return;
        const gift = (b.gifts || []).find(g => Number(g.idx) === i + 1);
        owner[s] = { name: (gift && gift.name) || b.name || b.username || '' };
      });
    });
    (e.luckyWinners || []).forEach(w => { if (w.seat && !owner[w.seat]) owner[w.seat] = { name: w.name || w.username || '' }; });
    const zones = (e.zones || []).map(z => {
      const seats = [];
      for (let n = 1; n <= Number(z.capacity || 0); n++) {
        const label = (z.seatPrefix || '') + n;
        seats.push({ label, num: n, owner: owner[label] || null });
      }
      return { name: z.name || '', seats };
    });
    // seats not covered by any zone (e.g. prefix changed) still join the draw
    const known = new Set(zones.flatMap(z => z.seats.map(s => s.label)));
    const extra = Object.keys(owner).filter(l => !known.has(l)).map(l => ({ label: l, num: l, owner: owner[l] }));
    if (extra.length) zones.push({ name: '', seats: extra });
    return zones;
  }

  window.blm48OpenLuckyStage = function (e, opts) {
    opts = opts || {};
    if (!document.getElementById('ls-style')) {
      const st = document.createElement('style'); st.id = 'ls-style'; st.textContent = STYLE; document.head.appendChild(st);
    }
    const zones = buildSeats(e);
    const taken = zones.flatMap(z => z.seats).filter(s => s.owner);
    const prize = (e.luckyPrize || [])[0] || null;
    const total = Number(e.luckyWinnerCount) || (e.luckyWinners || []).length || 1;
    const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

    const o = document.createElement('div');
    o.className = 'ls-overlay';
    o.innerHTML = `
      <div class="ls-wrap">
        <div class="ls-top">
          <div class="ls-head"><div class="ls-kicker"><i class="fa-solid fa-clover"></i> Lucky Draw</div><div class="ls-title">${esc(e.title)}</div></div>
          <button type="button" class="ls-close" aria-label="Close"><i class="fa-solid fa-xmark"></i></button>
        </div>
        ${prize ? `<div class="ls-prize">${prize.imageUrl ? `<img src="${esc(prize.imageUrl)}" alt="">` : ''}
          <div><div class="k">รางวัล · ${total} ผู้โชคดี</div><div class="v">${esc(prize.label || '')}</div></div></div>` : ''}
        <div class="ls-readout"><div class="lbl">ที่นั่ง</div><div class="ls-seat">–</div><div class="ls-name">${taken.length} ที่นั่งร่วมลุ้น</div></div>
        <div class="ls-zones">${zones.map(z => `<div class="ls-zone">${z.name ? `<div class="ls-zone-name">${esc(z.name)}</div>` : ''}
          <div class="ls-grid">${z.seats.map(s => `<div class="ls-chip${s.owner ? '' : ' is-empty'}" data-seat="${esc(s.label)}">${esc(s.num)}</div>`).join('')}</div></div>`).join('')}</div>
        <div class="ls-winners"></div>
        <div class="ls-actions"><button type="button" class="ls-btn" id="ls-go"></button><div class="ls-msg"></div>
          <div class="ls-note">${opts.draw ? 'ระบบสุ่มจากเซิร์ฟเวอร์ ที่นั่งละ 1 สิทธิ์เท่ากัน สุ่มได้ครั้งเดียว' : 'ย้อนดูผลการสุ่ม'}</div></div>
      </div>`;
    document.body.appendChild(o);
    document.documentElement.style.overflow = 'hidden';
    requestAnimationFrame(() => o.classList.add('show'));

    const chip = {};
    o.querySelectorAll('.ls-chip').forEach(c => { chip[c.dataset.seat] = c; });
    const readout = o.querySelector('.ls-readout');
    const seatEl = o.querySelector('.ls-seat');
    const nameEl = o.querySelector('.ls-name');
    const btn = o.querySelector('#ls-go');
    const msg = o.querySelector('.ls-msg');
    const list = o.querySelector('.ls-winners');
    let winners = opts.draw ? null : (e.luckyWinners || []);
    let shown = 0, running = false, closed = false, hit = null;

    function setButton() {
      if (winners && shown >= winners.length) { btn.textContent = 'เสร็จสิ้น'; btn.classList.add('is-ghost'); return; }
      btn.classList.remove('is-ghost');
      btn.innerHTML = shown === 0
        ? `<i class="fa-solid fa-clover"></i> เริ่มสุ่ม`
        : `<i class="fa-solid fa-clover"></i> สุ่มรางวัลถัดไป (${shown + 1}/${winners ? winners.length : total})`;
    }

    function show(seat) {
      if (hit) hit.classList.remove('is-hit');
      hit = chip[seat.label] || null;
      if (hit) hit.classList.add('is-hit');
      seatEl.textContent = seat.label;
      nameEl.textContent = seat.owner ? seat.owner.name : '';
    }

    async function spin(w) {
      readout.classList.remove('is-win');
      const pool = taken.filter(s => !(chip[s.label] && chip[s.label].classList.contains('is-winner')));
      const steps = reduce ? 6 : Math.min(46, 26 + pool.length);
      let prev = null;
      for (let i = 0; i < steps && pool.length > 1; i++) {
        if (closed) return;
        let s; do { s = pool[Math.floor(Math.random() * pool.length)]; } while (s === prev && pool.length > 1);
        prev = s; show(s);
        const p = i / steps;                        // fast at first, then slows right down before the stop
        await wait(reduce ? 160 : 45 + Math.pow(p, 3) * 430);
      }
      if (closed) return;
      const target = taken.find(s => s.label === w.seat) || { label: w.seat, owner: { name: w.name || w.username } };
      show(target);
      nameEl.textContent = w.name || w.username || (target.owner && target.owner.name) || '';
      if (hit) { hit.classList.remove('is-hit'); hit.classList.add('is-winner'); }
      readout.classList.add('is-win');
      burst();
      shown++;
      list.insertAdjacentHTML('beforeend', `<div class="ls-win-row"><span class="n">${shown}</span>
        <span class="who">${esc(w.name || w.username || '-')}</span><span class="seat">ที่นั่ง ${esc(w.seat || '-')}</span></div>`);
    }

    function burst() {
      if (reduce) return;
      const b = document.createElement('div');
      b.className = 'ls-burst';
      const cols = ['#ffc107', '#e0b953', '#ff85a2', '#4caf82', '#fff1c4'];
      for (let i = 0; i < 34; i++) {
        const a = Math.random() * Math.PI * 2, d = 90 + Math.random() * 150;
        const p = document.createElement('i');
        p.style.cssText = `background:${cols[i % cols.length]};--dx:${(Math.cos(a) * d).toFixed(0)}px;--dy:${(Math.sin(a) * d * .7).toFixed(0)}px;--r:${(Math.random() * 540 - 270).toFixed(0)}deg;animation-delay:${(Math.random() * .08).toFixed(2)}s`;
        b.appendChild(p);
      }
      readout.appendChild(b);
      setTimeout(() => b.remove(), 1400);
    }

    btn.addEventListener('click', async () => {
      if (running) return;
      if (winners && shown >= winners.length) { close(); return; }
      running = true; btn.disabled = true; msg.textContent = '';
      try {
        if (!winners) {
          btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> กำลังสุ่ม';
          const r = await opts.draw();
          if (!r || !r.length) throw new Error((r && r.message) || 'สุ่มไม่สำเร็จ');
          winners = r;
        }
        btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> กำลังสุ่ม';
        await spin(winners[shown]);
      } catch (err) {
        msg.textContent = err.message || 'สุ่มไม่สำเร็จ';
      } finally {
        running = false; btn.disabled = false; if (!closed) setButton();
      }
    });

    function close() {
      if (running && !winners) return;              // don't leave while the server is drawing
      closed = true;
      o.classList.remove('show');
      document.documentElement.style.overflow = '';
      setTimeout(() => o.remove(), 250);
      if (opts.onClose) opts.onClose();
    }
    o.querySelector('.ls-close').addEventListener('click', close);
    setButton();
  };
})();
