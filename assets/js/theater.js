// 🎭 Theaters & Concerts shared helpers (theaters / theater_* pages)
// Shows run online (YouTube Live / Roblox) or on-site; tickets are paid with Tokens only.

const BLM48_THEATER_PLATFORMS = {
  youtube: { label: 'YouTube Live', icon: 'fa-brands fa-youtube', color: '#ff0033', watch: 'Watch on YouTube' },
  roblox:  { label: 'Roblox Concert', icon: 'fa-solid fa-gamepad', color: '#3a3a3a', watch: 'Join on Roblox' },
  onsite:  { label: 'On-site', icon: 'fa-solid fa-location-dot', color: '#8a8a8a', watch: 'Open venue info' },
  other:   { label: 'Online', icon: 'fa-solid fa-globe', color: '#3aa0d8', watch: 'Open watch link' }
};

function theaterPlatform(p) {
  return BLM48_THEATER_PLATFORMS[p] || BLM48_THEATER_PLATFORMS.other;
}

// '2026-10-24' -> '24 Oct 2026'
function theaterDate(d) {
  if (!d) return '';
  const [y, m, day] = String(d).slice(0, 10).split('-').map(Number);
  const mon = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][m - 1];
  return `${day} ${mon} ${y}`;
}

// ISO timestamp -> '15 Oct 2026 12:00' (Bangkok)
function theaterDateTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Bangkok', day: 'numeric', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false
  }).formatToParts(d).reduce((a, p) => (a[p.type] = p.value, a), {});
  return `${parts.day} ${parts.month} ${parts.year} ${parts.hour}:${parts.minute}`;
}

function theaterTimeRange(e) {
  if (!e.startTime) return '';
  return e.endTime ? `${e.startTime} - ${e.endTime}` : e.startTime;
}

function theaterVenue(e) {
  const p = theaterPlatform(e.platform);
  return e.venue || p.label;
}

function theaterRoundName(kind) {
  return kind === 'express' ? 'Express round' : 'Normal round';
}

// what the list/detail shows for an event: the open round, else the next one, else closed/sold out
function theaterSaleState(e) {
  const rounds = e.rounds || [];
  const open = rounds.find(r => r.state === 'open');
  const soldOut = (e.seatsLeft !== undefined ? Number(e.seatsLeft) : (e.zones || []).reduce((s, z) => s + Number(z.left), 0)) <= 0;
  if (e.status === 'cancelled') return { kind: 'cancelled', text: 'Cancelled', cls: 'is-closed' };
  // drafts only reach admins (get_theater_events / get_theater_event), and can't be booked
  if (e.status === 'draft') return { kind: 'draft', text: 'ฉบับร่าง · เห็นเฉพาะ Admin', cls: 'is-draft' };
  if (open && soldOut) return { kind: 'soldout', text: 'Sold Out', cls: 'is-soldout', round: open };
  if (open) return { kind: 'open', text: theaterRoundName(open.kind), cls: 'is-open', round: open };
  const next = rounds.find(r => r.state === 'upcoming');
  if (next) return { kind: 'upcoming', text: `${theaterRoundName(next.kind)} open for booking on ${theaterDateTime(next.openAt)}`, cls: 'is-upcoming', round: next };
  return { kind: 'closed', text: 'Booking Closed', cls: 'is-closed' };
}

// event summary block (poster + date/title/time/venue) used on list, checkout and bookings
function theaterEventHead(e, opts) {
  const o = opts || {};
  const p = theaterPlatform(e.platform);
  return `
    <div class="th-event-head">
      ${e.coverUrl
        ? `<img class="th-poster" src="${escapeHtml(e.coverUrl)}" alt="" loading="lazy" onerror="this.onerror=null;this.replaceWith(Object.assign(document.createElement('div'),{className:'th-poster is-empty'}))">`
        : '<div class="th-poster is-empty"></div>'}
      <div class="th-event-info">
        <div class="th-event-date">${theaterDate(e.eventDate)}</div>
        <div class="th-event-title">${escapeHtml(e.title)}</div>
        ${e.startTime ? `<div class="th-meta"><i class="fa-regular fa-clock"></i>${theaterTimeRange(e)}</div>` : ''}
        <div class="th-meta"><i class="${p.icon}" style="color:${p.color}"></i>${escapeHtml(theaterVenue(e))}</div>
        ${o.extra || ''}
      </div>
    </div>`;
}

