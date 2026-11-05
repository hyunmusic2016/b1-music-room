-- 로컬 시험: 마이그레이션 001~004를 적용한 빈 DB에서 실행합니다(Supabase에서는 실행하지 않음).
-- 하나라도 틀리면 그 자리에서 멈춥니다(ON_ERROR_STOP). 마지막에 "모든 시험 통과"가 나오면 성공입니다.
\set ON_ERROR_STOP 1
\set QUIET 1
create schema test;
create function test.ok(c boolean, label text) returns void language plpgsql as $$
begin
  if c is distinct from true then raise exception '실패: %', label; end if;
  raise notice '통과: %', label;
end $$;
-- 권한 거부를 확인하는 도우미: sql을 실행했을 때 권한 오류가 나야 통과
create function test.denied(sql text, label text) returns void language plpgsql as $$
begin
  begin execute sql;
  exception when insufficient_privilege then raise notice '통과(거부됨): %', label; return; end;
  raise exception '실패(거부되지 않음): %', label;
end $$;
grant usage on schema test to anon, authenticated;
grant execute on all functions in schema test to anon, authenticated;

-- 시험 시각: 2026-10-27(화) 14:28 서울
set app.fake_now = '2026-10-27 14:28:00';
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000a', 'admin@test'),
                                          ('00000000-0000-0000-0000-00000000000b', 'other@test');
insert into public.admins (user_id) values ('00000000-0000-0000-0000-00000000000a');

-- ===== 1. 익명(anon) 접근 차단 =====
set role anon;
select test.denied('select * from public.reservations', '익명은 예약 표를 직접 읽을 수 없음');
select test.denied('select * from public.users', '익명은 이용자 표를 직접 읽을 수 없음');
select test.denied($$insert into public.reservations (date,hour,name,pw_hash) values ('2026-10-27',20,'x','x')$$, '익명은 예약 표에 직접 쓸 수 없음');
select test.denied($$select public.hash_pw('1111')$$, '익명은 내부 도우미 함수를 부를 수 없음');
select test.denied($$select public.admin_users()$$, '익명은 관리자 함수를 부를 수 없음');
select test.denied($$select public.cleanup_old()$$, '익명은 정리 함수를 부를 수 없음');

-- ===== 2. 예약 현황 =====
select test.ok(jsonb_array_length(public.public_board()->'slots') = 48, '현황은 오늘·내일 48칸');
select test.ok((select bool_and((s->>'past')::boolean) from jsonb_array_elements(public.public_board()->'slots') s
                 where s->>'date' = '2026-10-27' and (s->>'hour')::int < 14), '오늘 14시 전 칸은 지남');
select test.ok((select not (s->>'past')::boolean from jsonb_array_elements(public.public_board()->'slots') s
                 where s->>'date' = '2026-10-27' and (s->>'hour')::int = 14), '14:28에도 14시 칸은 열려 있음');

-- ===== 3. 재원생 예약 규칙 =====
select test.ok((public.reserve('2026-10-27', 14, '홍 길동', '1111', true, 'stu'))->>'ok' = 'true', '재원생 예약 성공(이름 공백 제거)');
select test.ok((select s->>'masked' = '홍*동' and not (s ? 'name') from jsonb_array_elements(public.public_board()->'slots') s
                 where s->>'date' = '2026-10-27' and (s->>'hour')::int = 14), '현황에는 가린 이름만(홍*동), 원본 이름 없음');
select test.ok(position('1111' in public.public_board()::text) = 0 and position('홍길동' in public.public_board()::text) = 0,
               '현황 응답 어디에도 원본 이름·비밀번호 없음');
select test.ok((public.reserve('2026-10-27', 16, '홍길동', '2222', true, 'stu'))->>'msg' like '하루에 한 번만%', '재원생 하루 1회 제한(이름 기준)');
select test.ok((public.reserve('2026-10-28', 16, '홍길동', '1111', true, 'stu'))->>'ok' = 'true', '내일은 다시 예약 가능');
select test.ok((public.reserve('2026-10-27', 14, '이서연', '2222', true, 'stu'))->>'msg' like '다른 분이 방금%', '이미 예약된 시간은 막힘');
select test.ok((public.reserve('2026-10-27', 13, '이서연', '2222', true, 'stu'))->>'msg' like '이미 지난 시간%', '지난 시간은 막힘');
select test.ok((public.reserve('2026-10-29', 13, '이서연', '2222', true, 'stu'))->>'msg' like '오늘과 내일만%', '모레는 막힘');
select test.ok((public.reserve('2026-10-27', 15, '이서연', '2222', false, 'stu'))->>'msg' like '개인정보%', '동의하지 않으면 막힘');
select test.ok((public.reserve('2026-10-27', 15, '이1', '2222', true, 'stu'))->>'msg' like '본명을%', '이름 형식 확인');
select test.ok((public.reserve('2026-10-27', 15, '이서연', '22a2', true, 'stu'))->>'msg' like '비밀번호는%', '비밀번호 4자리 확인');
select test.ok((public.reserve('2026-10-27', 23, '이서연', '2222', true, 'stu'))->>'ok' = 'true', '23시 칸 예약 가능');

-- ===== 4. 외부 이용자: 미등록은 막힘, 5회 실패 시 잠금 =====
select test.ok((public.reserve('2026-10-27', 18, '박미등', '1234', true, 'ext'))->>'msg' like '등록된 일반회원%', '미등록 외부 이용자는 막힘');
select public.reserve('2026-10-27', 18, '박미등', '1234', true, 'ext') from generate_series(1, 4);
select test.ok((public.reserve('2026-10-27', 18, '박미등', '1234', true, 'ext'))->>'msg' like '시도 횟수를 초과%', '5회 실패 후 잠금');

-- ===== 5. 관리자 인증 =====
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
set role authenticated;
select test.ok((public.admin_users())->>'msg' = '관리자 로그인이 필요합니다.', '관리자가 아닌 로그인 계정은 거절');
select test.denied('select * from public.users', '로그인 계정도 표는 직접 못 읽음');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_users())->>'ok' = 'true', '관리자는 이용자 목록 조회 가능');
select test.denied('select * from public.users', '관리자도 표는 직접 못 읽음(함수로만)');

-- ===== 6. 이용자 등록 + 횟수권 =====
select test.ok((public.admin_create_user('{"type":"ext","name":"김외부","pw":"0000","phone":"01000000000","part":"드럼","memo":"",
  "prod":{"kind":"count","start":"2026-10-27","days":30,"total":2}}'))->>'ok' = 'true', '외부 이용자 + 횟수권(총 2회) 등록');
select test.ok((public.admin_create_user('{"type":"ext","name":"김외부","pw":"0000","phone":"01000000000"}'))->>'msg' like '같은 이름과 비밀번호%', '같은 이름+비밀번호 중복 등록 막힘');
select test.ok((public.admin_create_user('{"type":"ext","name":"김외부","pw":"9999","phone":"0123"}'))->>'msg' like '전화번호%', '전화번호 형식 확인');
select test.ok((public.admin_create_user('{"type":"stu","name":"김재원","pw":"1234","phone":"01011112222","prod":{"kind":"count","start":"2026-10-27","days":30,"total":0}}'))->>'msg' like '총 이용 횟수를%', '상품 값이 틀리면 막힘(030부터 재원생 횟수권은 가능)');
select test.ok(not exists (select 1 from jsonb_array_elements((public.admin_users())->'users') u where u->>'name' = '김재원'), '상품이 막히면 이용자도 저장 안 됨');
select test.ok(((public.admin_users())->'users'->0->'current'->>'end') = '2026-11-25', '30일 = 시작일 + 29일');
reset role;
select id as ext_uid from public.users where name = '김외부' \gset
select id as ext_pid from public.products where user_id = :ext_uid \gset

set role anon;
select test.ok((public.product_info('ext', '김외부', '1111'))->'product' = 'null'::jsonb, '비밀번호가 틀리면 상품 정보 없음');
select test.ok((public.product_info('ext', '김외부', '0000'))->'product'->>'kind' = 'count', '이름+비밀번호가 맞으면 상품 정보');
select test.ok((public.product_info('ext', '김외부', '0000'))->'product'->>'target' = 'ext', '상품 정보에 대상 구분(ext) 포함');
select (public.reserve('2026-10-27', 17, '김외부', '0000', true, 'ext'))->>'id' as e1 \gset
select test.ok(:e1 > 0, '횟수권으로 예약 1');
select test.ok((public.reserve('2026-10-27', 19, '김외부', '0000', true, 'ext'))->>'prod' = 'count', '외부 이용자는 하루 제한 없음(같은 날 2번째)');
select test.ok((public.reserve('2026-10-28', 10, '김외부', '0000', true, 'ext'))->>'msg' like '횟수권 2회를 모두%', '횟수권 횟수 다 쓰면 막힘');
select test.ok((public.cancel_own(:e1, '김외부', '1111'))->>'msg' = '본인의 예약이 아닙니다.', '비밀번호 틀리면 취소 불가');
select test.ok((public.cancel_own(:e1, '김외부', '0000'))->>'ok' = 'true', '본인 취소');
select test.ok((public.my_reservations('김외부', '0000'))->'product'->'left'->>'total' = '1', '취소하면 횟수권 횟수 돌려받음');
select test.ok((public.reserve('2026-10-28', 10, '김외부', '0000', true, 'ext'))->>'ok' = 'true', '돌려받은 횟수로 다시 예약');

-- ===== 7. 횟수권 충전 =====
reset role; set role authenticated;
select test.ok((public.admin_topup(:ext_pid, 5, 30))->'user'->'current'->>'total' = '7', '충전: 총 2 + 5 = 7회');
select test.ok((public.admin_topup(:ext_pid, 995, 30))->>'msg' like '총 이용 횟수는 999회%', '충전 후 999회 초과 막힘');
reset role;
select test.ok((select end_date = '2026-11-25' and total_count = 7 from public.products where id = :ext_pid), '충전 기간: 기존 종료일이 더 늦으면 유지');
select test.ok((select count(*) = 1 from public.product_topups where product_id = :ext_pid), '충전 기록 남음');

-- ===== 8. 재원생 정액권 =====
set role authenticated;
select test.ok((public.admin_create_user('{"type":"stu","name":"김정액","pw":"0000","phone":"010-0000-1111",
  "prod":{"kind":"flat","start":"2026-10-27","days":30,"limit":2}}'))->>'ok' = 'true', '재원생 + 정액권(하루 2회) 등록');
reset role; set role anon;
select (public.reserve('2026-10-27', 20, '김정액', '1111', true, 'stu')) as hm \gset
select test.ok((:'hm'::jsonb)->>'ok' = 'true' and (:'hm'::jsonb)->>'prod' is null, '정액권 재원생과 비밀번호가 다르면 동명이인 일반 재원생으로 예약(008)');
select test.ok((public.cancel_own(((:'hm'::jsonb)->>'id')::bigint, '김정액', '1111'))->>'ok' = 'true', '동명이인 예약 취소');
select (public.reserve('2026-10-27', 20, '김정액', '0000', true, 'stu'))->>'id' as f1 \gset
select test.ok((public.reserve('2026-10-27', 21, '김정액', '0000', true, 'stu'))->>'prod' = 'flat', '정액권은 하루 N회(2번째)');
select test.ok((public.reserve('2026-10-27', 22, '김정액', '0000', true, 'stu'))->>'msg' like '정액권 하루 이용 횟수(2회)%', '정액권 하루 횟수 초과 막힘');
select test.ok((public.reserve('2026-10-28', 20, '김정액', '0000', true, 'stu'))->>'ok' = 'true', '정액권 다음 날 다시 채워짐');
select test.ok((public.reserve('2026-10-28', 21, '김정액', '0000', true, 'stu'))->>'ok' = 'true', '정액권 다음 날 2번째');
select test.ok(jsonb_array_length((public.my_reservations('김정액', '0000'))->'list') = 4, '내 예약 조회: 4건');
select test.ok((public.my_reservations('김정액', '0000'))->'product'->'left'->>'today' = '0', '내 예약: 오늘 남은 횟수 0');
select test.ok((public.my_reservations('김정액', '9999'))->>'ok' = 'false', '비밀번호 틀리면 조회 안 됨');

-- ===== 9. 시간 변경 =====
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-28', 22))->>'msg' like '정액권 하루 이용 횟수(2회)를 초과%', '정액권: 옮길 날짜 하루 횟수 확인');
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-27', 22))->>'ok' = 'true', '시간 변경 성공');
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-27', 23))->>'msg' like '다른 분이 방금%', '이미 예약된 시간으로 변경 불가');
reset role;
set app.fake_now = '2026-10-27 22:10:00';
set role anon;
select test.ok((public.cancel_own(:f1, '김정액', '0000'))->>'msg' like '시작된 예약은%', '시작된 예약은 본인 취소 불가');
select test.ok((public.move_own(:f1, '김정액', '0000', '2026-10-28', 5))->>'msg' like '시작된 예약은%', '시작된 예약은 본인 변경 불가');
reset role;
set app.fake_now = '2026-10-27 14:30:00';

-- ===== 10. 이용자 수정(이름·비밀번호 변경이 예약에도 반영) =====
select id as stu_uid from public.users where name = '김정액' \gset
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :stu_uid, 'type', 'stu', 'name', '김정새', 'pw', '5555',
  'phone', '01000001111', 'part', '드럼', 'memo', '')))->>'ok' = 'true', '이용자 이름·비밀번호 수정');
