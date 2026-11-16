-- 로컬 시험: 060(이용권이 있는 재원생도 하루 1시간 무료) — Supabase에서는 실행하지 않음.
-- 마지막에 "모든 시험 통과(060)"가 나오면 성공입니다.
\set ON_ERROR_STOP 1
\set QUIET 1
update public.settings set value = jsonb_set(value, '{check}', 'false') where key = 'roster';
set app.fake_now = '2028-04-10 10:00';
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select (public.admin_create_user('{"type":"stu","name":"무료학생","pw":"6001","prods":[{"kind":"count","start":"2028-04-10","days":30,"total":2}]}'))->'user'->>'id' as fu \gset
select (public.admin_create_user('{"type":"stu","name":"보통학생","pw":"6002"}'))->'user'->>'id' as nu \gset
select (public.admin_create_user('{"type":"ext","name":"무료외부","pw":"6003","phone":"01060030000","prods":[{"kind":"count","start":"2028-04-10","days":30,"total":5}]}'))->'user'->>'id' as eu \gset
reset role; reset request.jwt.claims;
select id as fp from public.products where user_id = :fu \gset

-- 1. 이용권 재원생: 첫 1시간 무료, 2시간째부터 이용권
set role anon;
select test.ok((public.product_info('stu', '무료학생', '6001'))->'free'->>'2028-04-10' = 'true', '예약 전: 오늘 무료 남음');
select public.reserve('2028-04-10', 11, '무료학생', '6001', true, 'stu') as r \gset
select test.ok((:'r'::jsonb)->>'free' = 'true' and (:'r'::jsonb)->>'free_pass' = 'true' and (:'r'::jsonb)->>'prod' is null, '첫 예약은 무료(이용권 있음 표시)');
select (:'r'::jsonb)->>'id' as r11 \gset
reset role;
select test.ok(public.product_used(:fp) = 0, '첫 예약은 이용권 차감 없음');
set role anon;
select test.ok((public.product_info('stu', '무료학생', '6001'))->'free'->>'2028-04-10' = 'false', '예약 뒤: 오늘 무료 사용함');
select public.reserve('2028-04-10', 12, '무료학생', '6001', true, 'stu') as r \gset
select test.ok((:'r'::jsonb)->>'prod' = 'count' and (:'r'::jsonb)->>'free' = 'false', '두 번째는 이용권');
select (:'r'::jsonb)->>'id' as r12 \gset
select test.ok((public.reserve('2028-04-10', 13, '무료학생', '6001', true, 'stu'))->>'prod' = 'count', '세 번째도 이용권');
select test.ok((public.reserve('2028-04-10', 14, '무료학생', '6001', true, 'stu'))->>'msg' like '이용권 2시간을 모두 사용했습니다.%', '이용권 다 쓰면 막음');
-- 이용권을 다 써도 다른 날 첫 1시간은 무료
select public.reserve('2028-04-11', 11, '무료학생', '6001', true, 'stu') as r \gset
select test.ok((:'r'::jsonb)->>'free' = 'true', '이용권 다 써도 내일 첫 1시간은 무료');
select (:'r'::jsonb)->>'id' as t11 \gset
select test.ok((public.reserve('2028-04-11', 12, '무료학생', '6001', true, 'stu'))->>'msg' like '이용권 2시간을 모두 사용했습니다.%', '내일 두 번째는 막음(이용권 다 씀)');
reset role;
select test.ok(public.product_used(:fp) = 2, '이용권 2시간 사용');

-- 2. ① 무료 예약을 취소하면 그날 가장 이른 이용권 예약이 무료로, 1시간 돌려받음
set role anon;
select test.ok((public.cancel_own(:r11, '무료학생', '6001'))->>'ok' = 'true', '무료 예약 취소');
reset role;
select test.ok((select product_id is null from public.reservations where id = :r12), '12시 예약이 무료로 바뀜');
select test.ok(public.product_used(:fp) = 1, '이용권 1시간 돌려받음');
set role anon;
select test.ok((public.reserve('2028-04-10', 14, '무료학생', '6001', true, 'stu'))->>'prod' = 'count', '돌려받은 1시간으로 다시 예약');
reset role;
select test.ok(public.product_used(:fp) = 2, '다시 2시간 사용');

