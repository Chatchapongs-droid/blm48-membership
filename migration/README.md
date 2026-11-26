# ย้าย Supabase: rqhwzbrcgnpxtuaeoxml → fgovrwnjvdwvtsjeuhjj

สิ่งที่ย้าย: ตาราง 86 ตาราง, ฟังก์ชัน 314 ตัว, ข้อมูลทั้งหมด (~305 MB), ไฟล์ใน Storage 4 bucket (1,579 ไฟล์, ~870 MB),
cron 9 ตัว, Realtime 5 ตาราง, Storage policy 5 ตัว, Edge Function `send-push`
ไม่ต้องย้าย: Supabase Auth (มีผู้ใช้ 0 คน, ระบบใช้ตาราง `users` ของตัวเอง), Firebase, Vercel

> โฟลเดอร์ `migration/out/` จะมีข้อมูลผู้ใช้ทั้งหมดและ secret อยู่ในนั้น — อยู่ใน .gitignore แล้ว ห้ามส่งให้ใคร ลบทิ้งเมื่อย้ายเสร็จ

**เวลาที่เว็บใช้งานไม่ได้:** ประมาณ 20–40 นาที (ขั้นที่ 2–8) ควรทำช่วงคนน้อย และแจ้งล่วงหน้า

---

## ขั้นที่ 0 — เตรียม (เว็บยังใช้ได้ปกติ)

1. **โปรเจกต์ใหม่** ต้องเป็น Region **Southeast Asia (Singapore)** และ Postgres **17** (ดูที่ Settings → General / Infrastructure)
   แพ็กเกจ Free: ฐานข้อมูลจำกัด 500 MB (ใช้ ~305 MB) และ Storage 1 GB (ใช้ ~870 MB) — พอ แต่ใกล้เต็ม
2. **ติดตั้ง PostgreSQL 17 client** (มี `pg_dump`, `psql`):

   ```powershell
   winget install -e --id PostgreSQL.PostgreSQL.17
   ```

   แล้วเปิดเทอร์มินัลใหม่ และเพิ่ม path (ทำทุกครั้งที่เปิดเทอร์มินัลใหม่):

   ```powershell
   $env:Path += ';C:\Program Files\PostgreSQL\17\bin'
   ```

3. **Connection string ของทั้งสองโปรเจกต์**: Dashboard → ปุ่ม **Connect** → แท็บ **Session pooler** (ใช้ตัวนี้ เพราะเน็ตบ้านส่วนใหญ่ไม่มี IPv6)
   ใส่รหัสผ่านฐานข้อมูลแทน `[YOUR-PASSWORD]` เอง แล้วตั้งในเทอร์มินัล (ไม่ต้องส่งให้ใคร):

   ```powershell
   $env:OLD_DB_URL = 'postgresql://postgres.rqhwzbrcgnpxtuaeoxml:รหัสเดิม@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'
   ```

   ```powershell
   $env:NEW_DB_URL = 'postgresql://postgres.fgovrwnjvdwvtsjeuhjj:รหัสใหม่@...pooler.supabase.com:5432/postgres'
   ```

   ```powershell
   $env:NEW_REF = 'fgovrwnjvdwvtsjeuhjj'
   ```

4. **Key ของโปรเจกต์ใหม่**: Settings → API Keys
   - `service_role` / secret key → ตั้งในเทอร์มินัลเอง (ห้ามใส่ในโค้ดหน้าเว็บ):

     ```powershell
     $env:NEW_SUPABASE_URL = 'https://fgovrwnjvdwvtsjeuhjj.supabase.co'
     ```

     ```powershell
     $env:NEW_SERVICE_ROLE_KEY = 'วาง service_role key ของโปรเจกต์ใหม่'
     ```

   - `anon` / publishable key → ส่งให้ Claude ได้ (เป็น key สาธารณะ ใช้แก้โค้ดหน้าเว็บ)