reset role; set role anon;
select test.ok((public.my_reservations('김정새', '5555'))->>'ok' = 'true' and jsonb_array_length((public.my_reservations('김정새', '5555'))->'list') = 4,
               '새 이름·비밀번호로 예약 조회');
select test.ok((public.my_reservations('김정액', '0000'))->>'ok' = 'false', '옛 이름·비밀번호로는 조회 안 됨');
reset role; set role authenticated;
begin;
select test.ok((public.admin_update_user(jsonb_build_object('id', :ext_uid, 'type', 'stu', 'name', '김외부',
  'phone', '01000000000')))->'user'->>'type' = 'stu', '030: 횟수권 사용 중인 일반회원도 재원생으로 변경 가능(시험 뒤 되돌림)');
rollback;
select test.ok((public.admin_update_user(jsonb_build_object('id', :stu_uid, 'type', 'stu', 'name', '김정새',
  'phone', '01000001111', 'edit_prod', jsonb_build_object('start', '2026-10-27', 'days', 45, 'limit', 3))))->'user'->'current'->>'end' = '2026-12-10',
  '정액권 기간·횟수 수정(45일)');

-- ===== 11. 관리자 예약(일반예약 / 슈퍼패스, 비밀번호 없음)·취소 (007) =====
select test.ok((public.admin_reserve('2026-10-27', 15, '남궁민수', null, true, true))->>'ok' = 'true', '슈퍼패스: 미등록 외부 이용자도 예약');
select (public.admin_reservations())->'list' @> '[{"name":"남궁민수","super":true}]' as sp \gset
select test.ok(:'sp', '관리자 목록에 슈퍼패스 표시');
select test.ok((public.admin_reserve('2026-10-27', 15, '남궁민수', null, false, true))->>'msg' like '다른 분이 방금%', '슈퍼패스도 중복은 막힘');
select test.ok((public.admin_reserve('2026-10-27', 10, '남궁민수', null, false, true))->>'msg' like '이미 지난 시간%', '슈퍼패스도 지난 시간은 막힘');
select test.ok((public.admin_reserve('2026-10-27', 16, '남궁민수', null, true, false))->>'msg' like '등록되지 않은 일반회원%', '일반예약: 미등록 외부 이용자 막힘');
select test.ok((public.admin_reserve('2026-10-27', 16, '박재원', null, false, false))->>'ok' = 'true', '일반예약: 미등록 재원생 1회');
select test.ok((public.admin_reserve('2026-10-27', 18, '박재원', null, false, false))->>'msg' like '재원생은 하루에 한 번만%', '일반예약: 재원생 2회째 막힘');
select test.ok((public.admin_reserve('2026-10-27', 18, '박재원', null, false, true))->>'ok' = 'true', '슈퍼패스: 재원생 2회째도 예약');
select test.ok((public.admin_reserve('2026-10-27', 17, '김정새', :ext_uid, false, false))->>'msg' like '선택한 이용자를 찾을 수 없습니다%', '이름과 다른 이용자 번호는 거절');
select test.ok((public.admin_find_users('김정새', '2026-10-27'))->'users'->0->'product'->>'kind' = 'flat', '이름으로 이용자·정액권 찾기');
select test.ok((public.admin_find_users('박재원', '2026-10-27'))->>'day_taken' = 'true' and jsonb_array_length((public.admin_find_users('박재원', '2026-10-27'))->'users') = 0, '미등록 이름: 이용자 없음, 그날 예약 수');
select (public.admin_reserve('2026-10-27', 17, '김정새', :stu_uid, false, false))->>'id' as af1 \gset
reset role;
select test.ok((select product_kind = 'flat' and pw_hash is not null and user_id = :stu_uid from public.reservations where id = :af1), '일반예약: 정액권 차감 + 등록 비밀번호 연결');
set role authenticated;
select test.ok((public.admin_reserve('2026-10-27', 20, '김정새', :stu_uid, false, false))->>'msg' like '정액권 하루 이용 횟수(3회)%', '일반예약: 정액권 하루 횟수 다 쓰면 막힘');
select test.ok((public.admin_reserve('2026-10-27', 20, '김정새', :stu_uid, false, true))->>'prod' is null, '슈퍼패스: 정액권 차감 없이 예약');
select test.ok((public.admin_reserve('2026-10-28', 13, '김외부', :ext_uid, false, false))->>'prod' = 'count', '일반예약: 횟수권 차감(구분은 등록 정보를 따름)');
select test.ok((public.admin_user(:ext_uid))->'user'->'current'->'left'->>'total' = '4', '횟수권 남은 횟수 7-3 = 4');
select test.ok((public.admin_reserve('2026-10-28', 14, '김외부', :ext_uid, false, true))->>'prod' is null
           and (public.admin_user(:ext_uid))->'user'->'current'->'left'->>'total' = '4', '슈퍼패스: 횟수권 차감 없음');
reset role; set role anon;
select test.ok((public.my_reservations('김외부', '0000'))->'list' @> '[{"date":"2026-10-28","hour":13}]', '등록 이용자의 관리자 예약은 내 예약에서 보임');
reset role;
select (select id from public.reservations where name = '박재원' and hour = 16) as pj \gset
set role anon;
select test.ok((public.cancel_own(:pj, '박재원', '0000'))->>'msg' = '본인의 예약이 아닙니다.', '비밀번호 없는 예약은 아무 비밀번호로도 취소 불가');
select test.ok((public.my_reservations('박재원', '0000'))->>'ok' = 'false', '비밀번호 없는 예약은 내 예약에 안 보임');
reset role; set role authenticated;
select test.ok((public.admin_cancel(:af1, '시험'))->>'ok' = 'true', '관리자 예약 취소');
select test.ok((public.admin_cancel(:e1, '중복'))->>'ok' = 'false', '이미 취소된 예약은 다시 취소 안 됨');

-- ===== 11-2. 동명이인 재원생 하루 1회 (008) =====
select test.ok((public.admin_create_user('{"type":"ext","name":"이강현","pw":"1111","phone":"01011110000",
  "prod":{"kind":"count","start":"2026-10-27","days":30,"total":5}}'))->>'ok' = 'true', '횟수권 이용자 이강현 등록');
reset role; set role anon;
select test.ok((public.reserve('2026-10-28', 1, '이강현', '1111', true, 'ext'))->>'prod' = 'count', '횟수권 이강현 예약');
select test.ok((public.reserve('2026-10-28', 2, '이강현', '2222', true, 'stu'))->>'ok' = 'true', '재원생 이강현은 등록 이용자 이강현의 예약과 관계없이 예약(008)');
select test.ok((public.reserve('2026-10-28', 3, '이강현', '3333', true, 'stu'))->>'msg' like '하루에 한 번만%', '미등록 재원생은 같은 이름끼리 하루 1회(비밀번호 바꿔도 막힘)');
select test.ok((public.reserve('2026-10-28', 3, '김정새', '9999', true, 'stu'))->>'ok' = 'true', '정액권 재원생 김정새와 동명이인 재원생도 예약(008)');
select test.ok((public.reserve('2026-10-28', 4, '김정새', '5555', true, 'stu'))->>'prod' = 'flat', '정액권 김정새는 그대로 정액권 예약');
reset role; set role authenticated;
select test.ok((public.admin_find_users('이강현', '2026-10-28'))->>'day_taken' = 'true'
           and (public.admin_find_users('이강현', '2026-10-28'))->'users'->0->>'day_taken' = 'false', '관리자 이름 찾기: 미등록 재원생 쪽만 예약 있음');
select test.ok((public.admin_reserve('2026-10-28', 5, '이강현', null, false, false))->>'msg' like '재원생은 하루에 한 번만%', '관리자 일반예약: 미등록 재원생 이강현 2회째 막힘');
select (public.admin_find_users('이강현', '2026-10-28'))->'users'->0->>'id' as lkh \gset
select test.ok((public.admin_reserve('2026-10-28', 5, '이강현', :lkh, false, false))->>'prod' = 'count', '관리자 일반예약: 횟수권 이강현은 따로 예약');
reset role; set role anon;
select (select (x->>'id')::bigint from jsonb_array_elements((public.my_reservations('이강현', '2222'))->'list') x) as sk \gset
select test.ok((public.move_own(:sk, '이강현', '2222', '2026-10-28', 6))->>'ok' = 'true', '동명이인 이용자 예약이 있어도 시간 변경 가능(008)');
reset role; set role authenticated;

-- ===== 11-2b. 내 예약의 이용자 구분 (012) =====
reset role; set role anon;
select test.ok((public.my_reservations('이강현', '1111'))->>'user_type' = 'ext', '등록 외부 이용자는 구분 ext');
select test.ok((public.my_reservations('이강현', '2222'))->'user_type' = 'null'::jsonb, '미등록 재원생은 구분 없음(null)');
reset role; set role authenticated;

-- ===== 11-3. 출입 비밀번호 (011) =====
reset role; set role anon;
select test.ok((public.my_codes('이강현', '2222'))->'codes'->>'gate' = '0000', '앞으로의 예약이 있으면 출입 비밀번호 받음');
select test.ok((public.my_codes('이강현', '9999'))->'codes' = 'null'::jsonb, '비밀번호가 틀리면 출입 비밀번호 없음');
select test.ok((public.my_codes('예약없음', '1111'))->'codes' = 'null'::jsonb, '앞으로의 예약이 없으면 출입 비밀번호 없음');
select test.denied($$select public.door_codes()$$, '익명은 출입 비밀번호 내부 함수를 부를 수 없음');
select test.denied($$select public.admin_door_codes()$$, '익명은 관리자 출입 비밀번호 보기 불가');
select test.denied($$select public.admin_set_door_codes('{}')$$, '익명은 출입 비밀번호 변경 불가');
reset role; set role authenticated;
select test.ok((public.admin_set_door_codes('{"gate":"1234","room":"","toilet":"9"}'))->>'msg' like '연습실 비밀번호를%', '빈 비밀번호는 저장 안 됨');
select test.ok((public.admin_set_door_codes('{"gate":" 1234 ","room":"5678*","toilet":"9012#"}'))->'codes'->>'gate' = '1234', '관리자 출입 비밀번호 변경(앞뒤 공백 제거)');
select test.ok((public.admin_door_codes())->'codes'->>'toilet' = '9012#', '관리자 출입 비밀번호 보기');
reset role; set role anon;
select test.ok((public.my_codes('이강현', '2222'))->'codes'->>'room' = '5678*', '바뀐 출입 비밀번호가 바로 보임');
reset role; set role authenticated;

-- ===== 12. 이용 불가 설정 =====
select test.ok((public.admin_block('2026-10-28', 9, '2026-10-28', 12, '점검', false))->>'need_confirm' = 'true', '이용 불가 기간에 예약 있으면 확인 요청');
select test.ok((public.admin_block('2026-10-28', 9, '2026-10-28', 12, '점검', true))->>'slots' = '3', '확인하면 3칸 설정');
reset role;
select test.ok((select status = 'cancelled' and cancel_reason = '관리자 취소: 이용 불가 (점검)' from public.reservations where date = '2026-10-28' and hour = 10),
               '걸린 예약은 사유와 함께 취소');
set role anon;
select test.ok((public.reserve('2026-10-28', 11, '최민준', '4444', true, 'stu'))->>'msg' = '이용할 수 없는 시간입니다.', '이용 불가 시간은 예약 막힘');
reset role; set role authenticated;
select (public.admin_blocks())->'list'->0->>'group_id' as gid \gset
select test.ok((public.admin_unblock(:'gid'))->>'ok' = 'true', '이용 불가 해제');

-- ===== 13. 사용만료 =====
select test.ok((public.admin_set_status(:ext_uid, 'expired'))->'user'->>'status' = 'expired', '사용만료 처리');
reset role;
select test.ok(not exists (select 1 from public.products where id = :ext_pid), '사용만료: 오늘 시작한 횟수권은 삭제');
set role anon;
select test.ok((public.reserve('2026-10-28', 13, '김외부', '0000', true, 'ext'))->>'msg' like '등록된 일반회원%', '사용만료된 외부 이용자는 예약 불가');
reset role; set role authenticated;
select test.ok((public.admin_set_status(:ext_uid, 'blacklisted'))->'user'->>'status' = 'blacklisted', '블랙리스트 등록(015, 사용만료 상태에서도 가능)');
select test.ok((public.admin_set_status(:ext_uid, 'active'))->'user'->>'status' = 'active', '다시 사용');

-- ===== 14. 30일 뒤 정리 (009) =====
reset role;
set app.fake_now = '2026-12-20 12:00:00';
select test.ok(public.keep_from() = '2026-11-20', '보관 기간 30일(오늘 - 30일)');
select test.ok((public.cleanup_old())->>'ok' = 'true', '정리 함수 실행');
select test.ok(not exists (select 1 from public.reservations r where date < '2026-11-20' and not exists
                 (select 1 from public.products q where q.id = r.product_id and q.end_date >= '2026-11-20')), '30일 지난 예약 삭제');
select test.ok(exists (select 1 from public.reservations r join public.products q on q.id = r.product_id
                 where r.date < '2026-11-20' and q.end_date >= '2026-11-20'), '아직 끝나지 않은 상품의 예약은 남김(사용 횟수 보존)');
select test.ok(not exists (select 1 from public.products where end_date < '2026-11-20'), '30일 지난 상품 삭제');

select test.ok((public.cleanup_status())->>'pg_cron' = 'false', '정리 상태 확인 함수(로컬은 pg_cron 없음)');
set role anon;
select test.denied($$select public.cleanup_status()$$, '익명은 정리 상태 함수를 부를 수 없음');
reset role;

-- ===== 15. 상품 기간이 끝나면 이용자 현황에서 '일반'으로 (2026-10-30 확인) =====
-- 이용자 현황 화면은 admin_users의 current(종료일이 오늘 이후인 상품)가 있으면 그 칸, 없으면 '일반'에 둡니다.
set app.fake_now = '2026-12-20 12:00:00';
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_create_user('{"type":"ext","name":"만료외부","pw":"1212","phone":"01012121212",
  "prod":{"kind":"count","start":"2026-12-20","days":2,"total":5}}'))->>'ok' = 'true', '만료 시험: 외부 횟수권(12/20~12/21) 등록');
select test.ok((public.admin_create_user('{"type":"stu","name":"만료정액","pw":"3434","phone":"01034343434",
  "prod":{"kind":"flat","start":"2026-12-20","days":1,"limit":3}}'))->>'ok' = 'true', '만료 시험: 재원생 정액권(12/20 하루) 등록');
reset role;
select id as x_uid from public.users where name = '만료외부' \gset
select id as f_uid from public.users where name = '만료정액' \gset
set role authenticated;
select test.ok((public.admin_user(:x_uid))->'user'->'current'->>'kind' = 'count', '12/20: 만료외부는 횟수권 칸');
select test.ok((public.admin_user(:f_uid))->'user'->'current'->>'kind' = 'flat', '12/20: 만료정액은 정액권 칸');

reset role; set app.fake_now = '2026-12-21 09:00:00'; set role authenticated;
select test.ok((public.admin_user(:f_uid))->'user'->'current' = 'null'::jsonb, '12/21: 정액권 종료일(12/20) 다음 날 → current 없음(일반 칸)');
select test.ok((public.admin_user(:f_uid))->'user'->'last'->>'end' = '2026-12-20', '12/21: 만료된 정액권 기록(종료 12/20)은 남음');
select test.ok((public.admin_user(:x_uid))->'user'->'current'->>'kind' = 'count', '12/21: 횟수권은 종료일 당일까지 횟수권 칸');
select test.ok(exists (select 1 from jsonb_array_elements((public.admin_users())->'users') e
                 where (e->>'id')::bigint = :f_uid and e->'current' = 'null'::jsonb), '12/21: 이용자 목록(admin_users)에서도 정액권 없음');

reset role; set app.fake_now = '2026-12-22 09:00:00'; set role authenticated;
select test.ok((public.admin_user(:x_uid))->'user'->'current' = 'null'::jsonb, '12/22: 횟수권(남은 횟수 있어도) 종료일 지나면 current 없음(일반 칸)');
select test.ok((public.admin_user(:x_uid))->'user'->'last'->>'kind' = 'count', '12/22: 만료된 횟수권 기록은 남음');

-- 만료 뒤 예약 규칙: 외부 이용자는 상품 없는 일반(횟수 제한 없음), 재원생은 하루 1회
set role anon;
select test.ok((select r->>'ok' = 'true' and r->>'prod' is null from (select public.reserve('2026-12-22', 15, '만료외부', '1212', true, 'ext') r) x), '만료 뒤 외부: 상품 없이 예약됨');
select test.ok((public.reserve('2026-12-22', 16, '만료외부', '1212', true, 'ext'))->>'ok' = 'true', '만료 뒤 외부: 같은 날 2번째도 가능(제한 없음)');
select test.ok((select r->>'ok' = 'true' and r->>'prod' is null from (select public.reserve('2026-12-22', 17, '만료정액', '3434', true, 'stu') r) x), '만료 뒤 재원생: 정액권 없이 예약됨');
select test.ok((public.reserve('2026-12-22', 18, '만료정액', '3434', true, 'stu'))->>'msg' like '%하루에 한 번%', '만료 뒤 재원생: 하루 1회로 막힘');
reset role;

-- ===== 16. 만료된 상품과 기간이 겹쳐도 새 상품 추가·수정 가능 (013) =====
-- 지금 12/22: 만료외부의 횟수권(12/20~12/21)과 만료정액의 정액권(12/20)은 이미 끝남
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :x_uid, 'type', 'ext', 'name', '만료외부', 'phone', '01012121212',
  'new_prod', jsonb_build_object('kind', 'count', 'start', '2026-12-20', 'days', 5, 'total', 3))))->'user'->'current'->>'end' = '2026-12-24',
  '만료된 횟수권과 겹치는 시작일(12/20)로 새 횟수권 추가 가능');
