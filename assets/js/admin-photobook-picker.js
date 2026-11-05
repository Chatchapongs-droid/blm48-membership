// 📖 เลือกโฟโต้บุ๊ค (จากหน้า Admin Photobook) มาใช้ในหน้า Shop / Theater
// เล่มผูกกับไอเทมด้วย "รูปปกหน้า": ไอเทมที่ image_url = cover_url ของเล่ม → ตอนเข้า Inventory
// trigger inventory_attach_photobook ใส่ file_url = 'photobook:<id>' ให้ เปิดอ่านเป็นหนังสือ 3D ได้เอง
// ใช้: blm48TogglePhotobookPicker(anchorEl, username, book => { ... })  → รายการเล่มกางใต้ปุ่ม (ไม่ใช่ป๊อปอัป) กดอีกครั้งเพื่อปิด
(function () {
  let cache = null;

  function injectCss() {
    if (document.getElementById('pb-picker-css')) return;
    const st = document.createElement('style');
    st.id = 'pb-picker-css';
    st.textContent = `
      .pb-picker { grid-column: 1 / -1; border: 1px solid #f0f0f0; border-radius: 12px; padding: 6px; margin: 6px 0; background: #fff; max-height: 300px; overflow: auto; }
      .pb-picker .pp-row { display: flex; align-items: center; gap: 10px; width: 100%; border: none; background: none; padding: 7px 8px; border-radius: 10px;
        font-family: inherit; text-align: left; cursor: pointer; color: #333; }
      .pb-picker .pp-row:hover { background: #fafafa; }
      .pb-picker .pp-cover { width: 34px; height: 48px; flex: 0 0 34px; border-radius: 2px 5px 5px 2px; background: #f3f3f3 center/cover no-repeat; }
      .pb-picker .pp-t { font-size: 13.5px; font-weight: 700; }
      .pb-picker .pp-s { font-size: 11.5px; color: #767676; }
      .pb-picker .pp-empty { font-size: 12.5px; color: #767676; padding: 12px; text-align: center; line-height: 1.6; }
      .pb-picker .pp-empty a { color: #333; font-weight: 700; }
      .btn-pb-pick { display: inline-flex; align-items: center; gap: 5px; }
    `;
    document.head.appendChild(st);
  }

  async function loadBooks(username) {
    if (cache) return cache;
    const { data, error } = await blm48Supabase.rpc('admin_list_photobooks', { p_admin_username: username });
    if (error) throw error;
    if (!data || data.status !== 'success') throw new Error((data && data.message) || 'load failed');
    cache = (data.books || []).filter(b => b.status !== 'hidden');
    return cache;
  }

  // insertAfter = element ที่จะวางรายการต่อท้าย (ค่าเริ่มต้น = ปุ่มเอง)
  window.blm48TogglePhotobookPicker = async function (anchor, username, onPick, insertAfter) {
    injectCss();
    const host = insertAfter || anchor;
    const open = host.nextElementSibling && host.nextElementSibling.classList.contains('pb-picker') ? host.nextElementSibling : null;
    if (open) { open.remove(); return; }
    const box = document.createElement('div');
    box.className = 'pb-picker';
    box.innerHTML = '<div class="pp-empty"><i class="fa-solid fa-spinner fa-spin"></i> Loading...</div>';
    host.insertAdjacentElement('afterend', box);
    try {
      const books = await loadBooks(username);
      if (!books.length) {
        box.innerHTML = '<div class="pp-empty">ยังไม่มีโฟโต้บุ๊ค · <a href="admin_photobook?id=new">สร้างเล่มใหม่</a></div>';
        return;
      }
      box.innerHTML = books.map((b, i) => `
        <button type="button" class="pp-row" data-i="${i}">
          <span class="pp-cover" style="background-image:url('${escapeAttr(b.coverUrl || '')}')"></span>
          <span><span class="pp-t">${escapeHtml(b.title || 'Untitled')}</span><br><span class="pp-s">${Number(b.pageCount || 0)} หน้า</span></span>
        </button>`).join('');
      box.addEventListener('click', e => {
        const row = e.target.closest('.pp-row');
        if (!row) return;
        const b = books[Number(row.dataset.i)];
        box.remove();
        onPick(b);
      });
    } catch (err) {
      console.error('Photobook picker error:', err);
      box.innerHTML = '<div class="pp-empty">โหลดรายการโฟโต้บุ๊คไม่สำเร็จ</div>';
    }
  };
})();
