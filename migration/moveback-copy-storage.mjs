// Move back: copy Storage files that exist in Singapore but not in the old project.
// Reads out/moveback_missing.csv (bucket_id,name,mimetype - made by moveback.ps1).
// Needs $env:OLD_SERVICE_ROLE_KEY (old project's sb_secret_ / service_role key).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC_URL = 'https://fgovrwnjvdwvtsjeuhjj.supabase.co';
const DST_URL = 'https://rqhwzbrcgnpxtuaeoxml.supabase.co';
const KEY = process.env.OLD_SERVICE_ROLE_KEY || '';
if (!KEY) throw new Error('Set OLD_SERVICE_ROLE_KEY');
const authHeaders = { apikey: KEY, ...(KEY.startsWith('eyJ') ? { Authorization: `Bearer ${KEY}` } : {}) };

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), 'out');
const listPath = path.join(dir, 'moveback_missing.csv');
const failPath = path.join(dir, 'moveback_failed.txt');

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

async function copyOne(bucket, name, mime) {
  const src = await fetch(`${SRC_URL}/storage/v1/object/public/${bucket}/${encPath(name)}`);
  if (!src.ok) throw new Error(`download ${src.status}`);
  const body = Buffer.from(await src.arrayBuffer());
  const dst = await fetch(`${DST_URL}/storage/v1/object/${bucket}/${encPath(name)}`, {
    method: 'POST',
    headers: { ...authHeaders, 'Content-Type': mime || 'application/octet-stream', 'x-upsert': 'true', 'cache-control': 'max-age=31536000' },
    body,
  });
  if (!dst.ok) throw new Error(`upload ${dst.status} ${await dst.text()}`);
}

const rows = fs.existsSync(listPath) ? parseCsv(fs.readFileSync(listPath, 'utf8')).slice(1) : [];
console.log(`files to copy back: ${rows.length}`);
let ok = 0; const failed = []; let idx = 0;
async function worker() {
  while (idx < rows.length) {
    const [bucket, name, mime] = rows[idx++];
    let err;
    for (let a = 1; a <= 3; a++) {
      try { await copyOne(bucket, name, mime); err = null; break; }
      catch (e) { err = e; await new Promise(r => setTimeout(r, 1000 * a)); }
    }
    if (err) failed.push(`${bucket}/${name}\t${err.message}`); else ok++;
  }
}
await Promise.all(Array.from({ length: 4 }, worker));
fs.writeFileSync(failPath, failed.join('\n'));
console.log(`copied ${ok}, failed ${failed.length}${failed.length ? ' -> out/moveback_failed.txt' : ''}`);
if (failed.length) process.exitCode = 1;
