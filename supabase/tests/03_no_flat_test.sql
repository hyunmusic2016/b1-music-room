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
                 where n.nspname = 'public' and replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '시도 횟수', '') like '%횟수%') = 0, '서버 문구에 이용 "횟수"가 남지 않음(049, 비밀번호 시도 횟수는 그대로)');
select test.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.prosrc like '%비밀번호를 여러 번 잘못%') = 0, '비밀번호 잠금 문구는 원래 "시도 횟수를 초과했습니다."(050)');
set app.fake_now = '2028-03-02 10:00'; set role anon;
select test.ok((public.reserve('2028-03-02', 13, '시간학생', '4901', true, 'stu'))->>'ok' = 'true', '재원생 예약');
select test.ok((public.reserve('2028-03-02', 15, '시간학생', '4901', true, 'stu'))->>'msg' like '하루 1시간만 예약할 수 있습니다.%', '재원생 두 번째는 "하루 1시간만 예약할 수 있습니다."(049)');
reset role;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"10시간","price":"60000"}]}'))->'ext_count'->0->>'n' = '10', '이용료 표에 "10시간"이라고 써도 숫자 10으로 저장(049)');
select test.ok((public.admin_set_prices('{"ext_count":[{"n":"abc","price":"5000"}]}'))->>'msg' like '%번째 줄: 시간을 1~999%', '이용료 표 오류 문구 "시간을"(049)');
reset role; reset request.jwt.claims; reset app.fake_now;

-- 051: 이용권 기간(pass_days)
select test.ok((public.price_info())->>'pass_days' = '30', '이용권 기간 처음 값 30(051)');
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"10","price":"60000"}],"pass_days":"60일"}'))->>'pass_days' = '60', '이용권 기간 60일 저장("일"을 붙여도 숫자로)(051)');
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"10","price":"60000"}]}'))->>'pass_days' = '60', '기간을 보내지 않으면 그대로(051)');
select test.ok((public.admin_set_prices('{"fee":"7000","pass_days":"0"}'))->>'msg' like '이용권 기간은 1~999%', '0일은 막음(051)');
select test.ok((public.admin_set_prices('{"fee":"7000","pass_days":"abc"}'))->>'msg' like '이용권 기간은 1~999%', '숫자 아닌 값은 막음(051)');
reset role; update public.settings set value = jsonb_set(value, '{updated_at}', '"2000-01-01"') where key = 'price_list'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"10","price":"60000"}],"pass_days":"60"}'))->>'updated_at' = '2000-01-01', '기간이 같으면 수정 날짜 그대로(051)');
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"10","price":"60000"}],"pass_days":"45"}'))->>'updated_at' <> '2000-01-01', '기간을 바꾸면 수정 날짜 오늘(051)');
reset role; reset request.jwt.claims;
set role anon;
select test.ok((public.price_info())->>'pass_days' = '45', '공개 조회에 이용권 기간(051)');
reset role;
select test.ok(not has_function_privilege('anon', 'public.admin_set_prices(jsonb)', 'execute'), '익명은 저장 함수를 못 부름(051)');
reset role;

-- 052: 명부 목록
create temp table t052 as select count(*) n from public.roster; grant select on t052 to authenticated;
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_roster_list())->>'ok' = 'true', '관리자는 명부 목록을 봄(052)');
select test.ok(jsonb_array_length((public.admin_roster_list())->'rows') = (select n from t052) and (select n from t052) > 0, '명부 인원만큼 줄(052)');
select test.ok(not ((public.admin_roster_list())::text like '%pw_hash%' or (public.admin_roster_list())::text like '%$2a$%'), '뒤 4자리(암호화 값)는 주지 않음(052)');
select test.ok(exists (select 1 from jsonb_array_elements((public.admin_roster_list())->'rows') e where e->>'user_id' is not null), '연결된 이용자 번호가 옴(052)');
reset role; reset request.jwt.claims;
select test.ok(not has_function_privilege('anon', 'public.admin_roster_list()', 'execute'), '익명은 명부 목록 함수를 못 부름(052)');

-- 053: 안내 글 칸 숨기기
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_set_info_page('room', '[{"t":"보임","b":"가"},{"t":"숨김","b":"나","hide":true}]'::jsonb))->>'ok' = 'true', '숨긴 칸 저장(053)');
select test.ok(((public.info_pages())->'pages'->'room'->'sections'->1->>'hide') = 'true', '숨긴 칸에 hide 저장(053)');
select test.ok(not ((public.info_pages())->'pages'->'room'->'sections'->0 ? 'hide'), '보이는 칸에는 hide 없음(053)');
select test.ok((public.admin_set_info_page('room', '[{"t":"","b":"","hide":true}]'::jsonb))->>'ok' = 'false', '빈 칸은 숨겨도 버림(053)');
select public.admin_set_info_page('room', null);
reset role; reset request.jwt.claims;
select '모든 시험 통과(048~053)' as 결과;