-- 3. ② 시간 변경: 옮길 날짜 기준으로 다시 계산
set role anon;
select test.ok((public.move_own(:t11, '무료학생', '6001', '2028-04-10', 16))->>'msg' like '이용권 2시간을 모두 사용했습니다.%', '무료가 있는 날로 옮기면 이용권 필요 → 다 써서 막힘');
select test.ok((public.move_own(:r12, '무료학생', '6001', '2028-04-10', 17))->>'free' = 'true', '같은 날 무료 예약 시간 변경은 무료 그대로');
reset role;
select id as r13 from public.reservations where user_id = :fu and date = '2028-04-10' and hour = 13 and status = 'confirmed' \gset
set role anon;
select test.ok((public.cancel_own(:t11, '무료학생', '6001'))->>'ok' = 'true', '내일 무료 예약 취소');
select public.move_own(:r13, '무료학생', '6001', '2028-04-11', 13) as m \gset
select test.ok((:'m'::jsonb)->>'free' = 'true' and (:'m'::jsonb)->>'prod' is null, '이용권 예약을 무료가 빈 날로 옮기면 무료');
reset role;
select test.ok(public.product_used(:fp) = 1, '옮겨서 무료가 되면 이용권 1시간 돌려받음');
set role anon;
select test.ok((public.reserve('2028-04-11', 15, '무료학생', '6001', true, 'stu'))->>'prod' = 'count', '내일 두 번째는 이용권');
reset role;
select id as t15 from public.reservations where user_id = :fu and date = '2028-04-11' and hour = 15 and status = 'confirmed' \gset
set role anon;
select test.ok((public.move_own(:t15, '무료학생', '6001', '2028-04-10', 20))->>'prod' = 'count', '이용권 예약을 무료가 있는 날로 옮기면 이용권 그대로');
reset role;
select test.ok(public.product_used(:fp) = 2, '이용권 그대로 옮기면 시간 변화 없음');
-- 무료 예약을 다른 날로 옮겨 원래 날의 무료가 비면 그날 이용권 예약이 무료로
select id as d17 from public.reservations where user_id = :fu and date = '2028-04-10' and hour = 17 and status = 'confirmed' \gset
select id as t13 from public.reservations where user_id = :fu and date = '2028-04-11' and hour = 13 and status = 'confirmed' \gset
set role anon;
select test.ok((public.cancel_own(:t13, '무료학생', '6001'))->>'ok' = 'true', '내일 무료 예약 취소(정리)');
select public.move_own(:d17, '무료학생', '6001', '2028-04-11', 9) as m \gset
select test.ok((:'m'::jsonb)->>'free' = 'true', '무료 예약을 무료가 빈 날로 옮김');
reset role;
select test.ok((select count(*) from public.reservations where user_id = :fu and date = '2028-04-10' and status = 'confirmed' and product_id is null) = 1,
               '원래 날짜의 이용권 예약 하나가 무료로 바뀜');
select test.ok((select hour from public.reservations where user_id = :fu and date = '2028-04-10' and status = 'confirmed' and product_id is null) = 14,
               '가장 이른 이용권 예약(14시)이 무료로');

-- 4. 관리자 일반예약도 같은 규칙, 슈퍼패스는 무료 1시간으로 안 셈(④)
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_reserve('2028-04-11', 20, '보통학생', :nu, false, true))->>'super' = 'true', '보통학생 슈퍼패스 예약');
select test.ok((public.admin_find_users('보통학생', '2028-04-11'))->'users'->0->>'day_taken' = 'false', '슈퍼패스는 무료 1시간으로 안 셈');
select public.admin_reserve('2028-04-11', 21, '보통학생', :nu, false, false) as a \gset
select test.ok((:'a'::jsonb)->>'free' = 'true' and (:'a'::jsonb)->>'free_pass' = 'false', '슈퍼패스가 있어도 일반예약 무료 1시간 가능(이용권 없음)');
select test.ok((public.admin_reserve('2028-04-11', 22, '보통학생', :nu, false, false))->>'msg' like '제휴회원은 하루 1시간만%', '이용권 없는 재원생 두 번째는 막음');
reset role; reset request.jwt.claims;
set role anon;
select test.ok((public.reserve('2028-04-11', 23, '보통학생', '6002', true, 'stu'))->>'msg' like '하루 1시간만 예약할 수 있습니다.%', '손님 예약도 두 번째는 막음');
-- 일반회원은 그대로(첫 예약부터 이용권)
select test.ok((public.reserve('2028-04-11', 5, '무료외부', '6003', true, 'ext'))->>'prod' = 'count', '일반회원은 첫 예약부터 이용권');
select test.ok((public.product_info('ext', '무료외부', '6003'))->'free' = 'null'::jsonb, '일반회원에게는 무료 정보 없음');
reset role;

