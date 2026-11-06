// 🫧 Bubble Float — ฟองกลมลอยอยู่หลังไอคอนของแท็บที่เปิดอยู่ในเมนูล่าง (.bottom-tab-bar)
// โหลดอัตโนมัติจาก common.js — ใช้กับทุกหน้าที่มีเมนูล่าง (index/fanpost/majorvote/notification/profile/musicvideo)
// - ฟองลอยขึ้นลงเบาๆ ตลอดเวลา ไอคอนที่ active ลอยตามไปด้วย
// - กดแท็บอื่น: ฟองไหลไปหาแท็บนั้นแบบสปริงก่อน แล้วค่อยเปลี่ยนหน้า
(function () {
  if (window.__blm48NavBubble) return;
  window.__blm48NavBubble = true;

  const css = `
  .blm48-nav-bubble {
    position: absolute; left: 0; top: 0;
    width: 74px; height: 74px; margin: -37px 0 0 -37px;
    border-radius: 50%;
    z-index: 1; pointer-events: none;
    /* ฟองสบู่ใส: ตรงกลางโปร่ง ขอบเป็นสีรุ้งจางๆ */
    background: radial-gradient(circle at 50% 50%, rgba(255,255,255,0) 55%, rgba(255,255,255,0.28) 74%, rgba(255,255,255,0.55) 100%);
    border: 1px solid rgba(255,255,255,0.75);
    box-shadow:
      inset 5px 2px 10px rgba(255,140,190,0.38),
      inset -5px -1px 10px rgba(120,200,255,0.38),
      inset 0 -6px 10px rgba(170,255,215,0.32),
      inset 0 5px 8px rgba(255,235,150,0.28),
      0 6px 16px rgba(255,107,139,0.12);
    -webkit-backdrop-filter: blur(1.5px) saturate(1.3);
    backdrop-filter: blur(1.5px) saturate(1.3);
    transition: transform 0.45s cubic-bezier(0.34, 1.56, 0.64, 1), opacity 0.2s ease;
    will-change: transform;
  }
  .blm48-nav-bubble-inner {
    position: absolute; inset: 0; border-radius: 50%;
    animation: blm48BubbleFloat 3.2s ease-in-out infinite;
  }
  .blm48-nav-bubble-inner::before { /* แสงสะท้อนบนฟอง */
    content: ""; position: absolute; top: 9px; left: 14px;
    width: 20px; height: 9px; border-radius: 50%;
    background: linear-gradient(180deg, rgba(255,255,255,0.95), rgba(255,255,255,0.2));
    transform: rotate(-30deg);
  }
  .blm48-nav-bubble-inner::after, .blm48-nav-bubble-mini { /* ฟองเล็กใสลอยขึ้น */
    content: ""; position: absolute; border-radius: 50%;
    background: radial-gradient(circle at 35% 30%, rgba(255,255,255,0.9) 0 18%, rgba(255,255,255,0.1) 45%, rgba(255,255,255,0.35) 100%);
    border: 1px solid rgba(255,255,255,0.8);
    box-shadow: inset 1px 0 2px rgba(255,140,190,0.4), inset -1px 0 2px rgba(120,200,255,0.4);
  }
  .blm48-nav-bubble-inner::after {
    width: 9px; height: 9px; right: 2px; top: 6px;
    animation: blm48BubbleRise 3.2s ease-in-out infinite;
  }
  .blm48-nav-bubble-mini {
    width: 6px; height: 6px; left: 4px; top: 18px;
    animation: blm48BubbleRise 3.2s ease-in-out 1.6s infinite;
  }
  @keyframes blm48BubbleFloat {
    0%, 100% { transform: translateY(0); }
    50% { transform: translateY(-5px); }
  }
  @keyframes blm48BubbleRise {
    0% { transform: translateY(6px) scale(0.6); opacity: 0; }
    25% { opacity: 1; }
    100% { transform: translateY(-22px) scale(1); opacity: 0; }
  }
  .bottom-tab-bar.has-bubble .tab-item.active > i,
  .bottom-tab-bar.has-bubble .tab-item.active > img,
  .bottom-tab-bar.has-bubble .tab-item.active > .icon-wrapper {
    animation: blm48BubbleFloat 3.2s ease-in-out infinite;
  }
  .blm48-nav-bubble.is-moving .blm48-nav-bubble-inner { animation: none; }
  @media (prefers-reduced-motion: reduce) {
    .blm48-nav-bubble { transition: none; }
    .blm48-nav-bubble-inner, .blm48-nav-bubble-inner::after, .blm48-nav-bubble-mini,
    .bottom-tab-bar.has-bubble .tab-item.active > * { animation: none !important; }
  }`;

  function init() {
    const bar = document.querySelector('.bottom-tab-bar');
    if (!bar || bar.querySelector('.blm48-nav-bubble')) return;

    const style = document.createElement('style');
    style.id = 'blm48-nav-bubble-css';
    style.textContent = css;
    document.head.appendChild(style);

    const bubble = document.createElement('div');
    bubble.className = 'blm48-nav-bubble';
    bubble.innerHTML = '<div class="blm48-nav-bubble-inner"><span class="blm48-nav-bubble-mini"></span></div>';
    bar.appendChild(bubble);
    bar.classList.add('has-bubble');

    let baseY = null; // ระดับความสูงของไอคอน active (คงที่ทุกแท็บ)

    function place(tab, animate) {
      if (!tab) { bubble.style.opacity = '0'; return; }
      const b = bar.getBoundingClientRect();
      const t = tab.getBoundingClientRect();
      const x = t.left + t.width / 2 - b.left;
      // วัดความสูงตอนไม่ได้กำลังเลื่อนเท่านั้น (ตอนกดแท็บใหม่ ไอคอนยังเด้งขึ้นไม่สุด จะได้ค่าผิด)
      if (!animate || baseY === null) baseY = t.top + t.height / 2 - b.top;
      if (!animate) bubble.style.transition = 'none';
      bubble.style.transform = `translate(${x}px, ${baseY}px)`;
      bubble.style.opacity = '1';
      if (!animate) { void bubble.offsetWidth; bubble.style.transition = ''; }
    }

    const activeTab = () => bar.querySelector('.tab-item.active');
    place(activeTab(), false);
    // รูปไอคอน/รูปโปรไฟล์โหลดทีหลังอาจทำให้ layout ขยับ — วางตำแหน่งใหม่อีกรอบ
    window.addEventListener('load', () => place(activeTab(), false));
    window.addEventListener('resize', () => place(activeTab(), false));
    window.addEventListener('pageshow', () => place(activeTab(), false)); // กลับมาจาก bfcache

    bar.addEventListener('click', (e) => {
      const tab = e.target.closest('.tab-item');
      if (!tab || tab.classList.contains('active')) return;
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      const href = tab.getAttribute('href');
      if (!href || href.startsWith('#') || href.startsWith('javascript:')) return;
      if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

      e.preventDefault();
      const prev = activeTab();
      if (prev) prev.classList.remove('active');
      tab.classList.add('active');
      bubble.classList.add('is-moving');
      place(tab, true);
      setTimeout(() => { window.location.href = tab.href; }, 280);
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
