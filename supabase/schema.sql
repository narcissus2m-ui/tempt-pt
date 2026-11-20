-- TEMPT PT 가이드 · Supabase 데이터베이스 설정
-- 사용법: Supabase 대시보드 > SQL Editor > New query 에 이 파일 전체를 붙여넣고 Run.
-- 여러 번 실행해도 안전합니다. (기존 데이터는 그대로 두고 바뀐 규칙만 다시 적용)
--
-- 구조: 관리자 → 트레이너 → 회원
--   관리자: 모든 회원·트레이너를 보고, 회원을 트레이너에게 배정(여러 명 가능)
--   트레이너: 배정된 회원의 기록을 같이 보고 고침 (같은 회원을 맡은 트레이너끼리 공유)
--   회원: 초대 코드로 연결된 자기 기록만
-- 저장 원칙(앱과 동일): 회원 / 인바디 측정 / 운동 세션 3개가 기록의 전부이고
-- 영양·심박 존·1RM·회복·캘린더·운동 복기는 앱이 이 기록에서 계산합니다. 운동 목록(exercises)은 센터 공용 사전입니다.

-- ───────── 1. 사용자 프로필 (로그인 계정 1개 = 1행) ─────────
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'member',
  display_name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('admin', 'trainer', 'member'));

-- 가입 코드: 관리자·트레이너 가입은 관리자에게 받은 코드가 있어야 함 (회원 가입은 코드 없이)
create table if not exists public.gym_settings (
  id int primary key default 1 check (id = 1),
  admin_code text not null default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  trainer_code text not null default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  updated_at timestamptz not null default now()
);
insert into public.gym_settings (id) values (1) on conflict (id) do nothing;

-- 가입 직전: 고른 역할과 코드를 확인하고, 코드는 계정 정보에 남기지 않음
create or replace function public.check_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  want text := coalesce(new.raw_user_meta_data->>'role', 'member');
  code text := upper(trim(coalesce(new.raw_user_meta_data->>'signup_code', '')));
  r text := 'member';
begin
  if want = 'admin' then
    if not exists (select 1 from public.gym_settings where admin_code = code) then raise exception 'bad_signup_code'; end if;
    r := 'admin';
  elsif want = 'trainer' then
    if not exists (select 1 from public.gym_settings where trainer_code = code) then raise exception 'bad_signup_code'; end if;
    r := 'trainer';
  end if;
  new.raw_user_meta_data := (coalesce(new.raw_user_meta_data, '{}'::jsonb) - 'signup_code') || jsonb_build_object('role', r);
  return new;
end $$;
drop trigger if exists before_auth_user_created on auth.users;
create trigger before_auth_user_created before insert on auth.users
  for each row execute function public.check_new_user();

-- 가입하면 프로필 자동 생성 (위에서 확인한 역할 사용)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, role, display_name)
  values (
    new.id,
    case when new.raw_user_meta_data->>'role' in ('admin', 'trainer') then new.raw_user_meta_data->>'role' else 'member' end,
    coalesce(new.raw_user_meta_data->>'display_name', '')
  )
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 가입 화면에서 코드가 맞는지 미리 확인 (맞다/아니다만 알려줌)
create or replace function public.check_signup_code(want text, code text) returns boolean
language sql stable security definer set search_path = public as $$
  select case want
    when 'admin' then exists (select 1 from public.gym_settings where admin_code = upper(trim(code)))
    when 'trainer' then exists (select 1 from public.gym_settings where trainer_code = upper(trim(code)))
    else true end;
$$;
revoke all on function public.check_signup_code(text, text) from public;
grant execute on function public.check_signup_code(text, text) to anon, authenticated;