select test.ok((public.admin_update_user(jsonb_build_object('id', :x_uid, 'type', 'ext', 'name', '만료외부', 'phone', '01012121212',
  'edit_prod', jsonb_build_object('start', '2026-12-19', 'days', 4, 'total', 3))))->'user'->'current'->>'end' = '2026-12-22',
  '사용 중 상품을 만료된 상품 기간까지 당겨 수정 가능');
select test.ok((public.admin_update_user(jsonb_build_object('id', :f_uid, 'type', 'stu', 'name', '만료정액', 'phone', '01034343434',
  'new_prod', jsonb_build_object('kind', 'flat', 'start', '2026-12-20', 'days', 4, 'limit', 2))))->>'ok' = 'true',
  '만료된 정액권과 겹치는 시작일로 새 정액권 추가 가능');
-- 아직 끝나지 않은 상품끼리 겹치는 것은 계속 막힘
reset role;
insert into public.products (user_id, kind, start_date, end_date, daily_limit) values (:f_uid, 'flat', '2026-12-26', '2026-12-27', 1);
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :f_uid, 'type', 'stu', 'name', '만료정액', 'phone', '01034343434',
  'edit_prod', jsonb_build_object('start', '2026-12-22', 'days', 3, 'limit', 1))))->>'msg' like '이 이용자의 다른 정액권과 기간이 겹칩니다%',
  '사용 중인 다른 상품과 겹치면 계속 막힘');
reset role;