-- 5. ③ SQL 실행 때 이미 잡힌 예약 바꾸기(060을 다시 실행해도 같은지 함께 확인)
alter table public.reservations disable trigger reservations_stu_rebalance;
update public.reservations set product_id = :fp, product_kind = 'count'
 where user_id = :fu and date = '2028-04-10' and status = 'confirmed' and product_id is null;
alter table public.reservations enable trigger reservations_stu_rebalance;
select test.ok(not public.stu_day_taken('2028-04-10', :fu, null), '시험 준비: 무료가 없는 날 만듦');
\i supabase/migrations/060_stu_daily_free.sql
select test.ok(public.stu_day_taken('2028-04-10', :fu, null), '060 실행 때 무료가 없는 날의 이용권 예약을 무료로');
select test.ok((select hour from public.reservations where user_id = :fu and date = '2028-04-10' and status = 'confirmed' and product_id is null) = 14, '가장 이른 예약(14시)이 무료로');
-- 지난 날짜는 손대지 않음
set app.fake_now = '2028-04-12 10:00';
alter table public.reservations disable trigger reservations_stu_rebalance;
update public.reservations set product_id = :fp, product_kind = 'count' where user_id = :fu and date = '2028-04-10' and product_id is null and status = 'confirmed';
alter table public.reservations enable trigger reservations_stu_rebalance;
select public.stu_rebalance('2028-04-10', :fu);
select test.ok(not public.stu_day_taken('2028-04-10', :fu, null), '지난 날짜 예약은 바꾸지 않음');
reset app.fake_now;

-- 6. 권한
select test.ok(not has_function_privilege('anon', 'public.stu_rebalance(date, bigint)', 'execute'), '익명은 stu_rebalance 실행 못 함');
select test.ok(not has_function_privilege('authenticated', 'public.stu_rebalance(date, bigint)', 'execute'), '로그인 사용자도 stu_rebalance 직접 실행 못 함');
select test.ok(has_function_privilege('anon', 'public.reserve(date, integer, text, text, boolean, text, text)', 'execute'), '익명 예약 권한 유지');
select test.ok(has_function_privilege('anon', 'public.move_own(bigint, text, text, date, integer)', 'execute'), '익명 시간 변경 권한 유지');
select test.ok(not has_function_privilege('anon', 'public.admin_reserve(date, integer, text, bigint, boolean, boolean, text, text)', 'execute'), '익명은 관리자 예약 못 함');
-- 061: 서버 문구 "재원생" → "제휴회원"(060 다음에 실행)
insert into public.settings (key, value) values ('lobby_info', '{"boxes":[{"id":"a","title":"재원생 안내","body":"재원생은 하루 1시간"}]}')
  on conflict (key) do update set value = excluded.value;
\i supabase/migrations/061_partner_wording.sql
select test.ok((select value->'boxes'->0->>'body' from public.settings where key = 'lobby_info') = '제휴회원은 하루 1시간', '저장된 로비 글도 바뀜(061)');
select test.ok((select count(*) from public.settings where value::text like '%재원생%') = 0, '저장된 글에 "재원생" 없음(061)');
select test.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.prosrc like '%재원생%') = 0, '서버 함수에 "재원생" 글자가 남지 않음(061)');
select test.ok(has_function_privilege('anon', 'public.reserve(date, integer, text, text, boolean, text, text)', 'execute')
               and not has_function_privilege('anon', 'public.admin_reserve(date, integer, text, bigint, boolean, boolean, text, text)', 'execute'), '061 뒤에도 권한 그대로');
select '모든 시험 통과(060~061)' as 결과;
