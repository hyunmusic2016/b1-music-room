-- 로컬 시험: 048(정액권 없애기 + "횟수권" → "이용권")을 01 시험이 남긴 자료 위에 실행한 뒤 확인합니다.
-- (Supabase에서는 실행하지 않음) 마지막에 "모든 시험 통과(048)"가 나오면 성공입니다.
\set ON_ERROR_STOP 1
\set QUIET 1

-- 1. 남아 있던 정액권 정리(실제 오늘 기준)
select test.ok((select count(*) from public.products where kind = 'flat' and end_date >= public.app_today()) = 0,
               '사용 중·시작 예정 정액권이 남지 않음');
select test.ok(exists (select 1 from public.products where kind = 'flat' and end_date = public.app_today() - 1),
               '이미 시작한 정액권은 어제 날짜로 종료되어 기록으로 남음');
select test.ok(exists (select 1 from public.reservations where product_kind = 'flat' and status = 'confirmed'),
               '정액권으로 잡힌 확정 예약은 취소되지 않고 그대로');
select test.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.prosrc like '%횟수권%') = 0, '서버 함수에 "횟수권" 글자가 남지 않음');

-- 2. 이용료 표에 정액권 칸 없음
set role anon;
select test.ok(not ((public.price_info()) ? 'ext_flat') and not ((public.price_info()) ? 'stu_flat'), '공개 이용료 표에 정액권 칸 없음');
select test.ok((public.price_info()) ? 'ext_count' and (public.price_info()) ? 'stu_count', '이용권 칸은 그대로');
select test.denied('select public.admin_set_prices(''{}'')', '익명은 이용료 저장 불가(권한 유지)');
reset role;

set app.fake_now = '2028-03-02 10:00';
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok(not ((public.admin_set_prices('{"fee":"7000","ext_flat":[{"n":"1","price":"100000"}],"ext_count":[{"n":"10","price":"60000"}]}')) ? 'ext_flat'),
               '정액권 가격을 보내도 저장되지 않음');
select test.ok((public.price_info())->'ext_count'->0->>'price' = '60000', '이용권 가격은 저장됨');
select test.ok((public.admin_set_prices('{"ext_count":[{"n":"","price":"5000"}]}'))->>'msg' like '일반회원 이용권 1번째 줄%', '서버 오류 문구도 "이용권"');

-- 3. 정액권 등록은 막힘, 이용권은 됨
select test.ok((public.admin_create_user('{"type":"ext","name":"정액시도","pw":"4811","phone":"01048110000","prods":[{"kind":"flat","start":"2028-03-02","days":30,"limit":1}]}'))->>'msg' = '이용권만 등록할 수 있습니다.',
               '새 정액권 등록은 막힘(prods 형식)');
select test.ok((public.admin_create_user('{"type":"stu","name":"정액시도","pw":"4812","prod":{"kind":"flat","start":"2028-03-02","days":30,"limit":1}}'))->>'msg' = '이용권만 등록할 수 있습니다.',
               '새 정액권 등록은 막힘(예전 형식)');
select (public.admin_create_user('{"type":"ext","name":"이용권회원","pw":"4813","phone":"01048130000","prods":[{"kind":"count","start":"2028-03-02","days":30,"total":1}]}'))->'user'->>'id' as ip_uid \gset
select test.ok(:ip_uid > 0, '이용권 등록은 됨');
select test.ok((public.admin_update_user(jsonb_build_object('id', :ip_uid, 'type', 'ext', 'name', '이용권회원', 'phone', '01048130000',
                 'prods', '[{"kind":"flat","start":"2028-03-02","days":30,"limit":2}]'::jsonb)))->>'ok' is distinct from 'true',
               '이용자 수정에서도 정액권 추가는 막힘');
reset role; reset request.jwt.claims;

-- 4. 예약 문구가 "이용권"
set role anon;
select test.ok((public.reserve('2028-03-02', 11, '이용권회원', '4813', true, 'ext'))->>'ok' = 'true', '이용권 예약 성공');
select test.ok((public.reserve('2028-03-02', 12, '이용권회원', '4813', true, 'ext'))->>'msg' like '이용권 1시간을 모두 사용했습니다.%', '다 쓰면 "이용권 1시간을 모두 사용했습니다."(049)');
select test.ok((public.product_info('ext', '이용권회원', '4813'))->'products'->0->>'kind' = 'count', '예약 창 상품 조회 그대로(익명 호출 가능, 이용권 보임)');
reset role; reset app.fake_now;

-- 049: "회·횟수" → "시간" 문구
select test.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') like '%횟수%') = 0, '서버 문구에 "횟수"가 남지 않음(049)');
set app.fake_now = '2028-03-02 10:00'; set role anon;
select test.ok((public.reserve('2028-03-02', 13, '시간학생', '4901', true, 'stu'))->>'ok' = 'true', '재원생 예약');
select test.ok((public.reserve('2028-03-02', 15, '시간학생', '4901', true, 'stu'))->>'msg' like '하루 1시간만 예약할 수 있습니다.%', '재원생 두 번째는 "하루 1시간만 예약할 수 있습니다."(049)');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"10시간","price":"60000"}]}'))->'ext_count'->0->>'n' = '10', '이용료 표에 "10시간"이라고 써도 숫자 10으로 저장(049)');
select test.ok((public.admin_set_prices('{"ext_count":[{"n":"abc","price":"5000"}]}'))->>'msg' like '%번째 줄: 시간을 1~999%', '이용료 표 오류 문구 "시간을"(049)');
reset role; reset request.jwt.claims; reset app.fake_now;
select '모든 시험 통과(048·049)' as 결과;