-- ===== 17. 휴면 이용자(90일 이상 이용 없음, 014) =====
-- 지금 12/22. 마지막 이용일 = 확정 예약의 이용 날짜 중 가장 늦은 날(취소 제외), 없으면 등록일
set role authenticated;
select test.ok((public.admin_create_user('{"type":"ext","name":"휴면외부","pw":"5656","phone":"01056565656"}'))->>'ok' = 'true', '휴면 시험: 외부 이용자 등록');
select test.ok((public.admin_create_user('{"type":"ext","name":"휴면상품","pw":"7878","phone":"01078787878",
  "prod":{"kind":"count","start":"2026-12-22","days":30,"total":5}}'))->>'ok' = 'true', '휴면 시험: 횟수권 있는 외부 이용자 등록');
reset role;
select id as d_uid from public.users where name = '휴면외부' \gset
select id as dp_uid from public.users where name = '휴면상품' \gset
update public.users set created_at = '2026-09-23 12:00+09' where id = :d_uid;   -- 12/22 기준 90일 전
update public.users set created_at = '2026-09-01 12:00+09' where id = :dp_uid;
set role authenticated;
select test.ok((public.admin_user(:d_uid))->'user'->>'last_used' = '2026-09-23', '예약이 없으면 마지막 이용일 = 등록일');
select test.ok((public.admin_user(:d_uid))->'user'->>'dormant' = 'true', '마지막 이용일로부터 90일 → 휴면');
reset role; update public.users set created_at = '2026-09-24 12:00+09' where id = :d_uid; set role authenticated;
select test.ok((public.admin_user(:d_uid))->'user'->>'dormant' = 'false', '89일이면 아직 휴면 아님');
reset role; update public.users set created_at = '2026-09-01 12:00+09' where id = :d_uid; set role authenticated;
select test.ok((public.admin_user(:dp_uid))->'user'->>'dormant' = 'false', '사용 중인 횟수권이 있으면 오래돼도 휴면 아님');
select test.ok(exists (select 1 from jsonb_array_elements((public.admin_users())->'users') e
                 where (e->>'id')::bigint = :d_uid and e->>'dormant' = 'true'), '이용자 목록(admin_users)에도 휴면 표시');
-- 다시 예약하면 자동으로 휴면이 풀림
set role anon;
select (public.reserve('2026-12-23', 9, '휴면외부', '5656', true, 'ext'))->>'id' as d_rid \gset
reset role; set role authenticated;
select test.ok((public.admin_user(:d_uid))->'user'->>'dormant' = 'false', '휴면 이용자가 예약하면 바로 휴면 풀림');
select test.ok((public.admin_user(:d_uid))->'user'->>'last_used' = '2026-12-23', '마지막 이용일 = 예약한 이용 날짜');
-- 그 예약을 취소하면 이용으로 세지 않음
set role anon;
select test.ok((public.cancel_own(:d_rid, '휴면외부', '5656'))->>'ok' = 'true', '휴면 시험 예약 본인 취소');
reset role; set role authenticated;
select test.ok((public.admin_user(:d_uid))->'user'->>'dormant' = 'true', '취소한 예약은 이용으로 세지 않음 → 다시 휴면');
-- 30일 지난 예약이 지워져도 마지막 이용일은 남음
reset role;
insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext) values ('2026-11-01', 9, '휴면외부', null, :d_uid, true);
select test.ok((public.cleanup_old())->>'ok' = 'true', '정리 함수 실행(11/22 전 예약 삭제)');
select test.ok(not exists (select 1 from public.reservations where user_id = :d_uid and date = '2026-11-01'), '11/1 예약은 지워짐');
select test.ok(public.user_last_used(:d_uid) = '2026-11-01', '지워진 예약의 이용 날짜가 마지막 이용일로 남음');
select test.ok(not public.user_dormant(:d_uid), '11/1 이용 → 12/22엔 51일이라 휴면 아님');
set role anon;
select test.denied($$select public.user_dormant(1)$$, '익명은 휴면 함수를 직접 부를 수 없음');
reset role;

-- ===== 18. 블랙리스트(외부 이용자만, 015) =====
-- 지금 12/22. 만료외부(외부, 횟수권 12/19~12/22 남음 2회 이상)로 시험
set role anon;
select (public.reserve('2026-12-23', 10, '만료외부', '1212', true, 'ext'))->>'id' as bl_rid \gset
reset role; set role authenticated;
select test.ok((public.admin_set_status(:f_uid, 'blacklisted'))->>'msg' like '블랙리스트는 일반회원만%', '재원생은 블랙리스트 등록 불가');
select test.ok(((public.admin_set_status(:x_uid, 'blacklisted'))->>'cancelled')::int >= 1, '블랙리스트 등록 → 앞으로의 확정 예약 자동 취소');
reset role;
select test.ok(not exists (select 1 from public.reservations where user_id = :x_uid and status = 'confirmed' and not public.slot_ended(date, hour)),
               '그 이용자의 끝나지 않은 확정 예약이 남지 않음');
set role authenticated;
reset role;
select test.ok((select cancel_reason from public.reservations where id = :bl_rid) = '관리자 취소: 이용 제한', '취소 사유: 관리자 취소: 이용 제한');
select test.ok(exists (select 1 from public.products where user_id = :x_uid and end_date >= '2026-12-22'), '정액권·횟수권은 그대로 남음');
set role authenticated;
select test.ok((public.admin_set_status(:x_uid, 'blacklisted'))->>'msg' like '이미 블랙리스트%', '두 번 등록 안 됨');
select test.ok((public.admin_user(:x_uid))->'user'->>'status' = 'blacklisted', '이용자 정보에 상태 blacklisted');
set role anon;
select test.ok((public.reserve('2026-12-23', 11, '만료외부', '1212', true, 'ext'))->>'msg' = '현재 예약이 제한되어 있습니다. 관리자에게 문의하십시오.', '블랙리스트 외부 이용자 예약 → 제한 안내');
select test.ok((public.reserve('2026-12-23', 11, '만료외부', '9999', true, 'ext'))->>'msg' like '등록된 일반회원 정보와 일치하지 않습니다%', '비밀번호가 틀리면 블랙리스트 여부를 알려 주지 않음');
select test.ok((public.my_reservations('만료외부', '1212'))->>'ok' = 'true', '블랙리스트여도 내 예약 조회는 가능(취소 사유 확인)');
reset role; set role authenticated;
select test.ok(exists (select 1 from jsonb_array_elements((public.admin_find_users('만료외부', '2026-12-23'))->'users') e where e->>'status' = 'blacklisted'),
               '관리자 예약 이름 찾기에 블랙리스트 표시');
select test.ok((public.admin_reserve('2026-12-23', 12, '만료외부', :x_uid, null, false))->>'msg' like '블랙리스트 이용자입니다%', '관리자 일반예약은 막힘');
select test.ok((public.admin_reserve('2026-12-23', 12, '만료외부', :x_uid, null, true))->>'ok' = 'true', '관리자 슈퍼패스는 허용');
select test.ok((public.admin_update_user(jsonb_build_object('id', :x_uid, 'type', 'ext', 'name', '만료외부', 'phone', '01012121212', 'memo', '시험 사유')))->>'ok' = 'true',
               '블랙리스트 이용자도 메모 수정 가능');
reset role;
select test.ok((select count(*) from public.users where id = :x_uid and type = 'ext') = 1, '구분은 외부 그대로');
do $$ begin
  update public.users set type = 'stu' where name = '만료외부';
  raise exception '실패: 블랙리스트 이용자를 재원생으로 바꿀 수 있음';
exception when others then
  if sqlerrm like '실패:%' then raise; end if;
  raise notice '통과: 블랙리스트인 동안 재원생으로 바꿀 수 없음';
end $$;
set role authenticated;
select test.ok((public.admin_set_status(:x_uid, 'active'))->'user'->>'status' = 'active', '블랙리스트 복귀');
set role anon;
select test.ok((public.reserve('2026-12-23', 13, '만료외부', '1212', true, 'ext'))->>'ok' = 'true', '복귀 뒤 다시 예약 가능(남은 횟수권 사용)');
reset role;

-- ===== 19. 블랙리스트 사유·이력 (016) =====
set role authenticated;
select test.ok((public.admin_user(:x_uid))->'user'->>'black_count' = '1', '18번에서 한 번 블랙리스트였던 이력(1회)');
select test.ok((public.admin_user(:x_uid))->'user'->>'black_restored_at' is not null, '복귀 날짜 기록');
select test.ok((public.admin_set_status(:x_uid, 'blacklisted', '  노쇼 3회  '))->'user'->>'black_reason' = '노쇼 3회', '사유와 함께 블랙리스트 등록(앞뒤 공백 정리)');
select test.ok((public.admin_user(:x_uid))->'user'->>'black_count' = '2', '이력 2회');
select test.ok((public.admin_user(:x_uid))->'user'->>'black_restored_at' is null, '다시 등록하면 복귀 날짜 비움');
select test.ok((public.admin_set_black_reason(:x_uid, '노쇼 3회, 장비 파손'))->'user'->>'black_reason' = '노쇼 3회, 장비 파손', '블랙리스트인 동안 사유 수정');
select test.ok((public.admin_set_black_reason(:x_uid, ''))->'user'->>'black_reason' is null, '사유 비우기');
select test.ok((public.admin_set_black_reason(:x_uid, repeat('가', 250)))->'user'->>'black_reason' = repeat('가', 200), '사유는 200자까지');
select test.ok((public.admin_set_black_reason(:x_uid, '노쇼'))->>'ok' = 'true', '사유 다시 적기');
select test.ok((public.admin_set_status(:x_uid, 'active'))->'user'->>'black_reason' = '노쇼', '복귀해도 사유는 이력으로 남음');
select test.ok((public.admin_user(:x_uid))->'user'->>'black_restored_at' is not null, '복귀 날짜 다시 기록');
select test.ok((public.admin_set_black_reason(:x_uid, '바꾸기'))->>'ok' = 'false', '블랙리스트가 아니면 사유 수정 안 됨');
select test.ok((public.admin_set_status(:x_uid, 'blacklisted'))->'user'->>'black_reason' is null, '사유 없이도 등록 가능');
select test.ok((public.admin_set_status(:x_uid, 'active'))->>'ok' = 'true', '다시 복귀');
set role anon;
select test.denied($$select public.admin_set_black_reason(1, 'x')$$, '익명은 사유 수정 함수를 부를 수 없음');
select test.ok((public.my_reservations('만료외부', '1212'))::text not like '%black%', '공개 내 예약 응답에는 블랙리스트 정보가 없음');
reset role;

-- ===== 20. 상품 없는(일반) 외부 이용자도 블랙리스트 (2026-10-30 확인) =====
set role authenticated;
select test.ok((public.admin_user(:d_uid))->'user'->'current' = 'null'::jsonb, '휴면외부는 상품 없는 일반 외부 이용자');
select test.ok((public.admin_set_status(:d_uid, 'blacklisted', '시험'))->'user'->>'status' = 'blacklisted', '일반 외부 이용자 블랙리스트 등록');
set role anon;
select test.ok((public.reserve('2026-12-23', 14, '휴면외부', '5656', true, 'ext'))->>'msg' = '현재 예약이 제한되어 있습니다. 관리자에게 문의하십시오.', '일반 외부 이용자도 예약 제한 안내');
reset role; set role authenticated;
select test.ok((public.admin_reserve('2026-12-23', 14, '휴면외부', :d_uid, null, false))->>'msg' like '블랙리스트 이용자입니다%', '일반 외부 이용자도 관리자 일반예약 막힘');
select test.ok((public.admin_set_status(:d_uid, 'active'))->'user'->>'black_count' = '1', '복귀하면 이력 1회');
set role anon;
select test.ok((public.reserve('2026-12-23', 14, '휴면외부', '5656', true, 'ext'))->>'ok' = 'true', '복귀 뒤 일반 외부 이용자 예약 가능');
reset role;

-- ===== 21. 끝난 지 7일 안의 상품도 예약 창에 알려 줌 (017) =====
-- 지금 12/22. 만료정액(재원생)의 정액권들: 12/20 하루짜리(2일 전 종료) 외에 15번·16번에서 만든 것들이 있음
reset role;
insert into public.users (type, name, pw_hash, phone) values ('ext', '칠일시험', public.hash_pw('4545'), '010-4545-4545');
select id as s_uid from public.users where name = '칠일시험' \gset
insert into public.products (user_id, kind, start_date, end_date, total_count) values (:s_uid, 'count', '2026-11-16', '2026-12-15', 5);  -- 7일 전 종료
set role anon;
select test.ok((public.product_info('ext', '칠일시험', '4545'))->'product'->>'end' = '2026-12-15', '끝난 지 7일째(12/15 종료, 오늘 12/22) 상품은 알려 줌');
reset role;
update public.products set end_date = '2026-12-14' where user_id = :s_uid;  -- 8일 전 종료
set role anon;
select test.ok((public.product_info('ext', '칠일시험', '4545'))->'product' = 'null'::jsonb, '끝난 지 8일 지난 상품은 알려 주지 않음');
reset role;
update public.products set end_date = '2026-12-21' where user_id = :s_uid;  -- 어제 종료
set role anon;
select test.ok((public.product_info('ext', '칠일시험', '4545'))->'product'->>'kind' = 'count', '어제 끝난 상품도 알려 줌');
select test.ok((public.product_info('ext', '칠일시험', '9999'))->'product' = 'null'::jsonb, '비밀번호가 틀리면 알려 주지 않음');
reset role;
insert into public.products (user_id, kind, start_date, end_date, total_count) values (:s_uid, 'count', '2026-12-22', '2026-12-30', 3);
set role anon;
select test.ok((public.product_info('ext', '칠일시험', '4545'))->'product'->>'end' = '2026-12-30', '사용 중 상품이 있으면 그것을 알려 줌');
select test.ok((public.reserve('2026-12-23', 15, '칠일시험', '4545', true, 'ext'))->>'prod' = 'count', '사용 중 상품으로 예약됨');
reset role;

-- ===== 22. 입금 계좌 (018) =====
set role anon;
select test.ok((public.pay_info())->>'number' = '', '처음엔 입금 계좌가 비어 있음');
select test.denied($$select public.admin_set_pay('{}')$$, '익명은 입금 계좌를 바꿀 수 없음');
reset role; set role authenticated;
select test.ok((public.admin_set_pay('{"bank":"농협","holder":"현실용음악학원","number":"12a-34","fee":"5000"}'))->>'msg' like '계좌번호는%', '계좌번호 형식 확인');
select test.ok((public.admin_set_pay('{"bank":"","holder":"x","number":"123-456789","fee":""}'))->>'msg' like '은행명%', '은행명 필수');
select test.ok((public.admin_set_pay('{"bank":"농협","holder":"현실용음악학원","number":"123-4567-8901-23","fee":"5,000원"}'))->>'fee' = '5000', '저장(이용료의 쉼표·원 정리)');
set role anon;
select test.ok((public.pay_info())->>'number' = '123-4567-8901-23' and (public.pay_info())->>'holder' = '현실용음악학원', '저장한 계좌가 공개 화면에 바로 보임');
reset role;

-- ===== 23. 상품 정보에 등록 이용자 표시 (019) =====
set role anon;
select test.ok((public.product_info('ext', '칠일시험', '4545'))->>'registered' = 'true', '등록 외부 이용자(이름+비밀번호 맞음)는 registered');
select test.ok((public.product_info('ext', '휴면외부', '5656'))->>'registered' = 'true' and (public.product_info('ext', '휴면외부', '5656'))->'product' = 'null'::jsonb, '상품 없는 등록 외부 이용자도 registered');
select test.ok((public.product_info('ext', '휴면외부', '0000'))->>'registered' is null, '비밀번호가 틀리면 registered 없음');
select test.ok((public.product_info('ext', '없는사람', '1234'))->>'registered' is null, '미등록 이름은 registered 없음');
reset role;

-- ===== 24. "외부 이용자" → "일반회원" 문구 (020) =====
set role authenticated;
select test.ok((public.admin_create_user('{"type":"x","name":"문구시험","pw":"1234","phone":"01012341234"}'))->>'msg' = '재원생 또는 일반회원을 선택하십시오.', '이용자 등록 구분 안내 문구');
reset role;

-- ===== 25. 1회 이용료 (021) =====
set role anon;
select test.denied($$select public.admin_set_fee('5000')$$, '익명은 이용료를 바꿀 수 없음');
reset role; set role authenticated;
select test.ok((public.admin_set_fee('5천원'))->>'msg' like '이용료는%', '이용료는 숫자만');
select test.ok((public.admin_set_fee('7,000원'))->>'fee' = '7000', '이용료 저장(쉼표·원 정리)');
select test.ok((public.pay_info())->>'number' = '123-4567-8901-23', '이용료를 바꿔도 계좌는 그대로');
select test.ok((public.admin_set_pay('{"bank":"신한","holder":"현실용음악학원","number":"110-123-456789"}'))->>'fee' = '7000', '계좌만 저장하면 이용료는 그대로');
set role anon;
select test.ok((public.pay_info())->>'fee' = '7000' and (public.pay_info())->>'bank' = '신한', '공개 화면에 계좌·이용료 함께 보임');
reset role; set role authenticated;
select test.ok((public.admin_set_fee(''))->>'fee' = '', '이용료 비우기');
reset role;

-- ===== 26. 이용료 표 (022) =====
set role anon;
select test.ok((public.price_info())->'ext_flat' = '[]'::jsonb, '처음엔 상품 가격 표가 비어 있음');
select test.denied($$select public.admin_set_prices('{}')$$, '익명은 이용료 표를 바꿀 수 없음');
reset role; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"","ext_flat":[{"n":"1","price":""}]}'))->>'msg' like '일반회원 정액권 1번째 줄: 가격%', '가격이 빈 줄은 막음');
select test.ok((public.admin_set_prices('{"fee":"","ext_count":[{"n":"0","price":"1000"}]}'))->>'msg' like '일반회원 횟수권 1번째 줄: 횟수를 1~999%', '횟수 0은 막음');
select test.ok((public.admin_set_prices('{"fee":"","stu_flat":[{"n":"100","price":"1000"}]}'))->>'msg' like '재원생 정액권 1번째 줄: 횟수를 1~99%', '정액권 하루 100회는 막음');
select test.ok((public.admin_set_prices('{"fee":"","ext_flat":[{},{},{},{},{},{},{},{},{},{},{}]}'))->>'msg' like '%10개까지%', '11개는 막음');
select test.ok((public.admin_set_prices('{"fee":"8,000원","ext_flat":[{"n":"1","price":"100,000원"},{"n":"","price":""},{"n":"2회","price":"150000"}],"ext_count":[{"n":"10","price":"60000"}],"stu_flat":[]}'))->'ext_flat' = '[{"n":1,"price":"100000"},{"n":2,"price":"150000"}]'::jsonb, '저장(빈 줄은 버림, 쉼표·원·회 정리)');
set role anon;
select test.ok((public.price_info())->>'fee' = '8000' and (public.price_info())->'ext_count'->0->>'price' = '60000', '공개 조회에 1회 이용료·상품 가격이 보임');
select test.ok((public.pay_info())->>'fee' = '8000' and (public.pay_info())->>'bank' = '신한', '1회 이용료는 계좌 상자에도 반영, 계좌는 그대로');
reset role;