-- ───────── 2. 회원 (회원 본인 계정과 연결 가능) ─────────
create table if not exists public.members (
  id text primary key,
  trainer_id uuid references public.profiles(id) on delete set null,  -- 이 회원을 등록한 트레이너
  user_id uuid unique references public.profiles(id) on delete set null, -- 회원 본인 계정 (연결 전에는 비어 있음)
  invite_code text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  name text not null default '',
  data jsonb not null default '{}'::jsonb,  -- 성별·생년월일·목적·안정시 심박·식단 방식 등 회원 정보 전체
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists members_trainer_idx on public.members(trainer_id);

-- 회원 ↔ 담당 트레이너 (한 회원에 여러 트레이너)
create table if not exists public.member_trainers (
  member_id text not null references public.members(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (member_id, trainer_id)
);
create index if not exists member_trainers_trainer_idx on public.member_trainers(trainer_id);
-- 트레이너가 직접 등록한 회원은 그 트레이너가 자동으로 담당
create or replace function public.member_added() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.trainer_id is not null then
    insert into public.member_trainers (member_id, trainer_id) values (new.id, new.trainer_id) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists on_member_added on public.members;
create trigger on_member_added after insert on public.members
  for each row execute function public.member_added();
insert into public.member_trainers (member_id, trainer_id)
  select id, trainer_id from public.members where trainer_id is not null on conflict do nothing;

-- ───────── 3. 인바디 · 신체 측정 ─────────
create table if not exists public.measurements (
  id text primary key,
  member_id text not null references public.members(id) on delete cascade,
  date date not null,
  height_cm numeric,
  weight_kg numeric,
  smm_kg numeric,
  body_fat_pct numeric,
  created_at timestamptz not null default now()
);
create index if not exists measurements_member_idx on public.measurements(member_id, date);

-- ───────── 4. 운동 세션 (세트·유산소·사진/영상 경로는 entries 안에) ─────────
create table if not exists public.sessions (
  id text primary key,
  member_id text not null references public.members(id) on delete cascade,
  date date not null,
  time text,
  entries jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.sessions add column if not exists trainer_ids uuid[] not null default '{}';  -- 수업한 선생님 (비어 있으면 개인 운동)
alter table public.sessions add column if not exists note text not null default '';           -- 수업 내용
alter table public.sessions add column if not exists created_by uuid default auth.uid() references public.profiles(id) on delete set null;
create index if not exists sessions_member_idx on public.sessions(member_id, date);

-- ───────── 5. 다음 단계용: 친구, 지도자 연결 요청 ─────────
create table if not exists public.friendships (
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

create table if not exists public.coach_requests (
  id uuid primary key default gen_random_uuid(),
  member_user_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  message text not null default '',
  created_at timestamptz not null default now(),
  unique (member_user_id, trainer_id)
);

-- ───────── 6. 접근 규칙 (Row Level Security) ─────────
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.member_trainers, public.gym_settings to authenticated;
grant select, insert, delete on public.members to authenticated;
grant select, insert, update, delete on public.measurements, public.sessions, public.friendships, public.coach_requests to authenticated;
revoke insert, update, delete on public.member_trainers, public.gym_settings from authenticated, anon;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;
create or replace function public.is_trainer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('trainer', 'admin'));
$$;
-- 관리자는 전부, 트레이너는 배정된 회원, 회원은 자기 기록
create or replace function public.can_access_member(mid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin()
    or exists (select 1 from public.members m where m.id = mid and (m.trainer_id = auth.uid() or m.user_id = auth.uid()))
    or exists (select 1 from public.member_trainers t where t.member_id = mid and t.trainer_id = auth.uid());
$$;

alter table public.profiles enable row level security;
alter table public.gym_settings enable row level security;
alter table public.members enable row level security;
alter table public.member_trainers enable row level security;
alter table public.measurements enable row level security;
alter table public.sessions enable row level security;
alter table public.friendships enable row level security;
alter table public.coach_requests enable row level security;

-- profiles: 본인, 관리자는 전원, 같은 회원을 맡은 트레이너·연결된 회원·수업한 선생님·친구를 볼 수 있음. 수정은 이름만, 본인만.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  id = auth.uid()
  or public.is_admin()
  or exists (select 1 from public.member_trainers t where t.trainer_id = profiles.id and public.can_access_member(t.member_id))
  or exists (select 1 from public.members m where m.user_id = profiles.id and public.can_access_member(m.id))
  or exists (select 1 from public.sessions s where profiles.id = any(s.trainer_ids) and public.can_access_member(s.member_id))
  or exists (select 1 from public.friendships f where
      (f.requester_id = auth.uid() and f.addressee_id = profiles.id) or (f.addressee_id = auth.uid() and f.requester_id = profiles.id))
  or exists (select 1 from public.coach_requests c where
      (c.member_user_id = auth.uid() and c.trainer_id = profiles.id) or (c.trainer_id = auth.uid() and c.member_user_id = profiles.id))
);
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;

-- gym_settings: 관리자만 코드 열람
drop policy if exists gym_settings_select on public.gym_settings;
create policy gym_settings_select on public.gym_settings for select to authenticated using (public.is_admin());

-- members
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using (trainer_id = auth.uid() or user_id = auth.uid() or public.can_access_member(id));
drop policy if exists members_insert on public.members;
create policy members_insert on public.members for insert to authenticated with check (
  (public.is_admin() and user_id is null and (trainer_id is null or trainer_id = auth.uid()))
  or (trainer_id = auth.uid() and public.is_trainer() and user_id is null)
  or (user_id = auth.uid() and trainer_id is null)          -- 트레이너 없이 혼자 쓰는 회원
);
drop policy if exists members_update on public.members;
create policy members_update on public.members for update to authenticated
  using (public.can_access_member(id)) with check (public.can_access_member(id));
drop policy if exists members_delete on public.members;
create policy members_delete on public.members for delete to authenticated using (
  public.is_admin() or trainer_id = auth.uid()
  or (trainer_id is null and user_id = auth.uid() and not exists (select 1 from public.member_trainers t where t.member_id = members.id))
);
-- 등록 트레이너·연결 계정·초대 코드는 앱에서 직접 못 바꾸고, 아래 함수로만 바뀝니다.
revoke update on public.members from authenticated;
grant update (name, data, updated_at) on public.members to authenticated;

-- member_trainers: 그 회원에 접근할 수 있으면 담당 목록을 볼 수 있음. 배정·해제는 관리자 함수로만.
drop policy if exists member_trainers_select on public.member_trainers;
create policy member_trainers_select on public.member_trainers for select to authenticated
  using (public.can_access_member(member_id));

-- measurements / sessions: 그 회원에 접근할 수 있는 사람만
drop policy if exists measurements_all on public.measurements;
create policy measurements_all on public.measurements for all to authenticated
  using (public.can_access_member(member_id)) with check (public.can_access_member(member_id));
drop policy if exists sessions_all on public.sessions;
create policy sessions_all on public.sessions for all to authenticated
  using (public.can_access_member(member_id)) with check (public.can_access_member(member_id));

-- friendships
drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships for select to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());
drop policy if exists friendships_insert on public.friendships;
create policy friendships_insert on public.friendships for insert to authenticated
  with check (requester_id = auth.uid() and status = 'pending');
drop policy if exists friendships_update on public.friendships;
create policy friendships_update on public.friendships for update to authenticated
  using (addressee_id = auth.uid()) with check (addressee_id = auth.uid());
drop policy if exists friendships_delete on public.friendships;
create policy friendships_delete on public.friendships for delete to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- coach_requests
drop policy if exists coach_requests_select on public.coach_requests;
create policy coach_requests_select on public.coach_requests for select to authenticated
  using (member_user_id = auth.uid() or trainer_id = auth.uid());
drop policy if exists coach_requests_insert on public.coach_requests;
create policy coach_requests_insert on public.coach_requests for insert to authenticated
  with check (member_user_id = auth.uid() and status = 'pending');
drop policy if exists coach_requests_update on public.coach_requests;
create policy coach_requests_update on public.coach_requests for update to authenticated
  using (trainer_id = auth.uid()) with check (trainer_id = auth.uid());
drop policy if exists coach_requests_delete on public.coach_requests;
create policy coach_requests_delete on public.coach_requests for delete to authenticated
  using (member_user_id = auth.uid() or trainer_id = auth.uid());

-- ───────── 7. 함수: 초대 코드 연결, 연결 해제, 트레이너 배정, 가입 코드 새로 발급 ─────────
-- 회원이 트레이너에게 받은 초대 코드로 자기 기록과 연결
create or replace function public.claim_member(code text) returns text
language plpgsql security definer set search_path = public as $$
declare mid text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception 'already_linked'; end if;
  update public.members set user_id = auth.uid(), updated_at = now()
    where invite_code = upper(trim(code)) and user_id is null
    returning id into mid;
  if mid is null then raise exception 'invalid_code'; end if;
  return mid;
end $$;
revoke all on function public.claim_member(text) from public, anon;
grant execute on function public.claim_member(text) to authenticated;

-- 관리자 또는 담당 트레이너가 회원 앱 연결을 끊을 때 (코드도 새로 발급)
create or replace function public.unlink_member(mid text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_trainer() and public.can_access_member(mid)) then raise exception 'not_allowed'; end if;
  update public.members
    set user_id = null, invite_code = upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)), updated_at = now()
    where id = mid;
