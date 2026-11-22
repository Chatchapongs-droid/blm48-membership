-- Song Vote (2026-11-22): กิจกรรมโหวตเพลง ใช้ระบบ Major Vote เดิม
-- applied via Supabase MCP migration "major_vote_song_kind"
--
-- major_vote_collections.vote_kind: 'member' (default) | 'song'
-- กิจกรรมเพลง: major_vote_candidates.member_name = ชื่อเพลง, profile_member = รูปปกเพลง
-- (Token / GE Token / Gift, โหมด Burned/Locked, ผลด่วน, ประกาศผล ใช้ของเดิมทั้งหมด)

alter table public.major_vote_collections
  add column if not exists vote_kind text not null default 'member';
alter table public.major_vote_collections drop constraint if exists major_vote_collections_vote_kind_check;
alter table public.major_vote_collections
  add constraint major_vote_collections_vote_kind_check check (vote_kind in ('member','song'));

-- admin_create_vote_event: เพิ่มพารามิเตอร์ท้าย p_vote_kind text default 'member'
--   (drop signature เดิมก่อนเพื่อไม่ให้มี overload ซ้ำ) และ insert vote_kind
-- คืนค่า 'voteKind' เพิ่มใน: get_vote_collections, get_major_vote_candidates,
--   admin_get_vote_event, admin_list_vote_campaigns
--
-- migration "admin_update_vote_candidate_profile":
--   admin_update_vote_candidate_profile(p_admin_username, p_candidate_id, p_profile)
--   เปลี่ยนรูปปกเพลง (เฉพาะกิจกรรม vote_kind = 'song')
