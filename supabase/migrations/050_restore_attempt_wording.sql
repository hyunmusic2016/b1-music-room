-- 050_restore_attempt_wording.sql : 비밀번호 잠금 문구를 원래대로(2026-11-09 사용자 요청)
-- 사용자: "횟수"는 예약할 때 쓰는 이용 횟수만 "시간"으로 바꾸는 것이고,
--   비밀번호 시도 횟수처럼 예약과 관계없는 말은 원래대로 씁니다.
--   · 049의 "비밀번호를 여러 번 잘못 입력했습니다." → 원래 "시도 횟수를 초과했습니다."
-- 049와 같은 방식(함수 정의 글을 읽어 글자만 바꿔 다시 만듦, 권한 그대로). 여러 번 실행해도 결과가 같습니다.
do $$
declare r record; def text; nd text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and p.prosrc like '%비밀번호를 여러 번 잘못 입력했습니다.%' loop
    def := pg_get_functiondef(r.oid);
    nd := replace(def, '비밀번호를 여러 번 잘못 입력했습니다.', '시도 횟수를 초과했습니다.');
    if nd <> def then execute nd; end if;
  end loop;
end $$;

-- 실행 결과 확인용(앞 숫자는 0, 뒤 숫자는 1 이상이면 정상)
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc like '%비밀번호를 여러 번 잘못%') as "바뀐 문구가 남은 함수",
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc like '%시도 횟수를 초과했습니다.%') as "원래 문구로 돌아온 함수";