-- ===== 27. 이용료 마지막 수정 날짜 (023) =====
reset role; set app.fake_now = '2027-01-05 10:00:00'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"8000","ext_flat":[{"n":"1","price":"100000"},{"n":"2","price":"150000"}],"ext_count":[{"n":"10","price":"60000"}],"stu_flat":[{"n":"1","price":"50000"}]}'))->>'updated_at' = '2027-01-05', '가격 표를 바꿔 저장하면 수정 날짜가 남음');
reset role; set app.fake_now = '2027-01-09 10:00:00'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"8,000원","ext_flat":[{"n":"1","price":"100,000"},{"n":"2","price":"150000"}],"ext_count":[{"n":"10","price":"60000"}],"stu_flat":[{"n":"1","price":"50,000원"}]}'))->>'updated_at' = '2027-01-05', '바뀐 것 없이 저장하면 날짜 그대로');
select test.ok((public.admin_set_prices('{"fee":"8000","ext_flat":[{"n":"1","price":"110000"},{"n":"2","price":"150000"}],"ext_count":[{"n":"10","price":"60000"}],"stu_flat":[{"n":"1","price":"50000"}]}'))->>'updated_at' = '2027-01-09', '가격을 바꾸면 날짜가 오늘로');
reset role; set app.fake_now = '2027-01-10 10:00:00'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"9000","ext_flat":[{"n":"1","price":"110000"},{"n":"2","price":"150000"}],"ext_count":[{"n":"10","price":"60000"}],"stu_flat":[{"n":"1","price":"50000"}]}'))->>'updated_at' = '2027-01-10', '1회 이용료만 바꿔도 날짜가 오늘로');
set role anon;
select test.ok((public.price_info())->>'updated_at' = '2027-01-10', '공개 조회에 수정 날짜가 보임');
reset role; reset app.fake_now;

-- ===== 28. 이용자 삭제 (024) =====
reset role; set app.fake_now = '2027-02-10 12:00:00'; set role authenticated;
select test.ok((public.admin_create_user('{"type":"ext","name":"삭제시험","pw":"4242","phone":"01042424242","memo":"메모",
  "prod":{"kind":"count","start":"2027-02-01","days":30,"total":5}}'))->>'ok' = 'true', '삭제 시험: 횟수권 일반회원 등록');
reset role;
select id as del_uid from public.users where name = '삭제시험' \gset
select id as del_pid from public.products where user_id = :del_uid \gset
-- 지난 예약 1건(어제), 앞으로의 예약 2건(오늘 15시, 내일 10시)
insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, product_id, product_kind)
  select '2027-02-09', 9, '삭제시험', pw_hash, id, true, :del_pid, 'count' from public.users where id = :del_uid;
set role anon;
select test.ok((public.reserve('2027-02-10', 15, '삭제시험', '4242', true, 'ext'))->>'ok' = 'true', '삭제 시험: 오늘 예약');
select test.ok((public.reserve('2027-02-11', 10, '삭제시험', '4242', true, 'ext'))->>'ok' = 'true', '삭제 시험: 내일 예약');
select test.denied($$select public.admin_delete_user(1)$$, '익명은 이용자를 삭제할 수 없음');
reset role; set role authenticated;
select test.ok((public.admin_delete_user(:del_uid))->>'cancelled' = '2', '삭제: 앞으로의 예약 2건 자동 취소');
select test.ok((public.admin_delete_user(:del_uid))->>'msg' like '없는 이용자%', '이미 삭제한 이용자는 다시 못 지움');
reset role;
select test.ok(not exists (select 1 from public.users where id = :del_uid), '이용자 정보(이름·전화번호·메모) 삭제됨');
select test.ok(not exists (select 1 from public.products where id = :del_pid), '정액권·횟수권 함께 삭제됨');
select test.ok((select count(*) from public.reservations where name = '삭제시험' and status = 'cancelled' and cancel_reason = '관리자 취소: 이용자 삭제' and user_id is null) = 2, '취소된 예약은 사유가 남고 이용자 연결만 끊김');
select test.ok((select count(*) from public.reservations where name = '삭제시험' and date = '2027-02-09' and status = 'confirmed' and user_id is null and product_id is null) = 1, '지난 예약은 기록으로 남음(연결만 끊김)');
set role anon;
select test.ok((public.my_reservations('삭제시험', '4242'))->'list'->0->>'reason' is not null and (public.my_reservations('삭제시험', '4242'))->>'user_type' is null, '내 예약에서 취소 사유 확인 가능, 등록 이용자 아님');
select test.ok((public.reserve('2027-02-11', 11, '삭제시험', '4242', true, 'ext'))->>'msg' like '등록된 일반회원 정보와 일치하지 않습니다%', '삭제된 일반회원은 더 예약할 수 없음(미등록)');
reset role; reset app.fake_now;

-- ===== 29. 재원생 명부 연동 (025) =====
reset role; set app.fake_now = '2027-03-10 12:00:00'; set role authenticated;
-- 연동 전에 등록해 둔 재원생(이름·비밀번호가 명부와 같으면 자동 연결될 사람), 명부에 없는 정액권 재원생
select test.ok((public.admin_create_user('{"type":"stu","name":"명부연결","pw":"1111","phone":"01011111111"}'))->>'ok' = 'true', '명부 시험: 연동 전 재원생 등록');
select test.ok((public.admin_create_user('{"type":"stu","name":"정액밖","pw":"2222","phone":"01022222222","prod":{"kind":"flat","start":"2027-03-01","days":30,"limit":2}}'))->>'ok' = 'true', '명부 시험: 명부에 없는 정액권 재원생 등록');
select test.ok((public.admin_set_roster_check(true))->>'msg' like '명부가 비어 있습니다%', '명부가 비면 명부 확인을 켤 수 없음');
reset role;
set role anon;
select test.ok((public.roster_sync('틀린열쇠', '[]'))->>'msg' like '연동 열쇠가 맞지 않습니다%', '열쇠가 없거나 틀리면 거절');
select test.denied($$select public.admin_roster_token()$$, '익명은 연동 열쇠를 만들 수 없음');
select test.denied($$select public.admin_roster_status()$$, '익명은 연동 상태를 볼 수 없음');
reset role; set role authenticated;
select (public.admin_roster_token())->>'token' as rtk \gset
reset role; set role anon;
select test.ok((public.roster_sync(:'rtk', '[]'))->>'msg' like '보낸 명부에 올바른 학생이 없습니다%', '빈 명부는 거절');
select test.ok((public.roster_sync(:'rtk', '[{"no":"R1","name":"명부일","pw4":"4321"},{"no":"R2","name":"명부연결","pw4":"1111"},{"no":"R3","name":"x","pw4":"12"},{"no":"R1","name":"명부중복","pw4":"9999"}]')) @> '{"ok":true,"count":2,"added":2,"linked":1}'::jsonb, '명부 반영: 올바른 2명, 잘못된 줄·중복 등록번호는 건너뜀, 같은 이름·비밀번호 재원생 자동 연결');
reset role;
select test.ok((select count(*) from public.roster) = 2 and (select roster_no from public.users where name = '명부연결') = 'R2', '명부 2명, 자동 연결 확인');
select test.ok(not exists (select 1 from public.roster where pw_hash like '%4321%'), '뒤 4자리는 원문으로 저장하지 않음');
set role authenticated;
select test.ok((public.admin_set_roster_check(true))->>'check' = 'true', '명부 확인 켜기');
reset role; set role anon;
select test.ok((public.reserve('2027-03-10', 13, '명부일', '4321', true, 'stu'))->>'ok' = 'true', '명부에 있는 재원생은 예약됨');
select test.ok((public.reserve('2027-03-10', 14, '명부없음', '4321', true, 'stu'))->>'msg' like '재원생 명부에서 확인되지 않습니다%', '명부에 없는 이름은 막힘');
select test.ok((public.reserve('2027-03-11', 14, '명부일', '0000', true, 'stu'))->>'msg' like '재원생 명부에서 확인되지 않습니다%', '이름은 맞고 비밀번호가 틀리면 막힘');
select test.ok((public.reserve('2027-03-10', 15, '정액밖', '2222', true, 'stu'))->>'prod' = 'flat', '(나) 명부에 없어도 그날 정액권이 있으면 예약됨');
select test.ok((public.reserve('2027-03-10', 16, '명부연결', '1111', true, 'ext'))->>'msg' like '등록된 일반회원 정보와 일치하지 않습니다%', '일반회원 예약은 명부와 상관없이 전과 같음');
-- 시트에서 전화번호가 바뀜 → 연결된 재원생 비밀번호도 바뀜
reset role; set role anon;
select test.ok((public.roster_sync(:'rtk', '[{"no":"R1","name":"명부일","pw4":"4321"},{"no":"R2","name":"명부연결","pw4":"5555"}]')) @> '{"ok":true,"changed":1}'::jsonb, '전화번호가 바뀐 학생 반영');
select test.ok((public.reserve('2027-03-10', 17, '명부연결', '5555', true, 'stu'))->>'ok' = 'true', '바뀐 뒤 4자리로 예약됨');
select test.ok((public.my_reservations('명부연결', '5555'))->>'user_type' = 'stu', '연결된 재원생 비밀번호도 새 뒤 4자리로 바뀜');
select test.ok((public.reserve('2027-03-11', 17, '명부연결', '1111', true, 'stu'))->>'msg' like '재원생 명부에서 확인되지 않습니다%', '옛 뒤 4자리는 막힘');
-- 안전장치: 12명 → 3명이면 거절, 강제로 반영은 됨
select test.ok((public.roster_sync(:'rtk', (select jsonb_agg(jsonb_build_object('no','M'||i,'name','명부다수','pw4',(1000+i)::text)) from generate_series(1,12) i)))->>'count' = '12', '12명 반영');
select test.ok((public.roster_sync(:'rtk', '[{"no":"R1","name":"명부일","pw4":"4321"},{"no":"R2","name":"명부연결","pw4":"5555"},{"no":"M1","name":"명부다수","pw4":"1001"}]'))->>'msg' like '한 번에 절반 넘게 빠져서%', '한 번에 절반 넘게 빠지면 거절');
reset role;
select test.ok((select count(*) from public.roster) = 12, '거절되면 기존 명부 그대로');
set role anon;
select test.ok((public.roster_sync(:'rtk', '[{"no":"R1","name":"명부일","pw4":"4321"},{"no":"R2","name":"명부연결","pw4":"5555"},{"no":"M1","name":"명부다수","pw4":"1001"}]', true))->>'removed' = '11', '강제로 반영하면 빠진 학생 삭제');
-- 명부에서 빠져도 이미 잡힌 예약은 그대로
select test.ok((public.roster_sync(:'rtk', '[{"no":"R2","name":"명부연결","pw4":"5555"},{"no":"M1","name":"명부다수","pw4":"1001"}]'))->>'removed' = '1', '명부일 빠짐');
reset role;
select test.ok(exists (select 1 from public.reservations where name = '명부일' and date = '2027-03-10' and status = 'confirmed'), '명부에서 빠져도 이미 잡힌 예약은 그대로');
set role anon;
select test.ok((public.reserve('2027-03-11', 13, '명부일', '4321', true, 'stu'))->>'msg' like '재원생 명부에서 확인되지 않습니다%', '명부에서 빠지면 새 예약은 막힘');
reset role; set role authenticated;
-- 이름으로 찾기·이용자 등록 때 명부 연결·직접 연결
select test.ok((public.admin_roster_find('명부다수'))->'rows'->0->>'no' = 'M1' and (public.admin_roster_find('명부다수'))->'rows'->0->>'pw4' is null, '이름으로 명부 찾기(뒤 4자리는 주지 않음)');
select test.ok((public.admin_create_user('{"type":"stu","name":"다른이름","phone":"01033333333","roster_no":"M1"}'))->>'msg' like '이름이 명부%', '이름이 명부와 다르면 등록 막힘');
select test.ok((public.admin_create_user('{"type":"stu","name":"명부다수","phone":"01033333333","roster_no":"M1","prod":{"kind":"flat","start":"2027-03-10","days":30,"limit":3}}'))->'user'->>'roster_no' = 'M1', '명부에서 골라 정액권과 함께 등록(비밀번호 입력 없음)');
select test.ok((public.admin_create_user('{"type":"stu","name":"명부다수","phone":"01033333333","roster_no":"M1"}'))->>'msg' like '이 명부 학생은 이미 등록%', '같은 명부 학생은 두 번 등록 안 됨');
reset role; set role anon;
select test.ok((public.reserve('2027-03-10', 18, '명부다수', '1001', true, 'stu'))->>'prod' = 'flat', '명부에서 등록한 학생은 뒤 4자리로 정액권 예약');
reset role;
select id as lk_uid from public.users where name = '정액밖' \gset
set role authenticated;
select test.ok((public.admin_link_roster(:lk_uid, 'M1'))->>'msg' like '이름이 명부%', '이름이 다르면 직접 연결 막힘');
select test.ok((public.admin_roster_status())->'unlinked' @> '[{"name":"정액밖"}]'::jsonb, '명부와 연결 안 된 재원생 목록');
reset role;
update public.users set type = 'ext' where name = '명부연결';
select test.ok((select roster_no from public.users where name = '명부연결') is null, '일반회원으로 바꾸면 명부 연결이 풀림');
-- 30. 026: 예약 창에서 재원생 확인 미리 보기(product_info의 roster)
set role anon;
select test.ok((public.product_info('stu', '명부다수', '1001'))->>'roster' = 'true', '명부와 맞으면 roster=true');
select test.ok((public.product_info('stu', '명부다수', '1001'))->'product' is not null, '정액권 정보도 함께 줌');
select test.ok((public.product_info('stu', '명부밖학생', '1234'))->>'roster' = 'false', '명부에 없는 이름은 roster=false');
select test.ok(not ((public.product_info('ext', '명부다수', '1001')) ? 'roster'), '일반회원 창에는 roster를 주지 않음');
select test.ok((public.product_info('stu', '명부다수', '9999'))->>'roster' = 'false', '뒤 4자리가 틀리면 roster=false');
select public.product_info('stu', '명부다수', '9998'), public.product_info('stu', '명부다수', '9997'), public.product_info('stu', '명부다수', '9996'), public.product_info('stu', '명부다수', '9995');
select test.ok((public.product_info('stu', '명부다수', '1001'))->>'locked' = 'true', '명부 이름의 뒤 4자리를 5번 틀리면 잠금');
select test.ok(not coalesce(((public.product_info('stu', '명부밖학생', '1235'))->>'locked')::boolean, false), '명부에 없는 이름은 틀려도 잠그지 않음');
select public.product_info('stu', '명부밖학생', '1236'), public.product_info('stu', '명부밖학생', '1237'), public.product_info('stu', '명부밖학생', '1238'), public.product_info('stu', '명부밖학생', '1239');
select test.ok((public.product_info('stu', '명부밖학생', '1234'))->>'roster' = 'false' and not ((public.product_info('stu', '명부밖학생', '1234')) ? 'locked'), '명부에 없는 이름은 여러 번 물어도 잠기지 않음');
-- 31. 027: 명부 학생은 예약이 없어도 내 예약 조회
reset role;
insert into public.roster (reg_no, name, pw_hash) values ('Z1', '예약없는생', public.hash_pw('2468'));
set role anon;
select test.ok((public.my_reservations('예약없는생', '2468')) @> '{"ok":true,"list":[],"user_type":"stu"}'::jsonb, '명부 학생은 예약이 없어도 조회됨(재원생)');
select test.ok((public.my_reservations('예약없는생', '1357'))->>'ok' = 'false', '뒤 4자리가 틀리면 조회 안 됨');
select test.ok((public.my_reservations('명부에없음', '2468'))->>'ok' = 'false', '명부에 없고 예약도 없으면 조회 안 됨');
select test.ok((public.my_codes('예약없는생', '2468'))->'codes' = 'null'::jsonb or (public.my_codes('예약없는생', '2468'))->'codes' is null, '예약이 없으면 출입 비밀번호는 주지 않음');
reset role;
set role authenticated;
select test.ok((public.admin_set_roster_check(false))->>'check' = 'false', '명부 확인 끄기');
reset role; set role anon;
select test.ok(not ((public.product_info('stu', '명부밖학생', '1234')) ? 'roster'), '명부 확인을 끄면 roster를 주지 않음');
reset role; set role anon;
select test.ok((public.reserve('2027-03-11', 13, '명부밖학생', '1234', true, 'stu'))->>'ok' = 'true', '끄면 전처럼 아무 재원생이나 예약됨');
reset role; reset app.fake_now;

-- 32. 028: 출입 비밀번호 마지막 수정 날짜
reset role; set app.fake_now = '2027-04-01 10:00';
set role authenticated;
select test.ok((public.admin_set_door_codes('{"gate":"1111","room":"2222","toilet":"3333"}'))->'codes'->>'updated_at' = '2027-04-01', '바꾸면 오늘 날짜가 남음');
reset role; set app.fake_now = '2027-04-05 10:00'; set role authenticated;
select test.ok((public.admin_set_door_codes('{"gate":"1111","room":"2222","toilet":"3333"}'))->'codes'->>'updated_at' = '2027-04-01', '안 바꾸고 저장하면 날짜 그대로');
select test.ok((public.admin_door_codes())->'codes'->>'updated_at' = '2027-04-01', '관리자 조회에도 날짜');
select test.ok((public.admin_set_door_codes('{"gate":"1111","room":"2222","toilet":"4444"}'))->'codes'->>'updated_at' = '2027-04-05', '하나만 바꿔도 오늘 날짜로');
reset role;
select test.ok(public.door_codes()->>'updated_at' = '2027-04-05' and public.door_codes()->>'toilet' = '4444', '공개 my_codes가 쓰는 값에도 날짜');
reset app.fake_now;

-- 33. 029: 재원생은 전화번호 없이 등록·수정
set role authenticated;
select test.ok((public.admin_create_user('{"type":"stu","name":"번호없생","pw":"3579","phone":""}'))->'user'->>'phone' = '', '재원생은 전화번호 없이 등록됨');
select test.ok((public.admin_create_user('{"type":"stu","name":"번호틀생","pw":"3579","phone":"0123"}'))->>'msg' like '전화번호를 올바르게%', '재원생도 적은 번호가 틀리면 막힘');
select test.ok((public.admin_create_user('{"type":"ext","name":"번호없외","pw":"3579","phone":""}'))->>'msg' like '전화번호를 올바르게%', '일반회원은 전화번호 필수');
reset role;
select id as np_uid from public.users where name = '번호없생' \gset
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :np_uid, 'type', 'stu', 'name', '번호없생', 'phone', '', 'part', '드럼')))->>'ok' = 'true', '재원생 수정도 전화번호 없이 저장');
select test.ok((public.admin_update_user(jsonb_build_object('id', :np_uid, 'type', 'ext', 'name', '번호없생', 'phone', '')))->>'msg' like '전화번호를 올바르게%', '일반회원으로 바꿀 때는 전화번호 필요');
reset role;

