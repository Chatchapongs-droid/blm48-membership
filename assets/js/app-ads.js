/* =========================================================
   📣 BLM48 In-app Ads (โฆษณาโปรโมทกิจกรรมในแอป)
   - Admin จัดการที่ admin_ads / admin_ad?id= (ตาราง app_ads)
   - แยก 2 ส่วน: แบนเนอร์เลื่อนหน้า Home (placement banner, 3:1)
     และส่วน Promotion ถัดจากโพสต์แรกของ Timeline (placement timeline, การ์ด 2:1)
   - มีรูปอัปโหลด (image_url) -> โชว์รูปนั้น / ไม่มี -> ระบบวาดแบนเนอร์ธีม BLM48 ให้จากหัวข้อ + รูปประกอบ
   - นับยอดดู (เห็นบนจอ >= 60%, นับ 1 ครั้งต่อโฆษณาต่อการเปิดแอป) และยอดกด
   ========================================================= */
(function () {
  const CACHE_KEY = 'blm48_app_ads_cache';
  const SEEN_KEY = 'blm48_app_ads_seen';

  // ปลายทางสำเร็จรูปให้ Admin เลือก (path ภายในแอป)
  const DESTINATIONS = [
    { value: 'shop', label: 'Shop', kicker: 'SHOP' },
    { value: 'majorvote', label: 'Major Vote', kicker: 'MAJOR VOTE' },
    { value: 'theaters', label: 'Theaters & Concerts', kicker: 'THEATER' },
    { value: 'campaign', label: 'Champ Campaign', kicker: 'CAMPAIGN' },
    { value: 'coaster_trade', label: 'Coaster Trade', kicker: 'TRADE' },
    { value: 'specialfansday', label: 'Special Fans Day', kicker: 'SPECIAL DAY' },
    { value: 'musicvideo', label: 'Music Video', kicker: 'MUSIC VIDEO' },
    { value: 'fanpost', label: 'Fan Post', kicker: 'FAN POST' },
    { value: 'missions', label: 'Daily Mission', kicker: 'MISSION' },
    { value: 'leaderboard', label: 'Ranking', kicker: 'RANKING' },
    { value: 'membership_tier', label: 'Membership Tier', kicker: 'MEMBERSHIP' }
  ];
  const THEMES = ['yellow', 'pink', 'blue', 'dark'];

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ลิงก์ปลอดภัย: path ภายในแอป หรือ https:// เท่านั้น
  function safeHref(url) {
    const u = String(url || '').trim();
    if (/^https:\/\//i.test(u)) return u;
    if (/^[a-z0-9_\-]+(\.html)?([?#][^\s"'<>]*)?$/i.test(u)) return u;
    return '#';
  }
  function destOf(url) {
    const path = String(url || '').split(/[?#]/)[0].replace(/\.html$/i, '');
    return DESTINATIONS.find(d => d.value === path) || null;
  }

  function injectCss() {
    if (document.getElementById('blm48-ads-css')) return;
    const st = document.createElement('style');
    st.id = 'blm48-ads-css';
    st.textContent = `
      .ad-art { position: relative; width: 100%; aspect-ratio: 3 / 1; overflow: hidden; container-type: inline-size;
        font-family: 'Quicksand','Kanit',sans-serif; --ad-bg1:#ffd43b; --ad-bg2:#fff3bf; --ad-ink:#222; --ad-sub:#5c4a00; --ad-cta-bg:#222; --ad-cta-ink:#fff; --ad-blob:rgba(255,255,255,.45); --ad-kick-bg:rgba(255,255,255,.75); --ad-kick-ink:#7a5c00;
        background: linear-gradient(115deg, var(--ad-bg1) 0%, var(--ad-bg2) 100%); color: var(--ad-ink); user-select: none; }
      .ad-art.t-pink { --ad-bg1:#ff8fab; --ad-bg2:#ffe3ec; --ad-ink:#3a1424; --ad-sub:#6e2a44; --ad-cta-bg:#fff; --ad-cta-ink:#d6336c; --ad-kick-ink:#b02a5b; }
      .ad-art.t-blue { --ad-bg1:#74b4ff; --ad-bg2:#e3f0ff; --ad-ink:#0f2a4d; --ad-sub:#284b78; --ad-cta-bg:#0f2a4d; --ad-cta-ink:#fff; --ad-kick-ink:#1d5fb8; }
      .ad-art.t-dark { --ad-bg1:#17171c; --ad-bg2:#3a3a45; --ad-ink:#fff; --ad-sub:#d0d0da; --ad-cta-bg:#ffd43b; --ad-cta-ink:#222; --ad-blob:rgba(255,212,59,.14); --ad-kick-bg:rgba(255,212,59,.18); --ad-kick-ink:#ffd43b; }
      .ad-art .ad-blob { position: absolute; border-radius: 50%; background: var(--ad-blob); }
      .ad-art .ad-blob.b1 { width: 46cqw; height: 46cqw; right: -10cqw; top: -22cqw; }
      .ad-art .ad-blob.b2 { width: 22cqw; height: 22cqw; right: 30cqw; bottom: -14cqw; }
      .ad-art .ad-spark { position: absolute; width: 2.6cqw; height: 2.6cqw; background: var(--ad-cta-bg); opacity: .5;
        clip-path: polygon(50% 0,61% 39%,100% 50%,61% 61%,50% 100%,39% 61%,0 50%,39% 39%); }
      .ad-art .ad-text { position: absolute; left: 5.5cqw; top: 0; bottom: 0; width: 56cqw; display: flex; flex-direction: column; justify-content: center; gap: 1.3cqw; }
      .ad-art.no-photo .ad-text { width: 78cqw; }
      .ad-art .ad-kicker { align-self: flex-start; font-size: 2.5cqw; font-weight: 700; letter-spacing: .08em; padding: .5cqw 1.8cqw; border-radius: 9cqw; background: var(--ad-kick-bg); color: var(--ad-kick-ink); }
      .ad-art .ad-title { font-size: 6cqw; font-weight: 700; line-height: 1.12; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
      .ad-art .ad-sub { font-size: 3.1cqw; font-weight: 500; color: var(--ad-sub); line-height: 1.35; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
      .ad-art .ad-cta { align-self: flex-start; margin-top: .6cqw; font-size: 2.9cqw; font-weight: 700; padding: 1.2cqw 3.2cqw; border-radius: 9cqw; background: var(--ad-cta-bg); color: var(--ad-cta-ink); display: inline-flex; align-items: center; gap: 1.2cqw; }
      .ad-art .ad-photo { position: absolute; right: 5cqw; top: 50%; width: 26cqw; height: 26cqw; transform: translateY(-50%) rotate(4deg); border-radius: 4cqw; overflow: hidden; border: 1cqw solid #fff; box-shadow: 0 2cqw 4cqw rgba(0,0,0,.16); background: #fff; }
      .ad-art .ad-photo img { width: 100%; height: 100%; object-fit: cover; display: block; }
      .ad-art.has-image { background: #f4f4f4; aspect-ratio: auto; min-height: 20px; }
      .ad-art.has-image img.ad-img { width: 100%; height: auto; display: block; }

      /* การ์ด Promotion 2:1 (ปุ่มอยู่ใต้รูปแล้ว ไม่ต้องมีปุ่มในรูป) */
      .ad-art.promo { aspect-ratio: 2 / 1; }
      .ad-art.promo .ad-text { left: 6cqw; width: 52cqw; gap: 1.8cqw; }
      .ad-art.promo.no-photo .ad-text { width: 80cqw; }
      .ad-art.promo .ad-kicker { font-size: 3.2cqw; padding: .7cqw 2.4cqw; }
      .ad-art.promo .ad-title { font-size: 8cqw; -webkit-line-clamp: 3; }
      .ad-art.promo .ad-sub { font-size: 4cqw; }
      .ad-art.promo .ad-cta { display: none; }
      .ad-art.promo .ad-photo { width: 34cqw; height: 34cqw; right: 6cqw; border-radius: 5cqw; }
      .ad-art.promo .ad-blob.b1 { width: 64cqw; height: 64cqw; top: -26cqw; }
      .ad-art.promo .ad-spark { width: 3.4cqw; height: 3.4cqw; }
      .ad-art.promo.has-image { aspect-ratio: 2 / 1; }
      .ad-art.promo.has-image img.ad-img { height: 100%; object-fit: cover; }

      /* ส่วน Promotion ถัดจากโพสต์แรกของ Timeline - เต็มขอบเหมือน .post-card */
      #timeline-promo { margin: 0 -12px; padding: 16px 0 18px; border-bottom: 8px solid #f2f2f4; background: #fff; }
      #timeline-promo .tp-title { font-size: 19px; font-weight: 700; color: #222; padding: 0 12px 12px; }
      #timeline-promo .tp-row { display: flex; gap: 8px; overflow-x: auto; scroll-snap-type: x mandatory; scroll-padding: 0 12px; padding: 0 12px; scrollbar-width: none; }
      #timeline-promo .tp-row::-webkit-scrollbar { display: none; }
      #timeline-promo .tp-card { flex: 0 0 calc(100% - 6px); scroll-snap-align: start; text-decoration: none; color: inherit; min-width: 0; }
      #timeline-promo .tp-row.single .tp-card { flex-basis: 100%; }
      #timeline-promo .tp-img { border-radius: 8px; overflow: hidden; background: #f4f4f4; }
      #timeline-promo .tp-foot { display: flex; align-items: center; gap: 12px; padding-top: 10px; }
      #timeline-promo .tp-info { flex: 1; min-width: 0; }
      #timeline-promo .tp-name { font-size: 16px; font-weight: 500; color: #222; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      #timeline-promo .tp-desc { font-size: 13.5px; color: #767676; line-height: 1.35; margin-top: 2px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
      #timeline-promo .tp-btn { flex-shrink: 0; background: #ffd43b; color: #222; font-size: 14px; font-weight: 700; border-radius: 20px; padding: 8px 18px; white-space: nowrap; }
    `;
    document.head.appendChild(st);
  }

  // 🎨 ศิลป์โฆษณา (รูปอัปโหลด หรือวาดให้อัตโนมัติ): Banner = 3:1, Promotion (placement timeline) = 2:1
  function renderArt(ad) {
    injectCss();
    const ratio = ad.placement === 'timeline' ? 'promo' : '';
    if (ad.imageUrl) {
      return `<div class="ad-art has-image ${ratio}"><img class="ad-img" src="${esc(ad.imageUrl)}" alt="${esc(ad.title)}" draggable="false" loading="lazy"></div>`;
    }
    const theme = THEMES.includes(ad.theme) ? ad.theme : 'yellow';
    const d = destOf(ad.linkUrl);
    const kicker = ad.kicker || (d ? d.kicker : '');
    const cta = ad.ctaLabel || 'ดูเลย';
    return `
      <div class="ad-art ${ratio} t-${theme} ${ad.photoUrl ? '' : 'no-photo'}">
        <span class="ad-blob b1"></span><span class="ad-blob b2"></span>
        <span class="ad-spark" style="right:${ad.photoUrl ? 36 : 12}cqw; top:14%"></span>
        <span class="ad-spark" style="right:${ad.photoUrl ? 3 : 22}cqw; bottom:12%; transform:scale(.7)"></span>
        <div class="ad-text">
          ${kicker ? `<span class="ad-kicker">${esc(kicker)}</span>` : ''}
          <div class="ad-title">${esc(ad.title)}</div>
          ${ad.subtitle ? `<div class="ad-sub">${esc(ad.subtitle)}</div>` : ''}
          <span class="ad-cta">${esc(cta)} <i class="fa-solid fa-arrow-right"></i></span>
        </div>
        ${ad.photoUrl ? `<div class="ad-photo"><img src="${esc(ad.photoUrl)}" alt="" draggable="false" loading="lazy"></div>` : ''}
      </div>`;
  }

  // ===== ข้อมูล =====
  function readCache() {
    try { const c = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null'); return Array.isArray(c) ? c : null; } catch (e) { return null; }
  }
  // กรองช่วงเวลาอีกรอบฝั่งเครื่อง เผื่อแคชค้างข้ามเวลาจบโฆษณา
  function liveNow(list) {
    const now = Date.now();
    return (list || []).filter(a => (!a.startsAt || Date.parse(a.startsAt) <= now) && (!a.endsAt || Date.parse(a.endsAt) > now));
  }
  async function fetchAds() {
    try {
      const res = await blm48Rpc('get_active_ads', {});
      if (res && res.status === 'success' && Array.isArray(res.ads)) {
        try { localStorage.setItem(CACHE_KEY, JSON.stringify(res.ads)); } catch (e) {}
        return res.ads;
      }
    } catch (e) { console.warn('ads fetch failed', e); }
    return null;
  }
  const forPlacement = (list, p) => liveNow(list).filter(a => a.placement === p);

  // ===== นับยอดดู / ยอดกด =====
  // ส่งแบบ keepalive ตรงไปที่ REST เพื่อให้ยอดกดไม่หายตอนเปลี่ยนหน้า
  function track(id, kind) {
    try {
      fetch(`${BLM48_SUPABASE_URL}/rest/v1/rpc/track_ad_event`, {
        method: 'POST', keepalive: true,
        headers: { 'Content-Type': 'application/json', apikey: BLM48_SUPABASE_ANON_KEY, Authorization: `Bearer ${BLM48_SUPABASE_ANON_KEY}` },
        body: JSON.stringify({ p_ad_id: Number(id), p_kind: kind })
      }).catch(() => {});
    } catch (e) {}
  }
  function seenSet() {
    try { return new Set(JSON.parse(sessionStorage.getItem(SEEN_KEY) || '[]')); } catch (e) { return new Set(); }
  }
  function markSeen(id) {
    const s = seenSet();
    if (s.has(String(id))) return false;
    s.add(String(id));
    try { sessionStorage.setItem(SEEN_KEY, JSON.stringify([...s])); } catch (e) {}
    return true;
  }
  let viewObserver = null;
  function observeViews(root) {
    if (!('IntersectionObserver' in window)) return;
    if (!viewObserver) {
      viewObserver = new IntersectionObserver(entries => {
        entries.forEach(en => {
          if (!en.isIntersecting || en.intersectionRatio < 0.6 || document.hidden) return;
          const id = en.target.dataset.adId;
          viewObserver.unobserve(en.target);
          if (id && markSeen(id)) track(id, 'view');
        });
      }, { threshold: [0.6] });
    }
    root.querySelectorAll('[data-ad-id]').forEach(el => { if (!seenSet().has(el.dataset.adId)) viewObserver.observe(el); });
  }
  function bindClicks(root) {
    root.querySelectorAll('[data-ad-id]').forEach(el => {
      if (el.dataset.adBound) return;
      el.dataset.adBound = '1';
      el.addEventListener('click', () => track(el.dataset.adId, 'click'));
    });
  }

  // ===== หน้า Home: แบนเนอร์เลื่อน =====
  function renderBanners(list) {
    const box = document.getElementById('autoBannerContainer');
    if (!box) return;
    const ads = forPlacement(list, 'banner');
    const sig = JSON.stringify(ads);
    if (box.dataset.adSig === sig) return;
    box.dataset.adSig = sig;
    box.querySelectorAll('.ad-banner-item').forEach(el => el.remove());
    box.insertAdjacentHTML('beforeend', ads.map(a => `
      <a href="${esc(safeHref(a.linkUrl))}" class="auto-banner-item ad-banner-item" data-ad-id="${a.id}" style="flex: 0 0 100%; min-width: 100%; scroll-snap-align: start; text-decoration: none; display: block;">
        ${renderArt(a)}
      </a>`).join(''));
    bindClicks(box);
    observeViews(box);
    if (typeof window.initBannerFeatures === 'function') window.initBannerFeatures();
  }

  // ===== หน้า Home: การ์ดโปรโมทถัดจากโพสต์แรกของ Timeline =====
  let promoEl = null;
  let feedObs = null;
  function placePromo() {
    const feed = document.getElementById('posts-container');
    if (!feed || !promoEl) return;
    const first = feed.querySelector(':scope > .post-card');
    if (!first) { if (promoEl.parentNode) promoEl.remove(); return; }
    if (first.nextElementSibling !== promoEl) first.after(promoEl);
  }
  function renderTimelinePromo(list) {
    const feed = document.getElementById('posts-container');
    if (!feed) return;
    const ads = forPlacement(list, 'timeline');
    if (!ads.length) { if (promoEl) promoEl.remove(); promoEl = null; return; }
    if (!promoEl) { promoEl = document.createElement('section'); promoEl.id = 'timeline-promo'; }
    promoEl.innerHTML = promoSectionHtml(ads);
    placePromo();
    bindClicks(promoEl);
    observeViews(promoEl);
    // ฟีดเพิ่มโพสต์ใหม่ไว้บนสุด / ล้างใหม่ตอนเปลี่ยนฟิลเตอร์ -> คอยย้ายการ์ดให้อยู่ถัดจากโพสต์แรกเสมอ
    if (!feedObs) {
      feedObs = new MutationObserver(() => placePromo());
      feedObs.observe(feed, { childList: true });
    }
  }

  // ส่วน Promotion (ใช้ทั้งหน้า Home และพรีวิวในหน้า Admin)
  function promoSectionHtml(ads, opts) {
    const tag = opts && opts.preview ? 'div' : 'a';
    return `
      <div class="tp-title">Promotion</div>
      <div class="tp-row ${ads.length === 1 ? 'single' : ''}">
        ${ads.map(a => `
          <${tag} class="tp-card" ${tag === 'a' ? `href="${esc(safeHref(a.linkUrl))}" data-ad-id="${a.id}"` : ''}>
            <div class="tp-img">${renderArt(Object.assign({}, a, { placement: 'timeline' }))}</div>
            <div class="tp-foot">
              <div class="tp-info"><div class="tp-name">${esc(a.title)}</div>${a.subtitle ? `<div class="tp-desc">${esc(a.subtitle)}</div>` : ''}</div>
              <span class="tp-btn">${esc(a.ctaLabel || 'ดูเลย')}</span>
            </div>
          </${tag}>`).join('')}
      </div>`;
  }

  async function initHome() {
    injectCss();
    const cached = readCache();
    if (cached) { renderBanners(cached); renderTimelinePromo(cached); }
    const fresh = await fetchAds();
    if (fresh) { renderBanners(fresh); renderTimelinePromo(fresh); }
    else if (!cached) { renderBanners([]); }
  }

  window.BLM48Ads = { DESTINATIONS, THEMES, renderArt, promoSectionHtml, safeHref, destOf, initHome, injectCss };
})();
