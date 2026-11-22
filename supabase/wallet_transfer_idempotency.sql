-- กันโอน Token ซ้ำเมื่อ timeout แล้วผู้ใช้กดโอนอีกครั้ง (2026-11-22)
-- หน้า transfer_wallet ส่ง p_request_id (สุ่มใหม่ทุกครั้งที่เข้าขั้นยืนยัน) ถ้ากดซ้ำด้วย id เดิม
-- จะได้ผลลัพธ์ของครั้งแรกกลับไป ไม่หัก Token ซ้ำ
-- เรียกแบบเดิม 3 พารามิเตอร์ (ไม่มี request id) ยังใช้ได้เหมือนเดิม

create table if not exists public.wallet_transfer_requests (
  request_id  text primary key,
  username    text not null,
  wallet_code text not null,
  amount      numeric not null,
  result      jsonb,
  created_at  timestamptz not null default now()
);
alter table public.wallet_transfer_requests enable row level security;
grant select, insert, update, delete on public.wallet_transfer_requests to service_role;

-- เนื้อหาการโอนเดิมย้ายไปเป็นฟังก์ชันภายใน (เรียกจากหน้าเว็บตรง ๆ ไม่ได้)
alter function public.transfer_token_by_wallet(text, text, numeric) rename to transfer_token_by_wallet_core_;
revoke execute on function public.transfer_token_by_wallet_core_(text, text, numeric) from public, anon, authenticated;

create or replace function public.transfer_token_by_wallet(
  p_username text, p_wallet_code text, p_amount numeric, p_request_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_req  text := nullif(btrim(coalesce(p_request_id, '')), '');
  v_code text := regexp_replace(coalesce(p_wallet_code, ''), '[^0-9]', '', 'g');
  v_amt  numeric := coalesce(p_amount, 0);
  v_n    int;
  v_prev record;
  v_res  jsonb;
begin
  if v_req is null then
    return public.transfer_token_by_wallet_core_(p_username, p_wallet_code, p_amount);
  end if;
  if length(v_req) > 64 then
    return jsonb_build_object('status','error','message','รหัสคำขอไม่ถูกต้อง');
  end if;

  -- คำขอซ้ำ (id เดิม) จะรอจนครั้งแรก commit แล้วไม่ insert เพิ่ม
  insert into public.wallet_transfer_requests (request_id, username, wallet_code, amount)
    values (v_req, p_username, v_code, v_amt)
    on conflict (request_id) do nothing;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    select * into v_prev from public.wallet_transfer_requests where request_id = v_req;
    if v_prev.username <> p_username or v_prev.wallet_code <> v_code or v_prev.amount <> v_amt then
      return jsonb_build_object('status','error','message','รหัสคำขอไม่ถูกต้อง');
    end if;
    return coalesce(v_prev.result,
      jsonb_build_object('status','error','message','กำลังดำเนินการโอน กรุณาตรวจสอบหน้า Transactions'));
  end if;

  v_res := public.transfer_token_by_wallet_core_(p_username, p_wallet_code, p_amount);
  update public.wallet_transfer_requests set result = v_res where request_id = v_req;
  return v_res;
end; $function$;

revoke execute on function public.transfer_token_by_wallet(text, text, numeric, text) from public;
grant execute on function public.transfer_token_by_wallet(text, text, numeric, text) to anon, authenticated, service_role;