-- 34. 030: 재원생 횟수권
reset role; set app.fake_now = '2027-05-01 08:00';
set role authenticated;
select test.ok((public.admin_create_user('{"type":"stu","name":"재횟수","pw":"2580","prod":{"kind":"count","start":"2027-05-01","days":30,"total":2}}'))->'user'->'current'->>'kind' = 'count', '재원생 횟수권 등록');
select test.ok((public.admin_create_user('{"type":"stu","name":"재횟둘","pw":"2581","prod":{"kind":"count","start":"2027-05-01","days":30,"total":3}}'))->>'ok' = 'true', '재원생 횟수권 등록(명부에 없는 학생)');
select test.ok((public.admin_set_roster_check(true))->>'check' = 'true', '명부 확인 켜기');
reset role; set role anon;
select test.ok((public.product_info('stu', '재횟수', '2580'))->'product'->>'kind' = 'count', '예약 창에 재원생 횟수권 정보');
select test.ok((public.reserve('2027-05-01', 10, '재횟수', '2580', true, 'stu'))->>'prod' = 'count', '재원생 횟수권으로 예약(명부에 없어도 횟수권이면 예외)');
select test.ok((public.reserve('2027-05-01', 11, '재횟수', '2580', true, 'stu'))->>'prod' = 'count', '같은 날 두 번째도 됨(하루 제한 없음)');
select test.ok((public.reserve('2027-05-01', 12, '재횟수', '2580', true, 'stu'))->>'msg' like '횟수권 2회를 모두%', '총 횟수를 다 쓰면 막힘');
select test.ok((public.my_reservations('재횟수', '2580'))->'product'->'left'->>'total' = '0' or (public.my_reservations('재횟수', '2580'))->>'ok' = 'true', '내 예약 조회');
select test.ok((public.cancel_own((select (x->>'id')::bigint from jsonb_array_elements((public.my_reservations('재횟수', '2580'))->'list') x limit 1), '재횟수', '2580'))->>'ok' = 'true', '취소하면');
select test.ok((public.reserve('2027-05-01', 13, '재횟수', '2580', true, 'stu'))->>'prod' = 'count', '돌려받은 1회로 다시 예약');
select test.ok((public.reserve('2027-05-02', 9, '재횟둘', '2581', true, 'stu'))->>'prod' = 'count', '명부에 없는 횟수권 재원생도 예약');
select test.ok((public.reserve('2027-05-02', 14, '명부밖둘', '1111', true, 'stu'))->>'msg' like '재원생 명부에서 확인되지 않습니다%', '상품 없는 명부 밖 학생은 그대로 막힘');
reset role;
select id as rh_uid from public.users where name = '재횟둘' \gset
set role authenticated;
select test.ok((public.admin_reserve('2027-05-02', 15, '재횟둘', :rh_uid, false, false))->>'prod' = 'count', '관리자 일반예약도 재원생 횟수권 차감');
select test.ok((public.admin_set_prices('{"fee":"9000","stu_count":[{"n":"10","price":"50000"}]}'))->'stu_count'->0->>'n' = '10', '이용료 표에 재원생 횟수권 저장');
select test.ok((public.admin_set_prices('{"fee":"9000","stu_count":[{"n":"1000","price":"1"}]}'))->>'msg' like '재원생 횟수권 1번째 줄: 횟수를 1~999%', '재원생 횟수권은 999회까지');
select test.ok((public.admin_set_roster_check(false))->>'check' = 'false', '명부 확인 끄기');
reset role; set role anon;
select test.ok((public.price_info()) ? 'stu_count', '공개 이용료 조회에 재원생 횟수권 칸');
reset role; reset app.fake_now;

-- 35. 031: 관리자 예약에서 명부 학생을 고르면 명부의 뒤 4자리가 붙어 '내 예약'에 보임
reset role; set app.fake_now = '2027-05-03 08:00';
set role authenticated;
select test.ok((public.admin_reserve('2027-05-03', 10, '예약없는생', null, false, false, 'Z1'))->>'ok' = 'true', '명부 학생으로 관리자 예약');
select test.ok((public.admin_reserve('2027-05-03', 11, '예약없는생', null, false, false, 'Z9'))->>'msg' like '재원생 명부에서 그 학생을%', '없는 등록번호는 막힘');
select test.ok((public.admin_reserve('2027-05-03', 12, '예약없는생', null, false, false, 'Z1'))->>'msg' like '재원생은 하루에 한 번만%', '명부 학생 관리자 일반예약도 하루 1회');
select test.ok((public.admin_reserve('2027-05-03', 13, '다른이름', null, false, true, 'Z1'))->>'msg' like '재원생 명부에서 그 학생을%', '이름이 명부와 다르면 막힘');
reset role; set role anon;
select test.ok(jsonb_array_length((public.my_reservations('예약없는생', '2468'))->'list') = 1, '그 학생의 내 예약에 관리자 예약이 보임');
select test.ok((public.my_codes('예약없는생', '2468'))->'codes'->>'gate' is not null, '출입 비밀번호도 받음');
reset role; reset app.fake_now;

