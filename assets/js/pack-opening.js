// 🎴 ฉากเปิดซองสุ่ม (ธีมมินิมอลโทนขาว — ท่วงท่าแบบเกมเปิดแพ็คการ์ด)
// ลำดับ: ซองลอยเข้ามาหมุนกลางเวทีขาว → กล้องซูมเข้าหารอยปะ → ลากนิ้วตัดตามรอยปะ → แถบบนกระเด็นหมุนหลุดไป ซองตกลง
//        → กองของลอยขึ้นจากล่าง → ดูทีละชิ้น (เอียงตามนิ้ว/เมาส์ มีแสงสะท้อน) ปัดซ้าย/ขวาหรือแตะเพื่อดูชิ้นถัดไป
// ของ SSR: พื้นหลังเปลี่ยนเป็นโฮโลพาสเทล + ประกายรุ้งบนรูป ; ซองที่มี SSR ข้างใน = ซองมุกโฮโลเรืองแสงตั้งแต่ก่อนฉีก
// ใช้: await blm48OpenPacks([{ cover, name, cards: [{ image, label, isSSR }] }, ...])  (หนึ่งซองต่อหนึ่งรายการสุ่ม)
// resolve เมื่อผู้ใช้เปิดครบทุกซองแล้วกดปุ่มสรุป หรือกด "Skip" แล้วกดปุ่มสรุป
(function () {
  const TEAR_DONE = 0.62; // ลากเกินสัดส่วนนี้ของความกว้างซอง = ตัดขาด
  const SWIPE_OUT = 60;   // ปัดการ์ดเกินกี่ px = ปัดทิ้งไปชิ้นถัดไป
  const reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
  function cssUrl(s) { return String(s || '').replace(/["\\\n\r]/g, '\\$&'); }
  function vibrate(p) { try { if (navigator.vibrate) navigator.vibrate(p); } catch (e) {} }

  function injectStyles() {
    if (document.getElementById('blm48-pack-style')) return;
    const st = document.createElement('style');
    st.id = 'blm48-pack-style';
    st.textContent = `
      .po-overlay { position: fixed; inset: 0; z-index: 20500; overflow: hidden; font-family: 'Quicksand', 'Kanit', sans-serif; color: #1d1d1f;
        background: radial-gradient(120% 80% at 50% 32%, #ffffff 0%, #f7f7f9 55%, #ececf0 100%);
        touch-action: none; user-select: none; -webkit-user-select: none; -webkit-tap-highlight-color: transparent;
        display: flex; flex-direction: column; align-items: center; justify-content: center; opacity: 0; transition: opacity 0.35s; }
      .po-overlay.show { opacity: 1; }
      .po-overlay * { box-sizing: border-box; }
      /* พื้นหลังโฮโลพาสเทล (โผล่ตอนเจอ SSR / ซองพิเศษ) */
      .po-holo-bg { position: absolute; inset: 0; opacity: 0; transition: opacity 0.7s ease; pointer-events: none;
        background: radial-gradient(70% 50% at 50% 42%, rgba(255,255,255,0.85), rgba(255,255,255,0) 70%),
          linear-gradient(90deg, #fff1f8, #f1edff, #e9f8ff, #ecfff3, #fffbea, #fff1f8);
        background-size: 100% 100%, 300% 100%; animation: po-holo-move 9s linear infinite; }
      .po-overlay.holo .po-holo-bg { opacity: 1; }
      @keyframes po-holo-move { from { background-position: 0 0, 0% 50%; } to { background-position: 0 0, 150% 50%; } }
      /* พื้นเวที: เงาวงรีใต้ของ */
      .po-floor { position: absolute; left: 50%; top: 50%; width: min(80vw, 340px); height: 34px; margin: calc(min(32vw, 135px) * 1.6 + 26px) 0 0 calc(min(80vw, 340px) / -2);
        border-radius: 50%; background: radial-gradient(closest-side, rgba(20,20,40,0.13), rgba(20,20,40,0)); pointer-events: none; transition: opacity 0.4s, transform 0.5s; }

      .po-topbar { position: absolute; left: 0; right: 0; top: 0; padding: calc(14px + env(safe-area-inset-top)) 14px 0; display: flex;
        align-items: center; justify-content: space-between; z-index: 6; }
      .po-count { font-size: 12px; font-weight: 600; color: #8a8a8e; letter-spacing: 0.5px; min-height: 16px; }
      .po-dots { display: flex; gap: 5px; margin-top: 6px; }
      .po-dots i { width: 6px; height: 6px; border-radius: 50%; background: rgba(29,29,31,0.14); transition: background 0.3s, transform 0.3s; }
      .po-dots i.on { background: #1d1d1f; }
      .po-dots i.cur { transform: scale(1.35); }
      .po-skip { border: 1px solid rgba(29,29,31,0.1); border-radius: 999px; padding: 7px 16px; background: rgba(255,255,255,0.75);
        color: #1d1d1f; font-family: inherit; font-size: 13px; font-weight: 600; cursor: pointer; backdrop-filter: none; }

      .po-stage { position: relative; width: min(64vw, 270px); aspect-ratio: 5 / 8; perspective: 1100px; z-index: 2; }

      /* ===== ซอง ===== */
      .po-pack { position: absolute; inset: 0; z-index: 3; transform-style: preserve-3d;
        transition: transform 0.65s cubic-bezier(0.3, 0.9, 0.3, 1), opacity 0.5s; }
      .po-pack.focus { transform: translateY(4%) scale(1.07); }
      .po-pack.drop { transform: translateY(135%) scale(0.94) rotate(4deg); opacity: 0;
        transition: transform 0.6s cubic-bezier(0.55, 0, 0.8, 0.3), opacity 0.45s 0.15s; }
      .po-pack-inner { position: absolute; inset: 0; transform-style: preserve-3d; }
      .po-pack.enter .po-pack-inner { animation: po-enter 0.95s cubic-bezier(0.2, 0.85, 0.25, 1) both; }
      .po-pack.idle .po-pack-inner { animation: po-float 3.2s ease-in-out infinite; }
      @keyframes po-enter {
        0% { transform: translateY(70vh) rotateY(-70deg) rotateZ(-8deg) scale(0.7); opacity: 0; }
        45% { opacity: 1; }
        75% { transform: translateY(-3%) rotateY(8deg) rotateZ(1deg) scale(1.02); }
        100% { transform: none; } }
      @keyframes po-float { 0%,100% { transform: translateY(0) rotateY(-7deg) rotateZ(-0.6deg); } 50% { transform: translateY(-7px) rotateY(7deg) rotateZ(0.6deg); } }

      .po-part { position: absolute; left: 0; right: 0; overflow: hidden;
        background: linear-gradient(135deg, #ffffff 0%, #f1f1f4 24%, #ffffff 46%, #e9e9ee 70%, #ffffff 100%); }
      .po-top { top: 0; height: 16%; border-radius: 10px 10px 0 0; transform-origin: 100% 100%; z-index: 3; }
      .po-body { top: 15.5%; bottom: 0; border-radius: 0 0 10px 10px; z-index: 2;
        box-shadow: 0 26px 50px -12px rgba(20,20,45,0.22), 0 0 0 1px rgba(29,29,31,0.05) inset; }
      .po-top { box-shadow: 0 0 0 1px rgba(29,29,31,0.05) inset; }
      /* รอยหยักซีลซองบน/ล่าง */
      .po-top::before, .po-body::after { content: ''; position: absolute; left: 0; right: 0; height: 8px;
        background: repeating-linear-gradient(90deg, rgba(29,29,31,0.09) 0 2px, rgba(255,255,255,0.6) 2px 5px); }
      .po-top::before { top: 0; } .po-body::after { bottom: 0; }
      .po-art { position: absolute; left: 9%; right: 9%; top: 8%; bottom: 20%; border-radius: 6px; overflow: hidden; background: #f0f0f3;
        box-shadow: 0 0 0 1px rgba(29,29,31,0.06); }
      .po-art img { width: 100%; height: 100%; object-fit: cover; pointer-events: none; }
      .po-name { position: absolute; left: 8%; right: 8%; bottom: 7.5%; text-align: center; color: #1d1d1f; font-weight: 700; font-size: 13px;
        letter-spacing: 0.2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .po-brand { position: absolute; left: 0; right: 0; bottom: 3.6%; text-align: center; font-size: 8.5px; letter-spacing: 3px; color: #a1a1a6; font-weight: 600; }
      .po-top .po-mini { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: #a1a1a6;
        font-weight: 700; font-size: 10px; letter-spacing: 4px; }
      .po-sheen { position: absolute; inset: 0; pointer-events: none;
        background: linear-gradient(110deg, transparent 32%, rgba(214,218,232,0.45) 42%, rgba(255,255,255,0.95) 48%, rgba(214,218,232,0.45) 54%, transparent 64%);
        background-size: 260% 100%; animation: po-sheen 3.6s ease-in-out infinite; }
      @keyframes po-sheen { 0% { background-position: 160% 0; } 60%,100% { background-position: -70% 0; } }

      /* ซองพิเศษ (มี SSR ข้างใน): มุกโฮโล + รัศมีพาสเทลเต้นเบาๆ */
      .po-stage.special .po-part { background: linear-gradient(120deg, #ffffff 0%, #ffeef7 18%, #f0edff 36%, #e7f8ff 54%, #effff4 72%, #fffbe9 88%, #ffffff 100%);
        background-size: 260% 260%; animation: po-pearl 4s ease-in-out infinite; }
      @keyframes po-pearl { 0%,100% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } }
      .po-halo { position: absolute; inset: -22%; border-radius: 50%; z-index: 0; pointer-events: none; opacity: 0; transition: opacity 0.6s;
        background: radial-gradient(closest-side, rgba(255,214,236,0.85), rgba(214,226,255,0.55) 45%, rgba(220,255,240,0.25) 70%, transparent);
        animation: po-halo 2.2s ease-in-out infinite; }
      .po-stage.special .po-halo { opacity: 1; }
      @keyframes po-halo { 0%,100% { transform: scale(0.9); } 50% { transform: scale(1.05); } }

      /* รอยปะ + จุดนำทางวิ่งตามรอยปะ */
      .po-guide { position: absolute; left: -5%; right: -5%; top: 15.6%; height: 0; z-index: 4; pointer-events: none;
        border-top: 1.5px dashed rgba(29,29,31,0.32); opacity: 0; transition: opacity 0.35s; }
      .po-cut { position: absolute; left: -5%; top: calc(15.6% - 1px); height: 3px; width: 0; z-index: 5; pointer-events: none; border-radius: 3px;
        background: #1d1d1f; box-shadow: 0 0 0 3px rgba(255,255,255,0.9), 0 0 14px 4px rgba(255,255,255,0.95); transition: opacity 0.3s; }
      .po-finger { position: absolute; top: calc(15.6% - 7px); left: -5%; z-index: 6; width: 14px; height: 14px; border-radius: 50%; pointer-events: none;
        background: #1d1d1f; box-shadow: 0 0 0 4px rgba(255,255,255,0.95), 0 4px 12px rgba(0,0,0,0.25); opacity: 0; }
      .po-stage.ready .po-guide { opacity: 1; }
      .po-stage.ready .po-finger { animation: po-finger 1.7s cubic-bezier(0.45, 0, 0.3, 1) infinite; }
      @keyframes po-finger { 0% { transform: translateX(0) scale(0.6); opacity: 0; } 15% { opacity: 1; transform: translateX(8%) scale(1); }
        78% { opacity: 1; } 100% { transform: translateX(calc(min(64vw, 270px) * 1.02)) scale(0.8); opacity: 0; } }
      .po-ring { position: absolute; z-index: 7; width: 30px; height: 30px; margin: -15px 0 0 -15px; border-radius: 50%; pointer-events: none;
        border: 1.5px solid rgba(29,29,31,0.35); animation: po-ring 0.7s ease-out forwards; }
      .po-ring.holo { border: 2px solid rgba(190,170,255,0.8); }
      @keyframes po-ring { from { transform: scale(0.3); opacity: 1; } to { transform: scale(9); opacity: 0; } }
      .po-whiteout { position: fixed; inset: 0; z-index: 20550; pointer-events: none; opacity: 0; background: #fff; animation: po-white 0.55s ease-out forwards; }
      @keyframes po-white { 0% { opacity: 0; } 20% { opacity: 0.9; } 100% { opacity: 0; } }

      /* ===== กองของที่ได้ (รูปจริงตามรูปทรง ไม่มีกรอบการ์ด) ===== */
      .po-cards { position: absolute; inset: 0 0 6%; z-index: 2; opacity: 0; pointer-events: none; }
      .po-cards.rise { opacity: 1; animation: po-rise 0.7s cubic-bezier(0.2, 0.9, 0.25, 1.08) both; pointer-events: auto; }
      @keyframes po-rise { from { transform: translateY(75%) scale(0.86); opacity: 0; } to { transform: none; opacity: 1; } }
      .po-card { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; perspective: 900px;
        opacity: 0; transform: translateY(4%) scale(0.9); pointer-events: none;
        transition: transform 0.5s cubic-bezier(0.25, 1, 0.35, 1), opacity 0.35s; }
      .po-card.top { opacity: 1; transform: none; pointer-events: auto; cursor: grab; }
      .po-card.next { opacity: 0; transform: translateY(3%) scale(0.94); }
      .po-card.drag { transition: none; cursor: grabbing; }
      .po-card.gone { opacity: 0; pointer-events: none; transition: transform 0.45s cubic-bezier(0.5, 0, 0.75, 0.4), opacity 0.4s 0.05s; }
      .po-tilt { position: relative; display: inline-flex; transform-style: preserve-3d; transition: transform 0.25s ease-out; will-change: transform; }
      .po-card.top.enter .po-tilt { animation: po-card-in 0.6s cubic-bezier(0.2, 0.9, 0.3, 1.15) both; }
      @keyframes po-card-in { from { transform: rotateY(-22deg) rotateX(6deg) scale(0.92); } to { transform: none; } }
      .po-tilt img { display: block; max-width: min(64vw, 270px); max-height: min(52vh, 400px); object-fit: contain; pointer-events: none;
        filter: drop-shadow(0 22px 26px rgba(20,20,45,0.2)) drop-shadow(0 3px 6px rgba(20,20,45,0.1)); }
      /* แสงสะท้อนตามมุมเอียง + ประกายรุ้ง (ตัดตามรูปทรงรูปด้วย mask) */
      .po-glare, .po-holo { position: absolute; inset: 0; pointer-events: none; -webkit-mask-size: 100% 100%; mask-size: 100% 100%;
        -webkit-mask-repeat: no-repeat; mask-repeat: no-repeat; }
      .po-glare { opacity: 0; transition: opacity 0.3s; mix-blend-mode: soft-light;
        background: radial-gradient(circle at var(--gx, 50%) var(--gy, 30%), rgba(255,255,255,0.95), rgba(255,255,255,0) 55%); }
      .po-card.top:hover .po-glare, .po-card.drag .po-glare, .po-card.top.enter .po-glare { opacity: 1; }
      .po-holo { display: none; mix-blend-mode: color-dodge; opacity: 0.55;
        background: linear-gradient(115deg, transparent 18%, rgba(255,140,200,0.55) 32%, rgba(150,200,255,0.6) 44%, rgba(160,255,200,0.55) 56%, rgba(255,240,150,0.5) 68%, transparent 82%);
        background-size: 250% 250%; background-position: var(--hx, 50%) 50%; animation: po-holo-sweep 3.2s ease-in-out infinite; }
      .po-card.is-ssr .po-holo { display: block; }
      @keyframes po-holo-sweep { 0%,100% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } }
      .po-glint { position: absolute; z-index: 8; width: 22px; height: 22px; pointer-events: none; background: #fff;
        clip-path: polygon(50% 0%, 58% 42%, 100% 50%, 58% 58%, 50% 100%, 42% 58%, 0% 50%, 42% 42%);
        filter: drop-shadow(0 0 4px rgba(180,190,220,0.9)); animation: po-glint 0.9s ease-out forwards; }
      .po-glint.holo { background: #fff6fb; filter: drop-shadow(0 0 6px rgba(255,150,210,0.9)); }
      @keyframes po-glint { 0% { transform: scale(0) rotate(0); opacity: 0; } 35% { transform: scale(1) rotate(45deg); opacity: 1; } 100% { transform: scale(0.2) rotate(90deg); opacity: 0; } }

      .po-caption { position: relative; z-index: 3; margin-top: 26px; min-height: 44px; display: flex; flex-direction: column; align-items: center; gap: 6px;
        padding: 0 20px; text-align: center; transition: opacity 0.25s, transform 0.25s; }
      .po-caption.swap { opacity: 0; transform: translateY(6px); }
      .po-caption .nm { font-size: 15px; font-weight: 700; color: #1d1d1f; max-width: 86vw; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .po-caption .sub { font-size: 12px; color: #8a8a8e; }
      .ssr-badge, .po-ssr { display: inline-block; font-size: 10.5px; font-weight: 800; letter-spacing: 1px; color: #1d1d1f; border-radius: 999px; padding: 2px 10px;
        background: linear-gradient(120deg, #ffe3f2, #e8e2ff, #dff4ff, #e2fbe9, #fff4d4); box-shadow: 0 0 0 1px rgba(29,29,31,0.08) inset; }
      .po-caption .po-ssr { animation: po-badge 0.5s cubic-bezier(0.3, 1.7, 0.5, 1) both 0.15s; }
      @keyframes po-badge { from { transform: scale(0); } to { transform: scale(1); } }
      .po-hint { position: relative; z-index: 3; margin-top: 10px; padding: 0 16px; font-size: 13px; color: #8a8a8e; text-align: center; min-height: 18px;
        animation: po-pulse 1.8s ease-in-out infinite; }
      @keyframes po-pulse { 0%,100% { opacity: 0.6; } 50% { opacity: 1; } }

      /* ===== สรุปของที่ได้ ===== */
      .po-summary { position: absolute; inset: 0; z-index: 4; display: flex; flex-direction: column; align-items: center; justify-content: center;
        padding: calc(64px + env(safe-area-inset-top)) 16px calc(28px + env(safe-area-inset-bottom)); animation: po-fade 0.4s ease both; }
      @keyframes po-fade { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: none; } }
      .po-summary h3 { margin: 0 0 4px; font-size: 19px; font-weight: 700; color: #1d1d1f; }
      .po-summary .sub { margin: 0 0 18px; font-size: 12px; color: #8a8a8e; }
      .po-grid { display: flex; flex-wrap: wrap; justify-content: center; align-items: flex-end; gap: 16px 14px; width: 100%; max-width: 440px; max-height: 58vh; overflow-y: auto; padding: 8px 4px; }
      .po-grid div { display: flex; flex-direction: column; align-items: center; gap: 6px; animation: po-pop 0.45s cubic-bezier(0.3, 1.5, 0.5, 1) both; }
      .po-grid img { height: 112px; width: auto; max-width: 170px; object-fit: contain; filter: drop-shadow(0 10px 14px rgba(20,20,45,0.16)); }
      @keyframes po-pop { from { transform: scale(0.5) translateY(20px); opacity: 0; } to { transform: none; opacity: 1; } }
      .po-done { margin-top: 24px; border: none; border-radius: 999px; padding: 13px 36px; background: #1d1d1f; color: #fff; font-family: inherit;
        font-size: 15px; font-weight: 700; cursor: pointer; box-shadow: 0 10px 24px -8px rgba(20,20,45,0.45); }
      .po-done:active { transform: scale(0.97); }

      .po-confetti { position: fixed; top: 46%; left: 50%; width: 7px; height: 11px; border-radius: 2px; z-index: 20600; pointer-events: none;
        animation: po-burst 1.5s cubic-bezier(0.15, 0.7, 0.3, 1) forwards; }
      @keyframes po-burst { 0% { transform: translate(-50%,-50%) rotate(0); opacity: 1; }
        75% { opacity: 1; }
        100% { transform: translate(calc(-50% + var(--tx)), calc(-50% + var(--ty))) rotate(var(--rot)) scale(0.5); opacity: 0; } }

      @media (prefers-reduced-motion: reduce) {
        .po-overlay *, .po-overlay { animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; }
      }
    `;
    document.head.appendChild(st);
  }

  // ฉลองแบบมินิมอล: เศษกระดาษสีเงิน/พาสเทล
  function confetti(n) {
    if (reduceMotion) return;
    const colors = ['#ffffff', '#e4e4ea', '#ffd6ec', '#d9d2ff', '#cdeeff', '#d4f7e0', '#fff1c4'];
    for (let i = 0; i < n; i++) {
      const p = document.createElement('div');
      p.className = 'po-confetti';
      const a = (Math.PI * 2 * i) / n + Math.random() * 0.5, d = 130 + Math.random() * 210;
      p.style.setProperty('--tx', Math.cos(a) * d + 'px');
      p.style.setProperty('--ty', Math.sin(a) * d - 50 + 'px');
      p.style.setProperty('--rot', (Math.random() * 720 - 360) + 'deg');
      p.style.background = colors[i % colors.length];
      p.style.boxShadow = '0 0 0 0.5px rgba(29,29,31,0.08)';
      document.body.appendChild(p);
      setTimeout(() => p.remove(), 1600);
    }
  }

  // ขอบล่างของแถบบนเป็นรอยตัดหยักเล็กๆ
  function jaggedClip() {
    const pts = ['0% 0%', '100% 0%'];
    for (let x = 100; x >= 0; x -= 4) pts.push(`${x}% ${x % 8 === 0 ? 100 : 90}%`);
    return `polygon(${pts.join(',')})`;
  }

  window.blm48OpenPacks = function (packs) {
    packs = (packs || []).filter(p => p.cards && p.cards.length);
    if (!packs.length) return Promise.resolve();
    injectStyles();

    return new Promise((resolve) => {
      const o = document.createElement('div');
      o.className = 'po-overlay';
      o.innerHTML = `<div class="po-holo-bg"></div><div class="po-floor"></div>
        <div class="po-topbar"><div><div class="po-count"></div><div class="po-dots"></div></div><button type="button" class="po-skip">Skip</button></div>
        <div class="po-stage"></div><div class="po-caption"></div><div class="po-hint"></div>`;
      document.body.appendChild(o);
      document.documentElement.style.overflow = 'hidden';
      requestAnimationFrame(() => o.classList.add('show'));

      const stage = o.querySelector('.po-stage');
      const hint = o.querySelector('.po-hint');
      const caption = o.querySelector('.po-caption');
      const countEl = o.querySelector('.po-count');
      const dotsEl = o.querySelector('.po-dots');
      const floor = o.querySelector('.po-floor');
      const allCards = packs.flatMap(p => p.cards);
      let packIdx = 0, finished = false, summarised = false;
      const timers = [];
      const later = (fn, ms) => { const t = setTimeout(fn, reduceMotion ? Math.min(ms, 60) : ms); timers.push(t); return t; };
      let cleanupPack = null;

      function finish() {
        if (finished) return;
        finished = true;
        timers.forEach(clearTimeout);
        o.classList.remove('show');
        document.documentElement.style.overflow = '';
        setTimeout(() => { o.remove(); resolve(); }, 350);
      }

      function showSummary() {
        if (summarised) return;
        summarised = true;
        timers.forEach(clearTimeout);
        if (cleanupPack) cleanupPack();
        o.classList.remove('holo', 'special');
        countEl.textContent = '';
        dotsEl.innerHTML = '';
        o.querySelector('.po-skip').style.display = 'none';
        stage.style.display = 'none';
        caption.style.display = 'none';
        floor.style.opacity = '0';
        hint.textContent = '';
        const hasSSR = allCards.some(c => c.isSSR);
        if (hasSSR) o.classList.add('holo');
        const sum = document.createElement('div');
        sum.className = 'po-summary';
        sum.innerHTML = `<h3>You got ${allCards.length} item${allCards.length > 1 ? 's' : ''}</h3>
          <p class="sub">${packs.length > 1 ? packs.length + ' packs opened' : esc(packs[0].name || 'BLM48 Random Pack')}</p>
          <div class="po-grid">${allCards.map((c, i) => `<div style="animation-delay:${i * 0.06}s"><img src="${esc(c.image)}" alt="" draggable="false">${c.isSSR ? '<span class="ssr-badge">SSR</span>' : ''}</div>`).join('')}</div>
          <button type="button" class="po-done">Add to Inventory</button>`;
        o.appendChild(sum);
        sum.querySelector('.po-done').addEventListener('click', finish);
        if (hasSSR) confetti(60);
      }

      function setDots(n, cur) {
        dotsEl.innerHTML = n > 1 ? Array.from({ length: n }, (_, i) => `<i class="${i <= cur ? 'on' : ''}${i === cur ? ' cur' : ''}"></i>`).join('') : '';
      }

      function glint(holo) {
        if (reduceMotion) return;
        const spots = [[12, 10], [86, 18], [80, 84], [16, 78], [50, 4]];
        const pick = spots.sort(() => Math.random() - 0.5).slice(0, holo ? 3 : 1);
        pick.forEach(([x, y], k) => {
          const g = document.createElement('div');
          g.className = 'po-glint' + (holo ? ' holo' : '');
          g.style.left = `calc(${x}% - 11px)`;
          g.style.top = `calc(${y}% - 11px)`;
          g.style.animationDelay = (0.18 + k * 0.16) + 's';
          stage.appendChild(g);
          setTimeout(() => g.remove(), 1500);
        });
      }

      function openPack(pack) {
        countEl.textContent = packs.length > 1 ? `Pack ${packIdx + 1}/${packs.length}` : '';
        setDots(0, -1);
        caption.innerHTML = '';
        // ซองที่มีของ SSR อย่างน้อย 1 ชิ้น = ซองพิเศษ (มุกโฮโล)
        const special = pack.cards.some(c => c.isSSR);
        o.classList.remove('holo');
        o.classList.toggle('special', special);
        stage.className = 'po-stage' + (special ? ' special' : '');
        floor.style.opacity = '1';
        floor.style.transform = '';

        stage.innerHTML = `<div class="po-halo"></div>
          <div class="po-cards">${pack.cards.map((c, i) => {
            const m = `-webkit-mask-image:url(&quot;${esc(cssUrl(c.image))}&quot;);mask-image:url(&quot;${esc(cssUrl(c.image))}&quot;);`;
            return `<div class="po-card${c.isSSR ? ' is-ssr' : ''}" data-i="${i}">
              <div class="po-tilt"><img src="${esc(c.image)}" alt="" draggable="false"><div class="po-holo" style="${m}"></div><div class="po-glare" style="${m}"></div></div>
            </div>`; }).join('')}</div>
          <div class="po-pack enter"><div class="po-pack-inner">
            <div class="po-part po-top" style="clip-path:${jaggedClip()}"><div class="po-mini">BLM48</div><div class="po-sheen"></div></div>
            <div class="po-part po-body">
              <div class="po-art">${pack.cover ? `<img src="${esc(pack.cover)}" alt="" draggable="false">` : ''}</div>
              <div class="po-name">${esc(pack.name || 'BLM48 Random Pack')}</div>
              <div class="po-brand">BLM48 · ${pack.cards.length} ITEM${pack.cards.length > 1 ? 'S' : ''}</div>
              <div class="po-sheen"></div>
            </div>
          </div></div>
          <div class="po-guide"></div><div class="po-cut"></div><div class="po-finger"></div>`;
        hint.textContent = '';

        const packEl = stage.querySelector('.po-pack');
        const topEl = stage.querySelector('.po-top');
        const cutEl = stage.querySelector('.po-cut');
        const guideEl = stage.querySelector('.po-guide');
        const cardsWrap = stage.querySelector('.po-cards');
        const cards = [...stage.querySelectorAll('.po-card')];
        let startX = null, progress = 0, torn = false, ready = false;

        // 1) ซองหมุนลอยเข้ามา → 2) ซูมเข้าหารอยปะ พร้อมให้ตัด
        later(() => { packEl.classList.remove('enter'); packEl.classList.add('idle'); }, 950);
        later(() => {
          packEl.classList.add('focus');
          floor.style.transform = 'translateY(14px) scaleX(1.1)';
          later(() => {
            ready = true;
            stage.classList.add('ready');
            hint.textContent = special ? 'Something special is inside ✦ Swipe along the line' : 'Swipe along the line to open';
          }, 450);
        }, 1250);

        function setProgress(p) {
          progress = Math.max(0, Math.min(1, p));
          cutEl.style.width = (progress * 110) + '%';
          topEl.style.transform = `rotate(${-progress * 7}deg) translateY(${-progress * 5}px)`;
        }

        function onDown(e) {
          if (torn) return;
          if (!ready) { // แตะก่อนซูมเสร็จ = ข้ามไปพร้อมตัดเลย
            ready = true; packEl.classList.remove('enter'); packEl.classList.add('idle', 'focus'); stage.classList.add('ready');
          }
          startX = e.clientX;
          packEl.classList.remove('idle');
          stage.classList.remove('ready');
          guideEl.style.opacity = '1';
          try { stage.setPointerCapture(e.pointerId); } catch (err) {}
        }
        function onMove(e) {
          if (torn || startX === null) return;
          setProgress(Math.abs(e.clientX - startX) / stage.offsetWidth);
          if (progress >= TEAR_DONE) tear(e);
        }
        function onUp() {
          if (torn || startX === null) return;
          startX = null;
          topEl.style.transition = 'transform 0.3s';
          setProgress(0);
          setTimeout(() => { topEl.style.transition = ''; }, 300);
          packEl.classList.add('idle');
          stage.classList.add('ready');
          guideEl.style.opacity = '';
        }
        stage.addEventListener('pointerdown', onDown);
        stage.addEventListener('pointermove', onMove);
        stage.addEventListener('pointerup', onUp);
        stage.addEventListener('pointercancel', onUp);

        function tear(e) {
          torn = true;
          stage.classList.remove('ready');
          const r = stage.getBoundingClientRect();
          const ring = document.createElement('div');
          ring.className = 'po-ring' + (special ? ' holo' : '');
          ring.style.left = Math.max(0, Math.min(r.width, (e ? e.clientX : r.right) - r.left)) + 'px';
          ring.style.top = (r.height * 0.156) + 'px';
          stage.appendChild(ring);
          setTimeout(() => ring.remove(), 750);
          if (special) {
            const w = document.createElement('div');
            w.className = 'po-whiteout';
            o.appendChild(w);
            setTimeout(() => w.remove(), 600);
            vibrate([50, 40, 50, 40, 110]);
          } else vibrate(25);

          // แถบบนกระเด็นหมุนหลุดขึ้นไป
          cutEl.style.width = '110%';
          topEl.style.transition = 'transform 0.75s cubic-bezier(0.25, 0.6, 0.4, 1), opacity 0.6s 0.15s';
          topEl.style.transform = 'translate(38%, -330%) rotate(-28deg) rotateX(55deg)';
          topEl.style.opacity = '0';
          guideEl.style.opacity = '0';
          later(() => { cutEl.style.opacity = '0'; }, 200);
          hint.textContent = '';

          // ซองตกลงจากเวที → กองของลอยขึ้นมาแทน
          later(() => { packEl.classList.remove('idle', 'focus'); packEl.classList.add('drop'); floor.style.transform = 'scaleX(0.7)'; }, 380);
          later(() => {
            floor.style.opacity = '0';
            cardsWrap.classList.add('rise');
            if (cards[0]) cards[0].classList.add('top');
            if (cards[1]) cards[1].classList.add('next');
          }, 780);
          later(() => {
            stage.removeEventListener('pointerdown', onDown);
            stage.removeEventListener('pointermove', onMove);
            stage.removeEventListener('pointerup', onUp);
            stage.removeEventListener('pointercancel', onUp);
            packEl.remove();
            reveal(0);
            bindCardGestures();
          }, 1250);
        }

        let cur = 0;
        function reveal(i) {
          const data = pack.cards[i];
          const el = cards[i];
          el.classList.remove('next');
          el.classList.add('top', 'enter');
          setTimeout(() => el.classList.remove('enter'), 650);
          if (cards[i + 1]) cards[i + 1].classList.add('next');
          o.classList.toggle('holo', !!data.isSSR);
          o.classList.toggle('special', false);
          glint(!!data.isSSR);
          if (data.isSSR) { confetti(44); vibrate([40, 40, 80]); }
          setDots(cards.length, i);
          caption.classList.add('swap');
          setTimeout(() => {
            caption.innerHTML = `${data.isSSR ? '<span class="po-ssr">SSR</span>' : ''}<div class="nm">${esc(data.label)}</div>`;
            caption.classList.remove('swap');
          }, reduceMotion ? 0 : 160);
          hint.textContent = i < cards.length - 1 ? 'Swipe or tap for the next item'
            : (packIdx < packs.length - 1 ? 'Tap to open the next pack' : 'Tap to see all items');
        }

        // เลื่อนการ์ดบนสุดออก (dir: -1 ซ้าย / 1 ขวา)
        function next(dir) {
          const el = cards[cur];
          if (!el) return;
          el.classList.remove('top', 'drag', 'enter');
          el.classList.add('gone');
          el.style.transform = `translate(${dir * 125}%, -6%) rotate(${dir * 16}deg)`;
          const tilt = el.querySelector('.po-tilt');
          tilt.style.transform = `rotateY(${dir * -28}deg)`;
          vibrate(10);
          cur++;
          if (cur < cards.length) { later(() => reveal(cur), 140); return; }
          unbindCardGestures();
          caption.classList.add('swap');
          hint.textContent = '';
          later(() => {
            packIdx++;
            if (packIdx < packs.length) openPack(packs[packIdx]); else showSummary();
          }, 500);
        }

        // เอียงตามนิ้ว/เมาส์ + ลากปัดซ้ายขวา + แตะ = ถัดไป
        let gx = null, gy = 0, dx = 0, moved = false;
        function tiltTo(el, cx, cy) {
          const b = el.querySelector('.po-tilt').getBoundingClientRect();
          const px = Math.max(0, Math.min(1, (cx - b.left) / b.width));
          const py = Math.max(0, Math.min(1, (cy - b.top) / b.height));
          const t = el.querySelector('.po-tilt');
          t.style.transform = `rotateY(${(px - 0.5) * 22}deg) rotateX(${(0.5 - py) * 18}deg)`;
          t.style.setProperty('--gx', (px * 100) + '%');
          t.style.setProperty('--gy', (py * 100) + '%');
          t.style.setProperty('--hx', (px * 100) + '%');
        }
        function resetTilt(el) { if (!el) return; const t = el.querySelector('.po-tilt'); t.style.transform = ''; }
        function gDown(e) {
          const el = cards[cur];
          if (!el || !el.classList.contains('top')) return;
          gx = e.clientX; gy = e.clientY; dx = 0; moved = false;
          el.classList.add('drag');
          try { cardsWrap.setPointerCapture(e.pointerId); } catch (err) {}
        }
        function gMove(e) {
          const el = cards[cur];
          if (!el) return;
          if (gx === null) { if (e.pointerType === 'mouse') tiltTo(el, e.clientX, e.clientY); return; }
          dx = e.clientX - gx;
          if (Math.abs(dx) > 6 || Math.abs(e.clientY - gy) > 6) moved = true;
          el.style.transform = `translateX(${dx}px) rotate(${dx / 22}deg)`;
          tiltTo(el, e.clientX, e.clientY);
        }
        function gUp() {
          if (gx === null) return;
          const el = cards[cur];
          gx = null;
          if (!el) return;
          el.classList.remove('drag');
          if (!moved) { next(-1); return; }
          if (Math.abs(dx) > SWIPE_OUT) { next(dx < 0 ? -1 : 1); return; }
          el.style.transform = '';
          resetTilt(el);
        }
        function gLeave() { if (gx === null) resetTilt(cards[cur]); }
        function bindCardGestures() {
          cardsWrap.addEventListener('pointerdown', gDown);
          cardsWrap.addEventListener('pointermove', gMove);
          cardsWrap.addEventListener('pointerup', gUp);
          cardsWrap.addEventListener('pointercancel', gUp);
          cardsWrap.addEventListener('pointerleave', gLeave);
        }
        function unbindCardGestures() {
          cardsWrap.removeEventListener('pointerdown', gDown);
          cardsWrap.removeEventListener('pointermove', gMove);
          cardsWrap.removeEventListener('pointerup', gUp);
          cardsWrap.removeEventListener('pointercancel', gUp);
          cardsWrap.removeEventListener('pointerleave', gLeave);
        }
        cleanupPack = () => {
          unbindCardGestures();
          stage.removeEventListener('pointerdown', onDown);
          stage.removeEventListener('pointermove', onMove);
          stage.removeEventListener('pointerup', onUp);
          stage.removeEventListener('pointercancel', onUp);
        };
      }

      o.querySelector('.po-skip').addEventListener('click', showSummary);
      openPack(packs[0]);
    });
  };
})();