end $$;
revoke all on function public.unlink_member(text) from public, anon;
grant execute on function public.unlink_member(text) to authenticated;

-- 관리자: 회원에게 트레이너 배정 / 해제
create or replace function public.assign_trainer(mid text, tid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_allowed'; end if;
  if not exists (select 1 from public.profiles where id = tid and role in ('trainer', 'admin')) then raise exception 'not_trainer'; end if;
  insert into public.member_trainers (member_id, trainer_id) values (mid, tid) on conflict do nothing;
end $$;
create or replace function public.unassign_trainer(mid text, tid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_allowed'; end if;
  delete from public.member_trainers where member_id = mid and trainer_id = tid;
  update public.members set trainer_id = null where id = mid and trainer_id = tid;
end $$;
-- 관리자: 가입 코드 새로 발급 (kind = 'admin' | 'trainer')
create or replace function public.regen_signup_code(kind text) returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
begin
  if not public.is_admin() then raise exception 'not_allowed'; end if;
  if kind = 'admin' then update public.gym_settings set admin_code = c, updated_at = now() where id = 1;
  elsif kind = 'trainer' then update public.gym_settings set trainer_code = c, updated_at = now() where id = 1;
  else raise exception 'bad_kind'; end if;
  return c;
end $$;
revoke all on function public.assign_trainer(text, uuid), public.unassign_trainer(text, uuid), public.regen_signup_code(text) from public, anon;
grant execute on function public.assign_trainer(text, uuid), public.unassign_trainer(text, uuid), public.regen_signup_code(text) to authenticated;

-- ───────── 8. 사진·영상 저장소 (회원 폴더별, 그 회원에 접근할 수 있는 사람만) ─────────
-- 파일 경로: <회원 id>/<파일 id>.<확장자>, 파일 하나 최대 50MB
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('session-media', 'session-media', false, 52428800, array['image/*', 'video/*'])
on conflict (id) do nothing;
drop policy if exists session_media_select on storage.objects;
create policy session_media_select on storage.objects for select to authenticated
  using (bucket_id = 'session-media' and public.can_access_member((storage.foldername(name))[1]));
drop policy if exists session_media_insert on storage.objects;
create policy session_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'session-media' and public.can_access_member((storage.foldername(name))[1]));
drop policy if exists session_media_delete on storage.objects;
create policy session_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'session-media' and public.can_access_member((storage.foldername(name))[1]));