-- 36. 032: 일반회원 상품 없는 예약의 입금 확인(관리자 전용)
reset role; set app.fake_now = '2027-05-04 08:00';
set role authenticated;
select test.ok((public.admin_create_user('{"type":"ext","name":"입금시험","pw":"8642","phone":"01086420000"}'))->>'ok' = 'true', '입금 확인용 일반회원 등록');
select test.ok((public.admin_create_user('{"type":"ext","name":"입금횟수","pw":"8643","phone":"01086430000","prod":{"kind":"count","start":"2027-05-04","days":30,"total":5}}'))->>'ok' = 'true', '횟수권 일반회원 등록');
reset role; set role anon;
select test.ok((public.reserve('2027-05-04', 10, '입금시험', '8642', true, 'ext'))->>'ok' = 'true', '상품 없는 일반회원 예약');
select test.ok((public.reserve('2027-05-04', 11, '입금횟수', '8643', true, 'ext'))->>'prod' = 'count', '횟수권 일반회원 예약');
select test.ok((public.reserve('2027-05-04', 12, '입금재원', '1357', true, 'stu'))->>'ok' = 'true', '재원생 예약');
reset role;
select id as pay_rid from public.reservations where name = '입금시험' and date = '2027-05-04' \gset
select id as pay_cid from public.reservations where name = '입금횟수' and date = '2027-05-04' \gset
select id as pay_sid from public.reservations where name = '입금재원' and date = '2027-05-04' \gset
select id as pay_uid from public.users where name = '입금시험' \gset
set role authenticated;
select test.ok((select (x->>'pay_need')::boolean and not (x->>'pay_ok')::boolean from jsonb_array_elements((public.admin_reservations())->'list') x where (x->>'id')::bigint = :pay_rid), '상품 없는 일반회원 예약은 입금 확인 대상·처음엔 확인 안 됨');
select test.ok((select not (x->>'pay_need')::boolean from jsonb_array_elements((public.admin_reservations())->'list') x where (x->>'id')::bigint = :pay_cid), '횟수권 예약은 대상 아님');
select test.ok((select not (x->>'pay_need')::boolean from jsonb_array_elements((public.admin_reservations())->'list') x where (x->>'id')::bigint = :pay_sid), '재원생 예약은 대상 아님');
select test.ok((public.admin_set_paid(:pay_rid, true))->>'pay_ok' = 'true', '입금 확인');
select test.ok((select (x->>'pay_ok')::boolean from jsonb_array_elements((public.admin_reservations())->'list') x where (x->>'id')::bigint = :pay_rid), '목록에 확인됨으로 보임');
select test.ok((public.admin_set_paid(:pay_rid, false))->>'pay_ok' = 'false', '확인 취소');
select test.ok((public.admin_set_paid(:pay_cid, true))->>'msg' like '입금 확인은 일반회원이 정액권%', '횟수권 예약은 확인 불가');
select test.ok((public.admin_set_paid(:pay_sid, true))->>'msg' like '입금 확인은 일반회원이 정액권%', '재원생 예약은 확인 불가');
select test.ok((public.admin_reserve('2027-05-04', 13, '입금시험', :pay_uid, true, true))->>'ok' = 'true', '슈퍼패스 예약');
reset role;
select id as pay_pid from public.reservations where name = '입금시험' and date = '2027-05-04' and hour = 13 \gset
set role authenticated;
select test.ok((public.admin_set_paid(:pay_pid, true))->>'msg' like '입금 확인은%', '슈퍼패스 예약은 확인 불가(사용자 선택)');
select test.ok((public.admin_cancel(:pay_rid, '시험'))->>'ok' = 'true', '예약 취소');
select test.ok((public.admin_set_paid(:pay_rid, true))->>'msg' like '취소된 예약은%', '취소된 예약은 확인 불가');
reset role; set role anon;
select test.ok((select count(*) from jsonb_each((public.public_board()->'slots'->0))) > 0 and position('pay_ok' in public.public_board()::text) = 0, '공개 현황에 입금 확인 정보 없음');
select test.ok(position('pay_ok' in (public.my_reservations('입금시험', '8642'))::text) = 0, '내 예약에도 입금 확인 정보 없음');
reset role; reset app.fake_now;

-- 37. 033: 정액권 + 횟수권 동시 사용
reset role; set app.fake_now = '2027-06-01 08:00';
set role authenticated;
select test.ok((public.admin_create_user('{"type":"ext","name":"둘다회원","pw":"1111","phone":"01011110000","prods":[{"kind":"flat","start":"2027-06-01","days":30,"limit":1},{"kind":"count","start":"2027-06-01","days":30,"total":2}]}'))->>'ok' = 'true', '정액권+횟수권 함께 등록');
select test.ok((public.admin_create_user('{"type":"ext","name":"같은둘","pw":"1112","phone":"01011120000","prods":[{"kind":"flat","start":"2027-06-01","days":30,"limit":1},{"kind":"flat","start":"2027-06-01","days":30,"limit":2}]}'))->>'msg' like '같은 종류의 상품은%', '같은 종류 두 개는 막힘');
select test.ok(exists (select 1 from jsonb_array_elements((public.admin_users())->'users') x where x->>'name' = '둘다회원' and jsonb_array_length(x->'currents') = 2), '이용자 정보에 상품 2개(currents)');
select test.ok(exists (select 1 from jsonb_array_elements((public.admin_find_users('둘다회원', '2027-06-01'))->'users') x where jsonb_array_length(x->'products') = 2), '관리자 이름 찾기에 상품 2개');
reset role; set role anon;
select test.ok(jsonb_array_length((public.product_info('ext', '둘다회원', '1111'))->'products') = 2, '예약 창 정보에 상품 2개');
select test.ok((public.reserve('2027-06-01', 10, '둘다회원', '1111', true, 'ext'))->>'choose' = 'true', '둘 다 쓸 수 있으면 고르라고 함');
select test.ok(jsonb_array_length((public.reserve('2027-06-01', 10, '둘다회원', '1111', true, 'ext'))->'options') = 2, '고를 상품 2개를 알려 줌');
select test.ok((public.reserve('2027-06-01', 10, '둘다회원', '1111', true, 'ext', 'flat'))->>'prod' = 'flat', '정액권을 골라 예약');
select test.ok((public.reserve('2027-06-01', 11, '둘다회원', '1111', true, 'ext'))->>'choose' = 'true', '034: 정액권 오늘 다 써도 고르는 창');
select test.ok((public.reserve('2027-06-01', 11, '둘다회원', '1111', true, 'ext'))->'options'->0->>'usable' = 'false', '034: 다 쓴 정액권은 usable false');
select test.ok((public.reserve('2027-06-01', 11, '둘다회원', '1111', true, 'ext'))->'options'->1->>'usable' = 'true', '034: 남은 횟수권은 usable true');
select test.ok((public.reserve('2027-06-01', 11, '둘다회원', '1111', true, 'ext', 'count'))->>'prod' = 'count', '남은 횟수권을 골라 예약');
select test.ok((public.reserve('2027-06-01', 12, '둘다회원', '1111', true, 'ext', 'count'))->>'prod' = 'count', '횟수권 한 번 더');
select test.ok((public.reserve('2027-06-01', 13, '둘다회원', '1111', true, 'ext', 'flat'))->>'msg' like '정액권 하루 이용 횟수%', '다 쓴 정액권을 고르면 막힘');
select test.ok((public.reserve('2027-06-01', 13, '둘다회원', '1111', true, 'ext'))->>'msg' like '정액권 하루 이용 횟수(1회)와 횟수권 2회를 모두%', '둘 다 다 쓰면 막힘');
select test.ok((public.reserve('2027-06-02', 10, '둘다회원', '1111', true, 'ext'))->'options'->1->>'why' like '횟수권 2회를 모두%', '034: 다음 날 횟수권 다 씀 → 고르는 창에 이유');
select test.ok((public.reserve('2027-06-02', 10, '둘다회원', '1111', true, 'ext', 'flat'))->>'prod' = 'flat', '정액권을 골라 예약');
select test.ok((public.reserve('2027-06-02', 11, '둘다회원', '1111', true, 'ext', 'count'))->>'msg' like '횟수권 2회를 모두%', '다 쓴 횟수권을 고르면 막힘');
select test.ok(jsonb_array_length((public.my_reservations('둘다회원', '1111'))->'products') = 2, '내 예약에 상품 2개');
reset role;
select id as dd_cnt from public.reservations where name = '둘다회원' and date = '2027-06-01' and hour = 11 \gset
select id as dd_uid from public.users where name = '둘다회원' \gset
select id as dd_fp from public.products where user_id = :dd_uid and kind = 'flat' \gset
select id as dd_cp from public.products where user_id = :dd_uid and kind = 'count' \gset
set role anon;
select test.ok((public.cancel_own(:dd_cnt, '둘다회원', '1111'))->>'ok' = 'true', '횟수권 예약 취소');
select test.ok((public.reserve('2027-06-02', 12, '둘다회원', '1111', true, 'ext'))->'options'->1->>'usable' = 'true', '취소로 돌려받은 횟수권은 다시 쓸 수 있음');
select test.ok((public.reserve('2027-06-02', 12, '둘다회원', '1111', true, 'ext', 'count'))->>'prod' = 'count', '돌려받은 횟수권으로 예약');
reset role; set role authenticated;
select test.ok((public.admin_reserve('2027-06-02', 13, '둘다회원', :dd_uid, true, false))->>'msg' like '정액권 하루 이용 횟수(1회)와 횟수권 2회를 모두 사용했습니다. 이용자 현황%', '관리자 일반예약: 둘 다 다 쓰면 막힘');
select test.ok((public.admin_reserve('2027-06-02', 13, '둘다회원', :dd_uid, true, true))->>'ok' = 'true', '슈퍼패스는 그대로');
-- 수정: 기존 두 상품 수정 + 같은 종류 새로 추가 막힘
select test.ok((public.admin_update_user(jsonb_build_object('id', :dd_uid, 'type','ext','name','둘다회원','phone','01011110000',
   'prods', jsonb_build_array(jsonb_build_object('id', :dd_fp, 'start','2027-06-01','days',30,'limit',2),
                              jsonb_build_object('id', :dd_cp, 'start','2027-06-01','days',30,'total',5)))))->>'ok' = 'true', '두 상품 함께 수정');
reset role;
select test.ok((select daily_limit from public.products where id = :dd_fp) = 2 and (select total_count from public.products where id = :dd_cp) = 5, '수정 값 저장됨');
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :dd_uid, 'type','ext','name','둘다회원','phone','01011110000',
   'prods', jsonb_build_array(jsonb_build_object('kind','flat','start','2027-06-05','days',30,'limit',1)))))->>'msg' like '이미 사용 중이거나 시작 예정인 정액권%', '같은 종류 새 상품은 막힘');
select test.ok((public.admin_update_user(jsonb_build_object('id', :dd_uid, 'type','ext','name','둘다회원','phone','01011110000',
   'prods', jsonb_build_array(jsonb_build_object('id', :dd_cp, 'start','2027-06-01','days',30,'total',1)))))->>'msg' like '이미 2회 사용했습니다%', '횟수권 총 횟수는 쓴 횟수 이상');
-- 한 종류만 있는 이용자에게 다른 종류 추가
select test.ok((public.admin_create_user('{"type":"stu","name":"하나생","pw":"2222","prod":{"kind":"flat","start":"2027-06-01","days":30,"limit":1}}'))->>'ok' = 'true', '재원생 정액권만 등록(예전 형식)');
reset role;
select id as hn_uid from public.users where name = '하나생' \gset
set role authenticated;
select test.ok((public.admin_update_user(jsonb_build_object('id', :hn_uid, 'type','stu','name','하나생','phone','',
   'prods', jsonb_build_array(jsonb_build_object('kind','count','start','2027-06-01','days',30,'total',3)))))->>'ok' = 'true', '정액권 쓰는 재원생에게 횟수권 추가');
select test.ok((public.admin_update_user(jsonb_build_object('id', :hn_uid, 'type','stu','name','하나생','phone','',
   'new_prod', jsonb_build_object('kind','count','start','2027-06-01','days',30,'total',3))))->>'ok' = 'true', '예전 형식 new_prod는 상품 있으면 무시(그대로 저장)');
reset role;
select test.ok((select count(*) from public.products where user_id = :hn_uid) = 2, '하나생 상품 2개');
set role anon;
select test.ok((public.reserve('2027-06-01', 14, '하나생', '2222', true, 'stu', 'count'))->>'prod' = 'count', '재원생 횟수권을 골라 예약');
select test.ok((public.reserve('2027-06-01', 15, '하나생', '2222', true, 'stu'))->>'choose' = 'true', '재원생도 둘 다 남아 있으면 고르라고 함');
select test.ok((public.reserve('2027-06-01', 15, '하나생', '2222', true, 'stu', 'flat'))->>'prod' = 'flat', '재원생 정액권을 골라 같은 날 두 번째 예약');
reset role; reset app.fake_now;

-- 38. 035: 홈 안내 창 글(관리자 변경·공개 조회)
reset role; set app.fake_now = '2027-06-10 08:00';
set role anon;
select test.ok((public.info_pages())->'pages' = '{}'::jsonb, '처음에는 저장한 안내 글 없음');
select test.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'admin_set_info_page' and has_function_privilege('anon', p.oid, 'execute')), '익명은 안내 글 저장 불가');
reset role; set role authenticated;
select test.ok((public.admin_set_info_page('way', '[{"t":"주차","b":"건물 뒤 주차장"},{"t":"","b":""}]'))->'pages'->'way'->'sections'->0->>'b' = '건물 뒤 주차장', '안내 글 저장');
select test.ok(jsonb_array_length((public.info_pages())->'pages'->'way'->'sections') = 1, '빈 칸은 버림');
select test.ok((public.info_pages())->'pages'->'way'->>'updated_at' = '2027-06-10', '수정 날짜');
select test.ok((public.admin_set_info_page('bad', '[{"t":"x","b":"y"}]'))->>'msg' = '잘못된 안내 창입니다.', '없는 창은 막힘');
select test.ok((public.admin_set_info_page('room', '[{"t":"","b":""}]'))->>'msg' like '내용을 한 칸 이상%', '모두 빈 칸이면 막힘');
select test.ok((public.admin_set_info_page('room', jsonb_build_array(jsonb_build_object('t', repeat('가', 61), 'b', 'x'))))->>'msg' like '칸 제목은 60자%', '제목 60자 제한');
select test.ok((public.admin_set_info_page('room', jsonb_build_array(jsonb_build_object('t', 'x', 'b', repeat('가', 3001)))))->>'msg' like '칸 하나의 내용은 3000자%', '내용 3000자 제한');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"드럼 1대"}]'))->'pages' ? 'way', '다른 창 저장해도 앞의 창 유지');
select test.ok(not ((public.admin_set_info_page('way', null))->'pages' ? 'way'), '기본 글로 되돌리기');
reset role; set role anon;
select test.ok((public.info_pages())->'pages'->'room'->'sections'->0->>'t' = '장비', '공개 조회에 저장한 글');
reset role; reset app.fake_now;