// reward bundle (same shape as shop_order_items.rewards) -> chips
function theaterRewardsHtml(rewards) {
  const list = rewards || [];
  if (!list.length) return '';
  // group identical items so "Poster x2" reads nicely
  const groups = [];
  list.forEach(r => {
    const key = r.kind + '|' + (r.label || '');
    const g = groups.find(x => x.key === key);
    if (g && r.kind === 'item') g.count++;
    else groups.push({ key, r, count: 1 });
  });
  return groups.map(({ r, count }) => {
    if (r.kind === 'cookie') return `<span class="th-reward"><i class="fas fa-cookie-bite" style="color:#d2691e"></i>${Number(r.amount).toLocaleString()} Cookies</span>`;
    if (r.kind === 'ge_token') return `<span class="th-reward"><i class="fas fa-gem"></i>${Number(r.amount).toLocaleString()} GE Token</span>`;
    return `<span class="th-reward">${r.imageUrl ? `<img src="${escapeHtml(r.imageUrl)}" alt="">` : '<i class="fas fa-gift" style="color:#f0a73a"></i>'}${escapeHtml(r.label || 'Item')}${count > 1 ? ' x' + count : ''}</span>`;
  }).join('');
}

// ---- Ticket holders: seat 2+ can be put under a friend's Wallet Code ----
// The ticket then shows the friend's name, and a Lucky Draw win on that seat goes to the friend.
// "giveItems" also sends that seat's Official Souvenir, Ticket Stub and after-show souvenir to the friend.
const BLM48_THEATER_AVATAR = '/assets/images/default-avatar.png';
const theaterHolderPicked = {};   // idx -> { walletCode, name, profile_img }

function theaterWalletLabel(code) {
  return code ? 'BLM-' + code : '';
}

function theaterHolderRowHtml(idx) {
  const p = theaterHolderPicked[idx];
  const body = p
    ? `<div class="th-holder-me">
         <img src="${escapeHtml(p.profile_img || BLM48_THEATER_AVATAR)}" alt="" onerror="this.onerror=null;this.src='${BLM48_THEATER_AVATAR}'">
         <div class="grow"><div>${escapeHtml(p.name)}</div><div class="sub">${theaterWalletLabel(p.walletCode)}</div></div>
         <button type="button" class="th-holder-clear" onclick="theaterHolderClear(${idx})" aria-label="ลบชื่อเพื่อน"><i class="fa-solid fa-xmark"></i></button>
       </div>
       <label class="th-holder-give"><input type="checkbox" id="holder-give-${idx}" ${p.giveItems ? 'checked' : ''}
         onchange="theaterHolderPicked[${idx}].giveItems = this.checked">
         <span>ให้ของที่ระลึกของที่นั่งนี้กับเพื่อนด้วย<br><span class="th-zone-note">Official Souvenir, Ticket Stub และของที่ระลึกหลังจบการแสดงของที่นั่งนี้จะเข้า Inventory ของเพื่อน</span></span></label>`
    : `<div class="th-holder-input">
         <input type="text" id="holder-input-${idx}" inputmode="text" autocomplete="off" placeholder="Wallet Code เพื่อน (BLM-...)"
           onkeydown="if(event.key==='Enter'){event.preventDefault();theaterHolderCheck(${idx});}">
         <button type="button" class="btn-yellow" id="holder-check-${idx}" onclick="theaterHolderCheck(${idx})">ตรวจสอบ</button>
       </div>
       <div class="th-zone-note" style="margin-top:6px">เว้นว่างไว้ ถ้าที่นั่งนี้เป็นของคุณเอง</div>`;
  return `<div class="th-holder-seat">ที่นั่งที่ ${idx}</div>${body}<div class="inline-error" id="holder-error-${idx}"></div>`;
}

function theaterHolderRender(idx) {
  const el = document.getElementById('holder-' + idx);
  if (el) el.innerHTML = theaterHolderRowHtml(idx);
}

function theaterHolderClear(idx) {
  delete theaterHolderPicked[idx];
  theaterHolderRender(idx);
  if (typeof onTheaterHolderChange === 'function') onTheaterHolderChange();
}

async function theaterHolderCheck(idx) {
  const input = document.getElementById('holder-input-' + idx);
  const err = document.getElementById('holder-error-' + idx);
  const btn = document.getElementById('holder-check-' + idx);
  const code = (input.value || '').replace(/[^0-9]/g, '');
  err.style.display = 'none';
  if (!code) { err.textContent = 'กรุณาใส่ Wallet Code ของเพื่อน'; err.style.display = 'block'; return; }
  const dup = Object.keys(theaterHolderPicked).find(k => Number(k) !== idx && theaterHolderPicked[k].walletCode === code);
  if (dup) { err.textContent = 'เพื่อนคนนี้อยู่ที่นั่งที่ ' + dup + ' แล้ว'; err.style.display = 'block'; return; }
  btn.disabled = true;
  btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>';
  const user = getUserSession();
  const res = await blm48TheaterLookupFriend(user && user.username, code);
  btn.disabled = false;
  btn.textContent = 'ตรวจสอบ';
  if (!res || res.status !== 'success') {
    err.textContent = (res && res.message) || 'ตรวจสอบไม่สำเร็จ ลองใหม่อีกครั้งค่ะ';
    err.style.display = 'block';
    return;
  }
  theaterHolderPicked[idx] = Object.assign({ giveItems: false }, res.data);
  theaterHolderRender(idx);
  if (typeof onTheaterHolderChange === 'function') onTheaterHolderChange();
}
