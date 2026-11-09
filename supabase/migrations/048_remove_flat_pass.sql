-- 048_remove_flat_pass.sql : 정액권 없애기 + "횟수권" → "이용권"(2026-11-09 사용자 결정)
-- 사용자 결정:
--   · 정액권은 더 이상 쓰지 않습니다. 새로 등록할 수 없고(이용자 등록·수정 모두), 이용료 표에서도 빠집니다.
--   · 지금 서버에 남아 있는 정액권은 "어제 날짜로 종료"합니다(이미 시작한 것은 만료된 상품 기록으로 남고,
--     오늘 이후 시작 예정이던 것은 지워짐 — 상품 종료 버튼과 같은 end_product_row).
--     그 정액권으로 이미 잡힌 예약은 취소하지 않고 그대로 둡니다.
--   · 남는 상품(코드 값 'count')의 이름은 "이용권"입니다. 서버 안내 문구의 "횟수권"도 모두 "이용권"으로 바꿉니다.
-- 바뀌지 않는 것: 상품 없는 재원생 하루 1회, 상품 없는 일반회원 제한 없음, 재원생 추가 이용료,
--   이용권 예약 때 1회 차감·취소하면 돌려받기, 명부 확인 예외(이용권이 있는 등록 재원생).
-- 함수 권한은 그대로입니다(create or replace는 권한을 바꾸지 않음). 여러 번 실행해도 결과가 같습니다.

-- 1) 서버 함수 안의 안내 문구 바꾸기(그 함수의 정의 글을 그대로 가져와 글자만 바꿔 다시 만듦)
do $$
declare
  r record; def text; nd text;
  reps text[][] := array[
    array['정액권과 횟수권은 한 개씩만 등록할 수 있습니다.', '이용권은 한 개만 등록할 수 있습니다.'],
    array['정액권·횟수권', '이용권'],
    array['횟수권', '이용권'],
    -- 이용료 표: 정액권 칸을 받지도 주지도 않음
    array['array[''ext_flat'',''ext_count'',''stu_flat'',''stu_count'']', 'array[''ext_count'',''stu_count'']'],
    array['{"ext_flat":[],"ext_count":[],"stu_flat":[],"stu_count":[],"stu_extra":""}', '{"ext_count":[],"stu_count":[],"stu_extra":""}']
  ];
  i int;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and (p.prosrc like '%횟수권%' or p.prosrc like '%ext_flat%') loop
    def := pg_get_functiondef(r.oid); nd := def;
    for i in 1 .. array_length(reps, 1) loop
      nd := replace(nd, reps[i][1], reps[i][2]);
    end loop;
    if nd <> def then execute nd; end if;
  end loop;
end $$;

-- 2) 새 상품은 이용권만(정액권 등록은 서버가 막음)
create or replace function public.check_product(t text, kind text, s date, days int, lim int, tot int) returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  -- 048: 정액권은 없어짐. 이용권(count)만 등록할 수 있음
  if kind is distinct from 'count' then return public.fail('이용권만 등록할 수 있습니다.'); end if;
  if s is null or days is null or days not between 1 and 999 then
    return public.fail('시작일과 기간(일)을 확인하십시오. 기간은 1 이상의 숫자로 입력하십시오.'); end if;
  if tot is null or tot not between 1 and 999 then
    return public.fail('총 이용 횟수를 1~999 사이의 숫자로 입력하십시오.'); end if;
  return null;
end $$;
revoke execute on function public.check_product(text, text, date, int, int, int) from public, anon, authenticated;

-- 3) 남아 있는 정액권은 어제 날짜로 종료(예약은 그대로)
select public.end_product_row(id) from public.products
 where kind = 'flat' and end_date >= public.app_today();

-- 4) 이용료 표에서 정액권 가격 줄을 지움(가격이 바뀐 것이므로 수정 날짜를 오늘로)
update public.settings
   set value = (value - 'ext_flat' - 'stu_flat') || jsonb_build_object('updated_at', public.app_today()::text)
 where key = 'price_list' and (value ? 'ext_flat' or value ? 'stu_flat');

-- 실행 결과 확인용(아래 세 숫자가 모두 0이면 정상)
select
  (select count(*) from public.products where kind = 'flat' and end_date >= public.app_today()) as "남은 사용 중 정액권",
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc like '%횟수권%') as "횟수권 글자가 남은 함수",
  (select count(*) from public.settings where key = 'price_list' and (value ? 'ext_flat' or value ? 'stu_flat')) as "정액권 가격 줄";