-- 39. 036: 안내 창 사진(Storage 공개 버킷, 관리자만 올리기)
reset role;
select test.ok((select public from storage.buckets where id = 'info-photos'), '사진 버킷은 공개');
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
insert into storage.objects (bucket_id, name) values ('info-photos', 'room/1-a.jpg');
select test.ok(true, '관리자는 사진 올리기 가능');
select test.denied($q$insert into storage.objects (bucket_id, name) values ('other', 'x.jpg')$q$, '관리자도 다른 버킷에는 못 올림');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000b"}';
set role authenticated;
select test.denied($q$insert into storage.objects (bucket_id, name) values ('info-photos', 'room/2-b.jpg')$q$, '관리자가 아닌 로그인 계정은 사진 못 올림');
reset role; set role anon;
select test.denied($q$insert into storage.objects (bucket_id, name) values ('info-photos', 'room/3-c.jpg')$q$, '익명은 사진 못 올림');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"드럼","imgs":["room/1-a.jpg","room/2-b_c.png"]}]'))->'pages'->'room'->'sections'->0->'imgs'->>1 = 'room/2-b_c.png', '칸에 사진 저장');
select test.ok((public.admin_set_info_page('room', '[{"t":"","b":"","imgs":["room/1-a.jpg"]}]'))->'pages'->'room'->'sections'->0->'imgs'->>0 = 'room/1-a.jpg', '사진만 있는 칸도 저장');
select test.ok((public.admin_set_info_page('room', '[{"t":"x","b":"y","imgs":["https://evil.example/a.jpg"]}]'))->>'msg' like '사진 정보가 올바르지%', '다른 주소는 못 넣음');
select test.ok((public.admin_set_info_page('room', '[{"t":"x","b":"y","imgs":["way/1-a.jpg"]}]'))->>'msg' like '사진 정보가 올바르지%', '다른 창 폴더 사진은 못 넣음');
select test.ok(jsonb_array_length((public.admin_set_info_page('room', '[{"t":"x","b":"y","imgs":["room/1.jpg","room/2.jpg","room/3.jpg","room/4.jpg","room/5.jpg","room/6.jpg","room/7.jpg"]}]'))->'pages'->'room'->'sections'->0->'imgs') = 7, '040: 사진 7장 이상도 저장');
select test.ok((public.admin_set_info_page('room', jsonb_build_array(jsonb_build_object('t','x','b','y','imgs',(select jsonb_agg('room/'||g||'.jpg') from generate_series(1,101) g)))))->>'msg' like '사진은 칸 하나에 100장%', '040: 안전 한도 100장');
select test.ok(not ((public.admin_set_info_page('room', '[{"t":"x","b":"y"}]'))->'pages'->'room'->'sections'->0 ? 'imgs'), '사진 없는 칸에는 imgs 없음');
reset role; reset request.jwt.claims;

-- 40. 037: 이용료 보기 설명(price)도 안내 글로 저장
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_set_info_page('price', '[{"t":"정액권","b":"매일 채워짐","imgs":["price/1-a.jpg"]}]'))->'pages'->'price'->'sections'->0->>'t' = '정액권', '이용료 설명(price) 저장');
select test.ok((public.admin_set_info_page('price', '[{"t":"x","b":"y","imgs":["room/1-a.jpg"]}]'))->>'msg' like '사진 정보가 올바르지%', 'price 창은 price 폴더 사진만');
reset role; set role anon;
select test.ok((public.info_pages())->'pages'->'price'->'sections'->0->>'b' = '매일 채워짐', '공개 조회에 이용료 설명');
reset role; reset request.jwt.claims;

-- 41. 038·039·041: 사진 배치(041부터 사진마다 lay, 칸 전체 size·cols로 보내도 사진마다 바꿔 저장)
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1-a.jpg","room/2-b.jpg"],"size":"s"}]'))->'pages'->'room'->'sections'->0->'lay' = '["1s","1s"]'::jsonb, '옛 방식 작게 → 사진마다 1s');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1-a.jpg"],"cols":"3"}]'))->'pages'->'room'->'sections'->0->'lay' = '["3"]'::jsonb, '옛 방식 3장 → 사진마다 3');
select test.ok(not ((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1-a.jpg"],"size":"l"}]'))->'pages'->'room'->'sections'->0 ? 'lay'), '모두 기본(1l)이면 lay 저장 안 함');
select test.ok(not ((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1-a.jpg"],"size":"m"}]'))->'pages'->'room'->'sections'->0 ? 'size'), '칸 전체 size는 더 저장 안 함');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1-a.jpg"],"size":"xl"}]'))->>'msg' like '사진 크기를%', '잘못된 크기는 막힘');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1-a.jpg"],"cols":4}]'))->>'msg' like '한 줄 사진 수를%', '한 줄 4장은 막힘');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1.jpg","room/2.jpg","room/3.jpg","room/4.jpg"],"lay":["1l","2","2","1m"]}]'))->'pages'->'room'->'sections'->0->'lay' = '["1l","2","2","1m"]'::jsonb, '041: 사진마다 배치(2·3번만 한 줄 2장)');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1.jpg","room/2.jpg"],"lay":["2"]}]'))->>'msg' like '사진 배치 정보가 올바르지%', '041: 배치 수가 사진 수와 다르면 막힘');
select test.ok((public.admin_set_info_page('room', '[{"t":"장비","b":"x","imgs":["room/1.jpg"],"lay":["4"]}]'))->>'msg' like '사진 배치를 다시%', '041: 없는 배치 값은 막힘');
reset role;
-- 039 모양의 옛 자료를 넣고 041의 변환 부분만 다시 실행해 보기
update public.settings set value = '{"way":{"sections":[{"t":"a","b":"","imgs":["way/1-a.jpg","way/1-b.jpg"],"cols":2},{"t":"b","b":"","imgs":["way/2-b.jpg"],"size":"m"},{"t":"c","b":"x"},{"t":"d","b":"","imgs":["way/3.jpg"],"size":"l"}],"updated_at":"2026-11-04"}}' where key = 'info_pages';
\i supabase/tests/041_convert_only.sql
select test.ok((select value->'way'->'sections'->0 from public.settings where key = 'info_pages') = '{"t":"a","b":"","imgs":["way/1-a.jpg","way/1-b.jpg"],"lay":["2","2"]}'::jsonb, '041 변환: 칸 2장 → 사진마다 2');
select test.ok((select value->'way'->'sections'->1->'lay' from public.settings where key = 'info_pages') = '["1m"]'::jsonb, '041 변환: 보통 → 1m');
select test.ok((select value->'way'->'sections'->2 from public.settings where key = 'info_pages') = '{"t":"c","b":"x"}'::jsonb and (select value->'way'->'sections'->3 from public.settings where key = 'info_pages') = '{"t":"d","b":"","imgs":["way/3.jpg"]}'::jsonb, '041 변환: 사진 없는 칸·기본값 칸 정리');
reset request.jwt.claims;

-- 42. 042: 문의 가능 시간(요일별 시작·끝, 지금 문의 가능한지 서버가 판단)
reset role;
set app.fake_now = '2026-11-02 10:00';  -- 월요일 10시
set role anon;
select test.ok((public.contact_info())->'hours'->'days'->0->>'start' = '09:00', '처음 값 매일 09:00~22:00');
select test.ok(((public.contact_info())->>'open')::boolean, '처음 값: 월 10시는 문의 가능');
select test.denied('select public.admin_set_contact_hours(''{}'')', '익명은 문의 시간 저장 불가');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_set_contact_hours('{"days":[{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"13:00","end":"18:30"},{"on":false}],"memo":"공휴일 휴무"}'))->'hours'->>'memo' = '공휴일 휴무', '문의 시간 저장');
select test.ok((public.admin_set_contact_hours('{"days":[{"on":true,"start":"10:00","end":"09:00"},{"on":false},{"on":false},{"on":false},{"on":false},{"on":false},{"on":false}]}'))->>'msg' = '월요일 끝 시각은 시작 시각보다 늦어야 합니다.', '끝이 시작보다 이르면 막힘');
select test.ok((public.admin_set_contact_hours('{"days":[{"on":true,"start":"10:15","end":"21:00"},{"on":false},{"on":false},{"on":false},{"on":false},{"on":false},{"on":false}]}'))->>'msg' = '월요일 시각을 다시 고르십시오.', '30분 단위가 아니면 막힘');
select test.ok((public.admin_set_contact_hours('{"days":[]}'))->>'msg' = '잘못된 요청입니다.', '요일 7개가 아니면 막힘');
reset role; reset request.jwt.claims;
set app.fake_now = '2026-11-02 09:59'; set role anon;
select test.ok(not ((public.contact_info())->>'open')::boolean, '월 09:59는 문의 시간 아님');
reset role; set app.fake_now = '2026-11-02 20:59'; set role anon;
select test.ok(((public.contact_info())->>'open')::boolean, '월 20:59는 문의 가능');
reset role; set app.fake_now = '2026-11-02 21:00'; set role anon;
select test.ok(not ((public.contact_info())->>'open')::boolean, '월 21:00(끝 시각)은 문의 시간 아님');
reset role; set app.fake_now = '2026-11-07 18:00'; set role anon;
select test.ok(((public.contact_info())->>'open')::boolean, '토 18:00은 문의 가능(13:00~18:30)');
reset role; set app.fake_now = '2026-11-08 12:00'; set role anon;
select test.ok(not ((public.contact_info())->>'open')::boolean, '일요일(문의 안 받음)은 문의 시간 아님');
select test.ok((public.contact_info())->'hours'->>'updated_at' is not null, '저장 날짜가 남음');
reset role; reset app.fake_now;

-- 43. 043: 문의 안 받는 기간(예외)
reset role; set app.fake_now = '2026-11-02 10:00';  -- 월 10시(위에서 월~금 10:00~21:00 저장됨)
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
set role authenticated;
select test.ok((public.admin_add_contact_off('2026-11-03 09:00', '2026-11-05 00:00', '휴가'))->'hours'->'off'->0->>'reason' = '휴가', '예외 추가');
select test.ok((public.admin_add_contact_off('2026-11-03 09:00', '2026-11-03 08:00', ''))->>'msg' = '끝 날짜·시각은 시작보다 늦어야 합니다.', '끝이 시작보다 이르면 막힘');
select test.ok((public.admin_add_contact_off('2026-11-01 09:00', '2026-11-01 12:00', ''))->>'msg' = '이미 지난 기간입니다.', '지난 기간은 막힘');
select test.ok((public.admin_add_contact_off('2026-11-03 9:00', '2026-11-04 12:00', ''))->>'msg' = '날짜와 시각을 다시 고르십시오.', '형식이 틀리면 막힘');
select test.ok(jsonb_array_length((public.admin_set_contact_hours('{"days":[{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"10:00","end":"21:00"},{"on":true,"start":"13:00","end":"18:30"},{"on":false}],"memo":"공휴일 휴무"}'))->'hours'->'off') = 1, '요일 시간을 저장해도 예외는 남음');
reset role; reset request.jwt.claims; set role anon;
select test.denied('select public.admin_add_contact_off(''2026-11-03 09:00'',''2026-11-04 09:00'',''x'')', '익명은 예외 추가 불가');
select test.ok(((public.contact_info())->>'open')::boolean and (public.contact_info())->'off_now' = 'null'::jsonb, '예외 전(월 10시)은 문의 가능');
reset role; set app.fake_now = '2026-11-04 12:00'; set role anon;
select test.ok(not ((public.contact_info())->>'open')::boolean and (public.contact_info())->'off_now'->>'reason' = '휴가', '예외 중(수 12시)은 문의 불가 + 사유');
reset role; set app.fake_now = '2026-11-05 10:00'; set role anon;
select test.ok(((public.contact_info())->>'open')::boolean and jsonb_array_length((public.contact_info())->'hours'->'off') = 0, '예외 끝난 뒤(목 10시)는 다시 문의 가능, 끝난 예외는 안 보임');
reset role; set app.fake_now = '2026-11-02 10:00';
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}';
select value->'off'->0->>'id' as off_id from public.settings where key = 'contact_hours' \gset
set role authenticated;
select test.ok(jsonb_array_length((public.admin_del_contact_off(:'off_id'))->'hours'->'off') = 0, '예외 삭제');
reset role; reset request.jwt.claims; reset app.fake_now;

select '모든 시험 통과' as 결과;
