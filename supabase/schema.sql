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
-- (예전 한 번만 쓰던 담당 채우기는 13절 센터 이전으로 대체)

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

-- ───────── 10. 즐겨찾기 운동 (계정마다, 헬스·필라테스 각 5개까지는 앱에서 제한) ─────────
alter table public.profiles add column if not exists fav_exercises text[] not null default '{}';
create or replace function public.set_fav_exercises(ids text[]) returns void
language sql security definer set search_path = public as $$
  update public.profiles set fav_exercises = coalesce(ids[1:10], '{}') where id = auth.uid();
$$;
revoke all on function public.set_fav_exercises(text[]) from public, anon;
grant execute on function public.set_fav_exercises(text[]) to authenticated;

-- ───────── 11. 강사 관리 (관리자: 이름·역할·연락처·메모 수정, 강사 해제) ─────────
create table if not exists public.staff_notes (
  trainer_id uuid primary key references public.profiles(id) on delete cascade,
  phone text not null default '',
  memo text not null default '',   -- 관리자만 보는 메모
  updated_at timestamptz not null default now()
);
grant select on public.staff_notes to authenticated;
alter table public.staff_notes enable row level security;
drop policy if exists staff_notes_select on public.staff_notes;
create policy staff_notes_select on public.staff_notes for select to authenticated using (public.is_admin());
create or replace function public.save_staff(tid uuid, nm text, rl text, ph text, mm text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_allowed'; end if;
  if rl not in ('admin', 'trainer', 'member') then raise exception 'bad_role'; end if;
  if tid = auth.uid() and rl <> 'admin' then raise exception 'self_role'; end if;
  if not exists (select 1 from public.profiles where id = tid and role in ('admin', 'trainer')) then raise exception 'not_trainer'; end if;
  update public.profiles set display_name = left(coalesce(nullif(trim(nm), ''), display_name), 40), role = rl where id = tid;
  if rl = 'member' then
    delete from public.member_trainers where trainer_id = tid;
    update public.members set trainer_id = null where trainer_id = tid;
    delete from public.staff_notes where trainer_id = tid;
  else
    insert into public.staff_notes (trainer_id, phone, memo) values (tid, left(coalesce(ph, ''), 30), left(coalesce(mm, ''), 2000))
      on conflict (trainer_id) do update set phone = excluded.phone, memo = excluded.memo, updated_at = now();
  end if;
end $$;
revoke all on function public.save_staff(uuid, text, text, text, text) from public, anon;
grant execute on function public.save_staff(uuid, text, text, text, text) to authenticated;

-- ───────── 12. 역할별 권한 정리 (관리자 · 강사 · 회원) ─────────
-- 수업 기록: 관리자·강사는 접근 가능한 회원의 기록 모두. 회원은 보기만 하고, 자기가 남긴 개인 운동(선생님 없음)만 추가·수정·삭제
drop policy if exists sessions_all on public.sessions;
drop policy if exists sessions_select on public.sessions;
create policy sessions_select on public.sessions for select to authenticated using (public.can_access_member(member_id));
drop policy if exists sessions_insert on public.sessions;
create policy sessions_insert on public.sessions for insert to authenticated with check (
  public.can_access_member(member_id)
  and (public.is_trainer() or (created_by = auth.uid() and coalesce(cardinality(trainer_ids), 0) = 0)));
drop policy if exists sessions_update on public.sessions;
create policy sessions_update on public.sessions for update to authenticated
  using (public.can_access_member(member_id) and (public.is_trainer() or (created_by = auth.uid() and coalesce(cardinality(trainer_ids), 0) = 0)))
  with check (public.can_access_member(member_id) and (public.is_trainer() or (created_by = auth.uid() and coalesce(cardinality(trainer_ids), 0) = 0)));
drop policy if exists sessions_delete on public.sessions;
create policy sessions_delete on public.sessions for delete to authenticated
  using (public.can_access_member(member_id) and (public.is_trainer() or (created_by = auth.uid() and coalesce(cardinality(trainer_ids), 0) = 0)));

-- 회원 정보의 선생님 메모(data.memo): 담당 선생님이 있는 회원은 본인이 바꿀 수 없음
create or replace function public.keep_staff_memo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_trainer()
     and (new.trainer_id is not null or exists (select 1 from public.member_trainers t where t.member_id = new.id)) then
    new.data := jsonb_set(coalesce(new.data, '{}'::jsonb), '{memo}', coalesce(old.data -> 'memo', '""'::jsonb));
  end if;
  return new;
end $$;
drop trigger if exists members_keep_staff_memo on public.members;
create trigger members_keep_staff_memo before update on public.members for each row execute function public.keep_staff_memo();

-- 운동 목록: 추가·수정·삭제와 시범 사진/영상은 관리자·강사만 (회원은 보기와 즐겨찾기)
drop policy if exists exercises_insert on public.exercises;
create policy exercises_insert on public.exercises for insert to authenticated with check (public.is_trainer() and created_by = auth.uid());
drop policy if exists exercises_update on public.exercises;
create policy exercises_update on public.exercises for update to authenticated using (public.is_trainer()) with check (public.is_trainer());
drop policy if exists exercises_delete on public.exercises;
create policy exercises_delete on public.exercises for delete to authenticated using (public.is_trainer());
drop policy if exists exercise_media_insert on storage.objects;
create policy exercise_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib' and public.is_trainer());
drop policy if exists exercise_media_delete on storage.objects;
create policy exercise_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib' and public.is_trainer());

-- ───────── 13. 센터(관리자 계정 단위) · 공유 범위 · 3일 수정 제한 · 공개/비공개 ─────────
-- 센터 = 관리자 계정이 운영하는 곳. 강사는 가입 코드로 센터에 들어오고, 회원은 센터가 보낸 초대 코드로 연결합니다.
--   회원은 코드 없이도 가입해서 혼자 기록할 수 있고, 여러 센터와 연결될 수 있습니다.
--   관리자: 자기 센터 회원 전부 / 강사: 자기 센터에서 배정받은 회원만 / 회원: 자기 기록 전부
--   연결이나 배정이 풀리면 서로 볼 수 없습니다.
-- 기록(운동 세션·인바디)마다 어느 센터에서 썼는지(center_id, 비어 있으면 회원 본인 기록)와 공개 여부(is_public)를 남깁니다.
--   다른 센터에서 쓴 기록과 회원 본인 기록은 회원이 비공개로 돌릴 수 있고, 비공개면 그 기록을 쓴 센터 밖에서는 "비공개"로만 보입니다.
--   고치기·지우기: 회원은 자기가 쓴 기록을 언제든, 강사는 자기 센터 기록을 쓴 지 3일 안에만, 관리자는 자기 센터 기록을 언제든.
-- 운동 목록: 누구나 추가, 고치고 지우는 건 추가한 사람만. 서로 연결된 사람(같은 센터 강사끼리, 관리자↔센터 회원, 강사↔배정 회원)끼리 공유.

create table if not exists public.centers (
  id uuid primary key default gen_random_uuid(),
  name text not null default '',
  admin_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  trainer_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  created_at timestamptz not null default now()
);
create table if not exists public.center_staff (
  center_id uuid not null references public.centers(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'trainer' check (role in ('admin', 'trainer')),
  created_at timestamptz not null default now(),
  primary key (center_id, user_id)
);
create index if not exists center_staff_user_idx on public.center_staff(user_id);
create table if not exists public.center_members (
  center_id uuid not null references public.centers(id) on delete cascade,
  member_id text not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (center_id, member_id)
);
create index if not exists center_members_member_idx on public.center_members(member_id);
alter table public.member_trainers add column if not exists center_id uuid references public.centers(id) on delete cascade;
alter table public.sessions add column if not exists center_id uuid references public.centers(id) on delete set null;
alter table public.sessions add column if not exists is_public boolean not null default true;
alter table public.measurements add column if not exists center_id uuid references public.centers(id) on delete set null;
alter table public.measurements add column if not exists is_public boolean not null default true;
alter table public.measurements add column if not exists created_by uuid references public.profiles(id) on delete set null;
alter table public.measurements alter column created_by set default auth.uid();
-- 회원 기록을 합칠 때(이미 자기 기록이 있는 회원이 센터 초대 코드로 연결) 예전 id로 저장된 사진·영상 경로를 위해
create table if not exists public.member_aliases (
  old_id text primary key,
  member_id text not null references public.members(id) on delete cascade
);

-- 처음 한 번: 지금까지의 하나뿐인 센터를 "TEMPT PT" 센터로 옮김 (가입 코드도 그대로)
do $$
declare c uuid;
begin
  if not exists (select 1 from public.centers) then
    insert into public.centers (name, admin_code, trainer_code)
      select 'TEMPT PT', admin_code, trainer_code from public.gym_settings where id = 1 returning id into c;
    if c is null then insert into public.centers (name) values ('TEMPT PT') returning id into c; end if;
    insert into public.center_staff (center_id, user_id, role)
      select c, id, role from public.profiles where role in ('admin', 'trainer') on conflict do nothing;
    -- 혼자 쓰던 회원(본인 계정, 담당 없음)은 개인 회원, 나머지는 모두 이 센터 회원
    insert into public.center_members (center_id, member_id)
      select c, m.id from public.members m
      where not (m.user_id is not null and m.trainer_id is null and not exists (select 1 from public.member_trainers t where t.member_id = m.id))
      on conflict do nothing;
    update public.member_trainers set center_id = c where center_id is null;
    update public.sessions s set center_id = c
      where exists (select 1 from public.center_members cm where cm.member_id = s.member_id and cm.center_id = c)
        and (coalesce(cardinality(s.trainer_ids), 0) > 0 or not exists (select 1 from public.members m where m.id = s.member_id and m.user_id is not distinct from s.created_by));
    update public.measurements x set center_id = c
      where exists (select 1 from public.center_members cm where cm.member_id = x.member_id and cm.center_id = c);
    update public.measurements x set created_by = m.user_id from public.members m
      where m.id = x.member_id and x.center_id is null and x.created_by is null;
  end if;
end $$;

-- ── 권한 판단 함수 ──
create or replace function public.is_center_admin(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.center_staff where center_id = c and user_id = auth.uid() and role = 'admin');
$$;
create or replace function public.is_center_staff(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.center_staff where center_id = c and user_id = auth.uid());
$$;
-- 어느 센터든 관리자/강사인지 (화면 구분용, 다른 센터 회원을 보는 권한은 아님)
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.center_staff where user_id = auth.uid() and role = 'admin');
$$;
create or replace function public.is_trainer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.center_staff where user_id = auth.uid());
$$;
create or replace function public.is_member_owner(mid text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where id = mid and user_id = auth.uid());
$$;
-- 센터 c에서 이 회원을 볼 수 있는지: 그 센터 관리자이거나, 그 센터에서 배정받은 강사
create or replace function public.staff_access(mid text, c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select c is not null
    and exists (select 1 from public.center_members where center_id = c and member_id = mid)
    and (public.is_center_admin(c)
      or (public.is_center_staff(c) and exists (select 1 from public.member_trainers t where t.member_id = mid and t.trainer_id = auth.uid() and t.center_id = c)));
$$;
create or replace function public.can_access_member(mid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_member_owner(mid)
    or exists (select 1 from public.center_members cm where cm.member_id = mid and public.staff_access(mid, cm.center_id))
    or exists (select 1 from public.member_aliases a where a.old_id = mid and (public.is_member_owner(a.member_id)
         or exists (select 1 from public.center_members cm where cm.member_id = a.member_id and public.staff_access(a.member_id, cm.center_id))));
$$;
-- 기록 보기: 본인, 그 기록을 쓴 센터, 또는 공개 기록이면 회원에게 접근할 수 있는 다른 센터
create or replace function public.can_see_record(mid text, cid uuid, pub boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_member_owner(mid)
    or exists (select 1 from public.center_members cm where cm.member_id = mid and public.staff_access(mid, cm.center_id) and (cm.center_id = cid or pub));
$$;
-- 기록 고치기·지우기: 회원은 자기가 쓴 기록 언제든 / 관리자는 자기 센터 기록 언제든 / 강사는 자기 센터 기록을 쓴 지 3일 안에
create or replace function public.can_edit_record(mid text, cid uuid, by uuid, cat timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select (cid is null and by = auth.uid() and public.is_member_owner(mid))
    or (cid is not null and public.staff_access(mid, cid) and (public.is_center_admin(cid) or cat > now() - interval '3 days'));
$$;
-- 두 계정이 서로 연결돼 있는지 (운동 목록·이름 공유)
create or replace function public.connected(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select a = b
    or exists (select 1 from public.center_staff s1 join public.center_staff s2 on s1.center_id = s2.center_id where s1.user_id = a and s2.user_id = b)
    or exists (select 1 from public.members m join public.center_members cm on cm.member_id = m.id join public.center_staff s on s.center_id = cm.center_id
      where ((m.user_id = a and s.user_id = b) or (m.user_id = b and s.user_id = a))
        and (s.role = 'admin' or exists (select 1 from public.member_trainers t where t.member_id = m.id and t.trainer_id = s.user_id and t.center_id = s.center_id)));
$$;
-- 직원이 이 회원 기록을 쓸 때 쓰는 센터 (관리자인 센터 먼저)
create or replace function public.staff_center_for(mid text) returns uuid
language sql stable security definer set search_path = public as $$
  select cm.center_id from public.center_members cm join public.center_staff s on s.center_id = cm.center_id and s.user_id = auth.uid()
  where cm.member_id = mid and public.staff_access(mid, cm.center_id)
  order by (s.role = 'admin') desc, cm.created_at limit 1;
$$;

grant select on public.centers, public.center_staff, public.center_members to authenticated;
revoke insert, update, delete on public.centers, public.center_staff, public.center_members, public.member_aliases from authenticated, anon;
alter table public.centers enable row level security;
alter table public.center_staff enable row level security;
alter table public.center_members enable row level security;
alter table public.member_aliases enable row level security;
drop policy if exists centers_select on public.centers;
create policy centers_select on public.centers for select to authenticated using (
  public.is_center_staff(id) or exists (select 1 from public.center_members cm join public.members m on m.id = cm.member_id where cm.center_id = centers.id and m.user_id = auth.uid()));
-- 가입 코드는 관리자만 (centers 표 대신 아래 함수로 읽음)
revoke select on public.centers from authenticated;
grant select (id, name, created_at) on public.centers to authenticated;
create or replace function public.my_center_codes() returns table (id uuid, name text, admin_code text, trainer_code text)
language sql stable security definer set search_path = public as $$
  select c.id, c.name, c.admin_code, c.trainer_code from public.centers c where public.is_center_admin(c.id) order by c.created_at;
$$;
drop policy if exists center_staff_select on public.center_staff;
create policy center_staff_select on public.center_staff for select to authenticated using (public.connected(auth.uid(), user_id));
drop policy if exists center_members_select on public.center_members;
create policy center_members_select on public.center_members for select to authenticated using (public.can_access_member(member_id));

-- profiles: 본인과 연결된 사람, 내가 볼 수 있는 수업을 한 강사
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (
  public.connected(auth.uid(), id)
  or exists (select 1 from public.sessions s where profiles.id = any(s.trainer_ids) and public.can_see_record(s.member_id, s.center_id, s.is_public))
  or exists (select 1 from public.sessions s where profiles.id = s.created_by and public.can_see_record(s.member_id, s.center_id, s.is_public))
  or exists (select 1 from public.friendships f where
      (f.requester_id = auth.uid() and f.addressee_id = profiles.id) or (f.addressee_id = auth.uid() and f.requester_id = profiles.id))
);
drop policy if exists gym_settings_select on public.gym_settings;
create policy gym_settings_select on public.gym_settings for select to authenticated using (false);

-- ── 가입: 회원은 코드 없이, 강사는 센터 강사 코드, 관리자는 센터 관리자 코드(합류) 또는 새 센터 이름 ──
create or replace function public.check_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  want text := coalesce(new.raw_user_meta_data->>'role', 'member');
  code text := upper(trim(coalesce(new.raw_user_meta_data->>'signup_code', '')));
  cname text := trim(coalesce(new.raw_user_meta_data->>'center_name', ''));
  r text := 'member'; c uuid := null;
begin
  if want = 'admin' then
    if code <> '' then
      select id into c from public.centers where admin_code = code;
      if c is null then raise exception 'bad_signup_code'; end if;
    elsif cname = '' then raise exception 'need_center_name';
    end if;
    r := 'admin';
  elsif want = 'trainer' then
    select id into c from public.centers where trainer_code = code;
    if c is null then raise exception 'bad_signup_code'; end if;
    r := 'trainer';
  end if;
  new.raw_user_meta_data := (coalesce(new.raw_user_meta_data, '{}'::jsonb) - 'signup_code' - 'center_id')
    || jsonb_build_object('role', r) || case when c is null then '{}'::jsonb else jsonb_build_object('center_id', c) end;
  return new;
end $$;
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text := case when new.raw_user_meta_data->>'role' in ('admin', 'trainer') then new.raw_user_meta_data->>'role' else 'member' end;
  c uuid := nullif(new.raw_user_meta_data->>'center_id', '')::uuid;
begin
  insert into public.profiles (id, role, display_name)
  values (new.id, r, coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (id) do nothing;
  if r = 'admin' and c is null then
    insert into public.centers (name) values (left(coalesce(nullif(trim(new.raw_user_meta_data->>'center_name'), ''), '내 센터'), 40)) returning id into c;
  end if;
  if r in ('admin', 'trainer') and c is not null then
    insert into public.center_staff (center_id, user_id, role) values (c, new.id, r) on conflict do nothing;
  end if;
  return new;
end $$;
create or replace function public.check_signup_code(want text, code text) returns boolean
language sql stable security definer set search_path = public as $$
  select case want
    when 'admin' then trim(coalesce(code, '')) = '' or exists (select 1 from public.centers where admin_code = upper(trim(code)))
    when 'trainer' then exists (select 1 from public.centers where trainer_code = upper(trim(code)))
    else true end;
$$;

-- ── 회원 ──
-- 직원이 등록한 회원은 등록한 사람의 센터 회원이 되고, 강사가 등록하면 그 강사가 담당
create or replace function public.member_added() returns trigger
language plpgsql security definer set search_path = public as $$
declare c uuid; adm boolean;
begin
  if new.trainer_id is not null and new.user_id is null then
    select s.center_id, s.role = 'admin' into c, adm from public.center_staff s where s.user_id = new.trainer_id
      order by (s.role = 'admin') desc, s.created_at limit 1;
    if c is not null then
      insert into public.center_members (center_id, member_id) values (c, new.id) on conflict do nothing;
      if not adm then insert into public.member_trainers (member_id, trainer_id, center_id) values (new.id, new.trainer_id, c) on conflict do nothing; end if;
    end if;
  end if;
  return new;
end $$;
drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated using (
  user_id = auth.uid() or public.can_access_member(id)
  or (user_id is null and trainer_id = auth.uid() and not exists (select 1 from public.center_members cm where cm.member_id = members.id)));
drop policy if exists members_insert on public.members;
create policy members_insert on public.members for insert to authenticated with check (
  (user_id = auth.uid() and trainer_id is null)
  or (user_id is null and trainer_id = auth.uid() and public.is_trainer()));
-- 지우기: 계정 연결 안 된 회원은 그 회원이 있는 센터(하나뿐)의 관리자 / 혼자 쓰는 회원은 본인
drop policy if exists members_delete on public.members;
create policy members_delete on public.members for delete to authenticated using (
  (user_id = auth.uid() and not exists (select 1 from public.center_members cm where cm.member_id = members.id))
  or (user_id is null and exists (select 1 from public.center_members cm where cm.member_id = members.id and public.is_center_admin(cm.center_id))
      and not exists (select 1 from public.center_members cm where cm.member_id = members.id and not public.is_center_admin(cm.center_id)))
  or (user_id is null and trainer_id = auth.uid() and not exists (select 1 from public.center_members cm where cm.member_id = members.id)));
-- 강사 메모(data.memo): 센터와 연결된 회원은 본인이 바꿀 수 없음
create or replace function public.keep_staff_memo() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id = auth.uid() and exists (select 1 from public.center_members cm where cm.member_id = new.id) then
    new.data := jsonb_set(coalesce(new.data, '{}'::jsonb), '{memo}', coalesce(old.data -> 'memo', '""'::jsonb));
  end if;
  return new;
end $$;

-- 회원이 센터 초대 코드로 연결. 이미 내 기록이 있으면 센터가 만들어 둔 기록을 내 기록으로 합침 (여러 센터 연결 가능)
create or replace function public.claim_member(code text) returns text
language plpgsql security definer set search_path = public as $$
declare rec public.members; own text;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into rec from public.members where invite_code = upper(trim(code));
  if rec.id is null then raise exception 'invalid_code'; end if;
  if rec.user_id = auth.uid() then raise exception 'already_linked'; end if;
  if rec.user_id is not null then raise exception 'invalid_code'; end if;
  select id into own from public.members where user_id = auth.uid();
  if own is null then
    update public.members set user_id = auth.uid(), updated_at = now() where id = rec.id;
    return rec.id;
  end if;
  insert into public.center_members (center_id, member_id, created_at) select center_id, own, created_at from public.center_members where member_id = rec.id on conflict do nothing;
  insert into public.member_trainers (member_id, trainer_id, center_id, created_at) select own, trainer_id, center_id, created_at from public.member_trainers where member_id = rec.id on conflict do nothing;
  perform set_config('app.merge', '1', true);
  update public.sessions set member_id = own where member_id = rec.id;
  update public.measurements set member_id = own where member_id = rec.id;
  perform set_config('app.merge', '', true);
  update public.member_aliases set member_id = own where member_id = rec.id;
  insert into public.member_aliases (old_id, member_id) values (rec.id, own) on conflict (old_id) do update set member_id = excluded.member_id;
  -- 강사 메모는 비어 있을 때만 가져옴
  update public.members set data = case when coalesce(data->>'memo', '') = '' and coalesce(rec.data->>'memo', '') <> '' then jsonb_set(data, '{memo}', rec.data->'memo') else data end, updated_at = now() where id = own;
  delete from public.members where id = rec.id;
  return own;
end $$;

-- 센터 연결 해제: 회원 본인 또는 그 센터 관리자. 그 센터의 배정도 모두 풀림. 계정 없는 회원이 마지막 센터에서 빠지면 기록째 지움
create or replace function public.leave_center(mid text, c uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_member_owner(mid) or public.is_center_admin(c)) then raise exception 'not_allowed'; end if;
  delete from public.member_trainers where member_id = mid and center_id = c;
  delete from public.center_members where member_id = mid and center_id = c;
  update public.members set trainer_id = null
    where id = mid and trainer_id is not null and not exists (select 1 from public.center_staff s join public.center_members cm on cm.center_id = s.center_id where s.user_id = members.trainer_id and cm.member_id = mid);
  delete from public.members m where m.id = mid and m.user_id is null and not exists (select 1 from public.center_members cm where cm.member_id = mid);
end $$;
revoke all on function public.leave_center(text, uuid) from public, anon;
grant execute on function public.leave_center(text, uuid) to authenticated;
-- 앱 연결 끊기(계정과 기록 분리)는 더 이상 쓰지 않음: 센터 연결 해제로 대신
create or replace function public.unlink_member(mid text) returns void
language plpgsql security definer set search_path = public as $$
begin raise exception 'not_allowed'; end $$;

-- 관리자: 자기 센터 회원에게 자기 센터 강사 배정 / 해제
create or replace function public.assign_trainer(mid text, tid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c uuid;
begin
  select cm.center_id into c from public.center_members cm
    join public.center_staff s on s.center_id = cm.center_id and s.user_id = tid
    where cm.member_id = mid and public.is_center_admin(cm.center_id) order by cm.created_at limit 1;
  if c is null then raise exception 'not_allowed'; end if;
  insert into public.member_trainers (member_id, trainer_id, center_id) values (mid, tid, c)
    on conflict (member_id, trainer_id) do update set center_id = excluded.center_id;
end $$;
create or replace function public.unassign_trainer(mid text, tid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.member_trainers t where t.member_id = mid and t.trainer_id = tid and public.is_center_admin(t.center_id)) then raise exception 'not_allowed'; end if;
  delete from public.member_trainers where member_id = mid and trainer_id = tid;
  update public.members set trainer_id = null where id = mid and trainer_id = tid;
end $$;
create or replace function public.regen_signup_code(kind text) returns text
language plpgsql security definer set search_path = public as $$
declare c text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)); cid uuid;
begin
  select center_id into cid from public.center_staff where user_id = auth.uid() and role = 'admin' order by created_at limit 1;
  if cid is null then raise exception 'not_allowed'; end if;
  if kind = 'admin' then update public.centers set admin_code = c where id = cid;
  elsif kind = 'trainer' then update public.centers set trainer_code = c where id = cid;
  else raise exception 'bad_kind'; end if;
  return c;
end $$;
-- 강사 관리: 내 센터 강사의 이름·역할·연락처·메모. 해제하면 내 센터에서만 빠지고 그 센터 배정이 풀림
drop policy if exists staff_notes_select on public.staff_notes;
create policy staff_notes_select on public.staff_notes for select to authenticated using (
  exists (select 1 from public.center_staff s where s.user_id = staff_notes.trainer_id and public.is_center_admin(s.center_id)));
create or replace function public.save_staff(tid uuid, nm text, rl text, ph text, mm text) returns void
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  select s.center_id into cid from public.center_staff s where s.user_id = tid and public.is_center_admin(s.center_id) order by s.created_at limit 1;
  if cid is null then raise exception 'not_allowed'; end if;
  if rl not in ('admin', 'trainer', 'member') then raise exception 'bad_role'; end if;
  if tid = auth.uid() and rl <> 'admin' then raise exception 'self_role'; end if;
  update public.profiles set display_name = left(coalesce(nullif(trim(nm), ''), display_name), 40) where id = tid;
  if rl = 'member' then
    delete from public.member_trainers where trainer_id = tid and center_id = cid;
    delete from public.center_staff where user_id = tid and center_id = cid;
  else
    update public.center_staff set role = rl where user_id = tid and center_id = cid;
    insert into public.staff_notes (trainer_id, phone, memo) values (tid, left(coalesce(ph, ''), 30), left(coalesce(mm, ''), 2000))
      on conflict (trainer_id) do update set phone = excluded.phone, memo = excluded.memo, updated_at = now();
  end if;
  update public.profiles set role = case when exists (select 1 from public.center_staff where user_id = tid and role = 'admin') then 'admin'
    when exists (select 1 from public.center_staff where user_id = tid) then 'trainer' else 'member' end where id = tid;
end $$;

-- ── 기록(세션·인바디): 쓴 센터·쓴 사람·쓴 시각은 서버가 정하고 바꿀 수 없음 ──
create or replace function public.record_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.created_by := auth.uid();
      new.created_at := now();
      new.center_id := case when public.is_member_owner(new.member_id) then null else public.staff_center_for(new.member_id) end;
      new.is_public := true;
    end if;
  else
    if coalesce(current_setting('app.merge', true), '') <> '1' then new.member_id := old.member_id; end if;
    new.created_by := old.created_by; new.created_at := old.created_at; new.center_id := old.center_id;
    if coalesce(current_setting('app.set_public', true), '') <> '1' then new.is_public := old.is_public; end if;
  end if;
  return new;
end $$;
drop trigger if exists sessions_stamp on public.sessions;
create trigger sessions_stamp before insert or update on public.sessions for each row execute function public.record_stamp();
drop trigger if exists measurements_stamp on public.measurements;
create trigger measurements_stamp before insert or update on public.measurements for each row execute function public.record_stamp();

drop policy if exists sessions_select on public.sessions;
create policy sessions_select on public.sessions for select to authenticated using (public.can_see_record(member_id, center_id, is_public));
drop policy if exists sessions_insert on public.sessions;
create policy sessions_insert on public.sessions for insert to authenticated with check (
  (center_id is null and created_by = auth.uid() and public.is_member_owner(member_id) and coalesce(cardinality(trainer_ids), 0) = 0)
  or (center_id is not null and created_by = auth.uid() and public.staff_access(member_id, center_id)));
drop policy if exists sessions_update on public.sessions;
create policy sessions_update on public.sessions for update to authenticated
  using (public.can_edit_record(member_id, center_id, created_by, created_at))
  with check (public.can_edit_record(member_id, center_id, created_by, created_at) and (center_id is not null or coalesce(cardinality(trainer_ids), 0) = 0));
drop policy if exists sessions_delete on public.sessions;
create policy sessions_delete on public.sessions for delete to authenticated using (public.can_edit_record(member_id, center_id, created_by, created_at));

drop policy if exists measurements_all on public.measurements;
drop policy if exists measurements_select on public.measurements;
create policy measurements_select on public.measurements for select to authenticated using (public.can_see_record(member_id, center_id, is_public));
drop policy if exists measurements_insert on public.measurements;
create policy measurements_insert on public.measurements for insert to authenticated with check (
  (center_id is null and created_by = auth.uid() and public.is_member_owner(member_id))
  or (center_id is not null and created_by = auth.uid() and public.staff_access(member_id, center_id)));
drop policy if exists measurements_update on public.measurements;
create policy measurements_update on public.measurements for update to authenticated
  using (public.can_edit_record(member_id, center_id, created_by, created_at)) with check (public.can_edit_record(member_id, center_id, created_by, created_at));
drop policy if exists measurements_delete on public.measurements;
create policy measurements_delete on public.measurements for delete to authenticated using (public.can_edit_record(member_id, center_id, created_by, created_at));

-- 회원 본인: 기록 공개/비공개 (그 기록을 쓴 센터에는 항상 보임)
create or replace function public.set_record_public(kind text, rid text, pub boolean) returns void
language plpgsql security definer set search_path = public as $$
declare mid text;
begin
  if kind = 'session' then select member_id into mid from public.sessions where id = rid;
  elsif kind = 'measurement' then select member_id into mid from public.measurements where id = rid;
  else raise exception 'bad_kind'; end if;
  if mid is null or not public.is_member_owner(mid) then raise exception 'not_allowed'; end if;
  perform set_config('app.set_public', '1', true);
  if kind = 'session' then update public.sessions set is_public = pub where id = rid;
  else update public.measurements set is_public = pub where id = rid; end if;
  perform set_config('app.set_public', '', true);
end $$;
-- 볼 수 있는 회원의 비공개 기록: 날짜만 (화면에 "비공개"로 표시)
create or replace function public.private_records() returns table (kind text, id text, member_id text, date date, center_name text)
language sql stable security definer set search_path = public as $$
  select 'session', s.id, s.member_id, s.date, coalesce(c.name, '')
    from public.sessions s left join public.centers c on c.id = s.center_id
    where public.can_access_member(s.member_id) and not public.can_see_record(s.member_id, s.center_id, s.is_public)
  union all
  select 'measurement', x.id, x.member_id, x.date, coalesce(c.name, '')
    from public.measurements x left join public.centers c on c.id = x.center_id
    where public.can_access_member(x.member_id) and not public.can_see_record(x.member_id, x.center_id, x.is_public);
$$;
revoke all on function public.set_record_public(text, text, boolean), public.private_records(), public.my_center_codes() from public, anon;
grant execute on function public.set_record_public(text, text, boolean), public.private_records(), public.my_center_codes() to authenticated;

-- ── 운동 목록: 누구나 추가, 고치기·지우기는 추가한 사람만, 연결된 사람끼리 공유 (기본 운동은 모두에게, 고칠 수 없음) ──
create or replace function public.exercise_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then if auth.uid() is not null then new.created_by := auth.uid(); end if;
  else new.created_by := old.created_by; end if;
  return new;
end $$;
drop trigger if exists exercises_stamp on public.exercises;
create trigger exercises_stamp before insert or update on public.exercises for each row execute function public.exercise_stamp();
drop policy if exists exercises_select on public.exercises;
create policy exercises_select on public.exercises for select to authenticated using (created_by is null or public.connected(auth.uid(), created_by));
drop policy if exists exercises_insert on public.exercises;
create policy exercises_insert on public.exercises for insert to authenticated with check (created_by = auth.uid());
drop policy if exists exercises_update on public.exercises;
create policy exercises_update on public.exercises for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());
drop policy if exists exercises_delete on public.exercises;
create policy exercises_delete on public.exercises for delete to authenticated using (created_by = auth.uid());
drop policy if exists exercise_media_insert on storage.objects;
create policy exercise_media_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib'
  and not exists (select 1 from public.exercises e where e.id = (storage.foldername(name))[2] and e.created_by is distinct from auth.uid()));
drop policy if exists exercise_media_delete on storage.objects;
create policy exercise_media_delete on storage.objects for delete to authenticated using (
  bucket_id = 'session-media' and (storage.foldername(name))[1] = 'lib'
  and not exists (select 1 from public.exercises e where e.id = (storage.foldername(name))[2] and e.created_by is distinct from auth.uid()));