5. **ก๊อปไฟล์ Storage รอบแรก** (เว็บยังใช้ได้ ใช้เวลานานสุด ทำล่วงหน้าได้):

   ```powershell
   New-Item -ItemType Directory -Force migration\out | Out-Null; psql $env:OLD_DB_URL -c "\copy (select bucket_id, name, coalesce(metadata->>'mimetype','application/octet-stream') as mimetype from storage.objects order by 1,2) to 'migration/out/storage_manifest.csv' with csv header"
   ```

   ```powershell
   node migration\copy-storage.mjs
   ```

   ถ้ามีไฟล์ไหนล้มเหลว รันคำสั่ง `node` ซ้ำได้ (ไฟล์ที่ก๊อปแล้วจะข้าม)

6. **Web Push (VAPID key)**: สร้างคู่ใหม่แล้ว เก็บอยู่ที่ `migration/out/vapid.json` (ไม่ขึ้น git — **อย่าลบไฟล์นี้** และควรสำรองไว้ที่ปลอดภัย เช่น password manager)
   public key ใส่ใน `assets/js/common.js` แล้ว (ยังไม่ได้ push — จะ push พร้อมขั้นที่ 7)
   ผลที่ผู้ใช้เห็น: คนที่เคยเปิดแจ้งเตือนไว้ (20 เครื่อง) ต้องเข้าหน้า Notification แล้วกดเปิดแจ้งเตือนอีกครั้ง (ปุ่มจะขึ้นเป็น "ปิด" ให้เอง)

---

## วันย้ายจริง

```powershell
cd 'D:\BLM48 Membership\migration'
```

**ขั้นที่ 2 — ปิดเว็บเดิม + export** (หยุด cron และบล็อก API ของโปรเจกต์เดิม แล้วดึงข้อมูลออก):

```powershell
.\1_freeze_and_export.ps1
```

ถ้ามีปัญหาตรงไหนแล้วอยากเปิดเว็บเดิมกลับ: `.\rollback_old.ps1`

**ขั้นที่ 3 — import เข้าโปรเจกต์ใหม่** (extension, policy, schema, ข้อมูล, Realtime, แก้ URL รูป 8,630 แถว, cron 9 ตัว):

```powershell
.\2_import.ps1
```

**ขั้นที่ 4 — ก๊อปไฟล์ Storage รอบสอง** (เฉพาะไฟล์ใหม่ที่อัปโหลดหลังรอบแรก):

```powershell
node .\copy-storage.mjs
```

**ขั้นที่ 5 — ตรวจ** (จำนวนแถวทุกตารางต้องตรงกัน):

```powershell
.\4_verify.ps1
```

**ขั้นที่ 6 — Edge Function** (ล็อกอิน Supabase CLI ด้วยบัญชีใหม่ในเบราว์เซอร์):

```powershell
npx supabase login
```

```powershell
.\5_set_push_secrets.ps1
```

(deploy `send-push` + ตั้ง secret 4 ตัวให้เอง โดยอ่านจาก `out\vapid.json` และ `out\schema.sql`)

**ขั้นที่ 7 — เปลี่ยนโค้ดหน้าเว็บ**: เตรียมไว้แล้วใน branch `supabase-cutover` (ยังไม่ push)
มี URL + publishable key ใหม่ (`supabase-client.js`), URL รูปสติกเกอร์ (`member-gift-stickers.js`), VAPID public key ใหม่ (`common.js`)
**ห้าม merge/push ก่อนขั้นที่ 3–6 ผ่าน** — บอก Claude ว่า "import ผ่านแล้ว" แล้ว Claude จะ merge เข้า main และ push ให้ Vercel deploy

```powershell
git merge supabase-cutover; git push origin main
```

**ขั้นที่ 8 — ทดสอบบนเว็บจริง**: ล็อกอิน, ดูฟีด/รูป, กดไลก์, โอน Token เล็กน้อย, อัปโหลดรูปโปรไฟล์, เปิดหน้า Shop / Campaign

**หลังย้าย**: เก็บโปรเจกต์เดิมไว้ (สถานะ freeze) อย่างน้อย 1 สัปดาห์ เผื่อต้องย้อนกลับ แล้วค่อยลบ และลบ `migration/out/`