-- ───────── 9. 운동 목록 (센터 공용: 이름·주 부위·보조 부위·도구·설명·사진/영상) ─────────
create table if not exists public.exercises (
  id text primary key,
  name text not null,
  muscles text[] not null default '{}',   -- 주 부위 (chest, back, shoulders, biceps, triceps, quads, hamstrings, glutes, calves, abs)
  muscles2 text[] not null default '{}',  -- 보조 부위
  equipment text not null default '',      -- 바벨·덤벨·플레이트·케틀벨·클럽벨·머신·케이블·맨몸·밴드·기타
  note text not null default '',           -- 자세 포인트·설명
  media jsonb not null default '[]'::jsonb,-- 시범 사진·영상 경로 (lib/<운동 id>/파일)
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
-- 운동 종류: gym(헬스) / pilates(필라테스). 필라테스 도구는 체어·바렐·리포머·캐딜락·매트
alter table public.exercises add column if not exists category text not null default 'gym';
alter table public.exercises drop constraint if exists exercises_category_check;
alter table public.exercises add constraint exercises_category_check check (category in ('gym', 'pilates'));
-- 기본 운동 (처음 한 번만 들어가고, 이후 수정·삭제한 내용은 그대로 둠)
insert into public.exercises (id, name, muscles, muscles2, equipment) values
  ('bench', '벤치프레스', '{chest}', '{triceps,shoulders}', '바벨'),
  ('incline_db', '인클라인 덤벨프레스', '{chest}', '{shoulders,triceps}', '덤벨'),
  ('dip', '딥스', '{chest,triceps}', '{shoulders}', '맨몸'),
  ('ohp', '오버헤드프레스', '{shoulders}', '{triceps}', '바벨'),
  ('lateral', '사이드 레터럴 레이즈', '{shoulders}', '{}', '덤벨'),
  ('pushdown', '트라이셉스 푸시다운', '{triceps}', '{}', '케이블'),
  ('deadlift', '데드리프트', '{hamstrings,glutes,back}', '{quads}', '바벨'),
  ('row', '바벨 로우', '{back}', '{biceps}', '바벨'),
  ('pullup', '풀업', '{back}', '{biceps}', '맨몸'),
  ('latpull', '랫풀다운', '{back}', '{biceps}', '머신'),
  ('curl', '바벨 컬', '{biceps}', '{}', '바벨'),
  ('squat', '백스쿼트', '{quads,glutes}', '{hamstrings}', '바벨'),
  ('legpress', '레그프레스', '{quads}', '{glutes}', '머신'),
  ('rdl', '루마니안 데드리프트', '{hamstrings}', '{glutes,back}', '바벨'),
  ('hipthrust', '힙 쓰러스트', '{glutes}', '{hamstrings}', '바벨'),
  ('legcurl', '레그 컬', '{hamstrings}', '{}', '머신'),
  ('calf', '카프 레이즈', '{calves}', '{}', '머신'),
  ('cablecrunch', '케이블 크런치', '{abs}', '{}', '케이블')
on conflict (id) do nothing;
insert into public.exercises (id, name, category, muscles, muscles2, equipment) values
  ('pi_footwork', '풋워크', 'pilates', '{quads,glutes}', '{calves}', '리포머'),
  ('pi_hundred', '헌드레드', 'pilates', '{abs}', '{}', '매트'),
  ('pi_rollup', '롤업', 'pilates', '{abs}', '{}', '매트'),
  ('pi_elephant', '엘리펀트', 'pilates', '{hamstrings,abs}', '{}', '리포머'),
  ('pi_longstretch', '롱 스트레치', 'pilates', '{abs,shoulders}', '{chest}', '리포머'),
  ('pi_rolldown', '롤다운', 'pilates', '{abs}', '{back}', '캐딜락'),
  ('pi_legspring', '레그 스프링', 'pilates', '{hamstrings,glutes}', '{abs}', '캐딜락'),
  ('pi_pumpchair', '풋워크 (체어)', 'pilates', '{quads,glutes}', '{calves}', '체어'),
  ('pi_swanchair', '스완 (체어)', 'pilates', '{back}', '{glutes}', '체어'),
  ('pi_swanbarrel', '스완 (바렐)', 'pilates', '{back}', '{glutes}', '바렐'),
  ('pi_sidestretch', '사이드 스트레치', 'pilates', '{abs}', '{}', '바렐')
on conflict (id) do nothing;
grant select, insert, update, delete on public.exercises to authenticated;
alter table public.exercises enable row level security;
-- 모두 보고 추가할 수 있고, 수정·삭제는 선생님(관리자·트레이너) 또는 직접 추가한 사람만
drop policy if exists exercises_select on public.exercises;
create policy exercises_select on public.exercises for select to authenticated using (true);
drop policy if exists exercises_insert on public.exercises;
create policy exercises_insert on public.exercises for insert to authenticated with check (created_by = auth.uid());
drop policy if exists exercises_update on public.exercises;
create policy exercises_update on public.exercises for update to authenticated
  using (public.is_trainer() or created_by = auth.uid()) with check (public.is_trainer() or created_by = auth.uid());
drop policy if exists exercises_delete on public.exercises;
create policy exercises_delete on public.exercises for delete to authenticated using (public.is_trainer() or created_by = auth.uid());
-- 운동 시범 사진·영상: lib/<운동 id>/파일 — 모두 볼 수 있고, 올리고 지우는 건 그 운동을 고칠 수 있는 사람만
drop policy if exists exercise_media_select on storage.objects;
create policy exercise_media_select on storage.objects for select to authenticated
  using (bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib');
drop policy if exists exercise_media_insert on storage.objects;
create policy exercise_media_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib'
  and (public.is_trainer() or not exists (select 1 from public.exercises e where e.id = (storage.foldername(name))[2] and e.created_by is distinct from auth.uid())));
drop policy if exists exercise_media_delete on storage.objects;
create policy exercise_media_delete on storage.objects for delete to authenticated using (
  bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib'
  and (public.is_trainer() or not exists (select 1 from public.exercises e where e.id = (storage.foldername(name))[2] and e.created_by is distinct from auth.uid())));

-- 이미 가입한 계정이 있으면 프로필을 채워 둠 (관리자 권한은 코드로만)
insert into public.profiles (id, role, display_name)
select u.id,
  case when u.raw_user_meta_data->>'role' = 'trainer' then 'trainer' else 'member' end,
  coalesce(u.raw_user_meta_data->>'display_name', '')
from auth.users u
on conflict (id) do nothing;
