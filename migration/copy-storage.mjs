// Step 4: copy all Storage files OLD -> NEW (4 public buckets, ~1,600 files, ~870 MB).
// Safe to run more than once: files already copied are skipped (out/storage_done.txt),
// so run it once BEFORE the freeze (bulk copy, no downtime) and once more AFTER the export
// to pick up the last new files.
//
// Needs (set them yourself in this terminal):
//   $env:NEW_SUPABASE_URL      = "https://<new-ref>.supabase.co"
//   $env:NEW_SERVICE_ROLE_KEY  = "<new project service_role / secret key>"
// and out/storage_manifest.csv (made by 1_freeze_and_export.ps1, or for the pre-copy run:
//   psql $env:OLD_DB_URL -c "\copy (select bucket_id, name, coalesce(metadata->>'mimetype','application/octet-stream') as mimetype from storage.objects order by 1,2) to 'migration/out/storage_manifest.csv' with csv header"
// )
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const OLD_URL = 'https://rqhwzbrcgnpxtuaeoxml.supabase.co';
// where to download from: the old project by default, or another copy (SOURCE_SUPABASE_URL)
const SRC_URL = (process.env.SOURCE_SUPABASE_URL || OLD_URL).replace(/\/+$/, '');
const WORKERS = Math.max(1, Number(process.env.COPY_WORKERS) || 6);
const NEW_URL = (process.env.NEW_SUPABASE_URL || '').replace(/\/+$/, '');
const KEY = process.env.NEW_SERVICE_ROLE_KEY || '';
if (!/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(NEW_URL) || NEW_URL === OLD_URL || NEW_URL === SRC_URL) throw new Error('Set NEW_SUPABASE_URL to the new project URL');
if (!KEY) throw new Error('Set NEW_SERVICE_ROLE_KEY');

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), 'out');
const manifestPath = path.join(dir, 'storage_manifest.csv');
const donePath = path.join(dir, `storage_done_${NEW_URL.slice(8, 28)}.txt`); // per target project
const failPath = path.join(dir, 'storage_failed.txt');

const BUCKETS = [
  { id: 'post-audio', public: true, file_size_limit: 8388608, allowed_mime_types: ['audio/webm', 'audio/mp4', 'audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/x-m4a', 'audio/aac'] },
  { id: 'post-images', public: true, file_size_limit: 6291456, allowed_mime_types: ['image/jpeg', 'image/png', 'image/webp', 'image/gif'] },
  { id: 'profile-images', public: true, file_size_limit: 3145728, allowed_mime_types: ['image/jpeg', 'image/png'] },
  { id: 'app-assets', public: true, file_size_limit: null, allowed_mime_types: null },
];

// new-style secret keys (sb_secret_...) go in apikey only; legacy JWT keys also as Bearer
const authHeaders = { apikey: KEY, ...(KEY.startsWith('eyJ') ? { Authorization: `Bearer ${KEY}` } : {}) };

function parseCsv(text) {
  const rows = []; let row = [], cur = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(cur); cur = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(cur); rows.push(row); row = []; cur = ''; }
    else cur += ch;
  }
  if (cur || row.length) { row.push(cur); rows.push(row); }
  return rows.filter(r => r.length >= 3 && r[0]);
}
const encPath = (name) => name.split('/').map(encodeURIComponent).join('/');

async function ensureBuckets() {
  for (const b of BUCKETS) {
    const res = await fetch(`${NEW_URL}/storage/v1/bucket`, {
      method: 'POST', headers: { ...authHeaders, 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: b.id, name: b.id, public: b.public, file_size_limit: b.file_size_limit, allowed_mime_types: b.allowed_mime_types }),
    });
    const txt = await res.text();
    if (res.ok) console.log(`bucket ${b.id}: created`);
    else if (/already exists|Duplicate/i.test(txt)) console.log(`bucket ${b.id}: exists`);
    else throw new Error(`bucket ${b.id}: ${res.status} ${txt}`);
  }
}

async function copyOne(bucket, name, mime) {
  const src = await fetch(`${SRC_URL}/storage/v1/object/public/${bucket}/${encPath(name)}`);
  if (!src.ok) throw new Error(`download ${src.status}`);
  const body = Buffer.from(await src.arrayBuffer());
  const dst = await fetch(`${NEW_URL}/storage/v1/object/${bucket}/${encPath(name)}`, {
    method: 'POST',
    headers: { ...authHeaders, 'Content-Type': mime || 'application/octet-stream', 'x-upsert': 'true', 'cache-control': 'max-age=3600' },
    body,
  });
  if (!dst.ok) throw new Error(`upload ${dst.status} ${await dst.text()}`);
  return body.length;
}

async function main() {
  if (!fs.existsSync(manifestPath)) throw new Error(`Missing ${manifestPath}`);
  const rows = parseCsv(fs.readFileSync(manifestPath, 'utf8')).slice(1); // skip header
  const done = new Set(fs.existsSync(donePath) ? fs.readFileSync(donePath, 'utf8').split('\n').filter(Boolean) : []);
  const todo = rows.filter(([b, n]) => !done.has(`${b}/${n}`));
  console.log(`source ${SRC_URL} -> ${NEW_URL}`);
  console.log(`files: ${rows.length} total, ${rows.length - todo.length} already copied, ${todo.length} to copy`);
  await ensureBuckets();

  let ok = 0, bytes = 0; const failed = [];
  let idx = 0;
  async function worker() {
    while (idx < todo.length) {
      const [bucket, name, mime] = todo[idx++];
      let lastErr;
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          bytes += await copyOne(bucket, name, mime);
          fs.appendFileSync(donePath, `${bucket}/${name}\n`);
          ok++; lastErr = null; break;
        } catch (e) { lastErr = e; await new Promise(r => setTimeout(r, 1000 * attempt)); }
      }
      if (lastErr) failed.push(`${bucket}/${name}\t${lastErr.message}`);
      if ((ok + failed.length) % 50 === 0) console.log(`  ${ok + failed.length}/${todo.length}  (${(bytes / 1048576).toFixed(0)} MB)`);
    }
  }
  await Promise.all(Array.from({ length: WORKERS }, worker));
  fs.writeFileSync(failPath, failed.join('\n'));
  console.log(`done: ${ok} copied (${(bytes / 1048576).toFixed(0)} MB), ${failed.length} failed${failed.length ? ' -> see out/storage_failed.txt, then run again' : ''}`);
  if (failed.length) process.exitCode = 1;
}
main().catch(e => { console.error(e.message); process.exit(1); });
