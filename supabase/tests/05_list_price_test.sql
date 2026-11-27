-- 로컬 시험: 065(이용권 정상가·할인 표기) — Supabase에서는 실행하지 않음.
-- 마지막에 "모든 시험 통과(065)"가 나오면 성공입니다.
\set ON_ERROR_STOP 1
\set QUIET 1
set app.fake_now = '2028-06-01 10:00';
set request.jwt.claims = '{"sub":"00000000-0000-0000-0000-00000000000a"}'; set role authenticated;
select test.ok((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"5","orig":"35,000원","price":"28000"},{"n":"10","price":"52000"}],"stu_count":[{"n":"10","orig":"30000","price":"24,000"}]}'))->'ext_count'
  = '[{"n":5,"orig":"35000","price":"28000"},{"n":10,"price":"52000"}]'::jsonb, '정상가 저장(쉼표·원 정리), 비운 줄은 정상가 없음');
select test.ok((public.price_info())->'stu_count'->0->>'orig' = '30000', '제휴회원 이용권 정상가도 저장');
select test.ok((public.admin_set_prices('{"ext_count":[{"n":"5","orig":"28000","price":"28000"}]}'))->>'msg' like '일반회원 이용권 1번째 줄: 정상가는 판매가보다 커야%', '정상가 = 판매가는 막음');
select test.ok((public.admin_set_prices('{"stu_count":[{"n":"5","orig":"abc","price":"28000"}]}'))->>'msg' like '제휴회원 이용권 1번째 줄: 정상가를 숫자로%', '정상가 숫자 아님은 막음(문구 "제휴회원")');
select test.ok((public.price_info())->'ext_count'->0->>'orig' = '35000', '실패한 저장은 표를 바꾸지 않음');
select test.ok(not ((public.admin_set_prices('{"fee":"7000","ext_count":[{"n":"5","orig":"","price":"28000"}]}'))->'ext_count'->0 ? 'orig'), '정상가를 지우면 할인 표기 없어짐');
reset role;
set role anon;
select test.denied('select public.admin_set_prices(''{}'')', '익명은 이용료 저장 불가(권한 유지)');
reset role; reset request.jwt.claims; reset app.fake_now;
select test.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.prosrc like '%재원생%') = 0, '서버 함수에 "재원생" 글자 없음(065 후)');
\i supabase/migrations/065_list_price.sql
select '모든 시험 통과(065)' as 결과;
