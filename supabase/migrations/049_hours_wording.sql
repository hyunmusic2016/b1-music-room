-- 049_hours_wording.sql : "회·횟수" → "시간"(2026-11-09 사용자 결정: "횟수"라는 말을 쓰지 않음)
-- 예약 1건 = 1시간이므로 이용권의 숫자(총 N·사용·남은)는 원래 시간과 같습니다. 데이터·규칙은 그대로이고 서버 안내 문구만 바꿉니다.
--   · "이용권 N회를 모두 사용했습니다." → "이용권 N시간을 모두 사용했습니다."
--   · "하루에 한 번만 예약할 수 있습니다." → "하루 1시간만 예약할 수 있습니다."
--   · "시도 횟수를 초과했습니다." → "비밀번호를 여러 번 잘못 입력했습니다."
--   · 이용자 수정·이용료 변경의 "총 이용 횟수", "횟수를 …" → "총 이용 시간", "시간을 …", "1회 이용료" → "1시간 이용료"
--   · 이용료 표 저장 때 횟수 칸에 "10시간"처럼 써도 숫자만 저장("회"도 그대로 받음)
-- 함수 정의 글을 읽어 글자만 바꿔 다시 만듭니다(048과 같은 방식, 권한 그대로). 여러 번 실행해도 결과가 같습니다.
do $$
declare
  r record; def text; nd text; i int;
  reps text[][] := array[
    array['replace(replace(trim(coalesce(row->>''n'', '''')), ''회'', ''''), '' '', '''')',
          'replace(replace(replace(trim(coalesce(row->>''n'', '''')), ''시간'', ''''), ''회'', ''''), '' '', '''')'],
    array['시도 횟수를 초과했습니다.', '비밀번호를 여러 번 잘못 입력했습니다.'],
    array['재원생은 하루에 한 번만 예약할 수 있습니다.', '재원생은 하루 1시간만 예약할 수 있습니다.'],
    array['하루에 한 번만 예약할 수 있습니다.', '하루 1시간만 예약할 수 있습니다.'],
    array['회를 모두 사용했습니다', '시간을 모두 사용했습니다'],
    array['수정에서 횟수를 늘리거나', '수정에서 시간을 늘리거나'],
    array['회 사용했습니다. 총 이용 횟수는 ', '시간 사용했습니다. 총 이용 시간은 '],
    array['회 이상이어야 합니다.', '시간 이상이어야 합니다.'],
    array['총 이용 횟수를 1~999', '총 이용 시간을 1~999'],
    array['총 이용 횟수는 999회를 넘을 수 없습니다. 지금 총 ', '총 이용 시간은 999시간을 넘을 수 없습니다. 지금 총 '],
    array['회입니다.', '시간입니다.'],
    array['추가 횟수를', '추가 시간을'],
    array['번째 줄: 횟수를 1~', '번째 줄: 시간을 1~'],
    array['1회 이용료는 숫자만', '1시간 이용료는 숫자만'],
    array['하루 이용 횟수', '하루 이용 시간'],
    array['회)를', '시간)를'],
    array['회)와', '시간)와']
  ];
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and (p.prosrc like '%횟수%' or p.prosrc like '%한 번만 예약%' or p.prosrc like '%회를 모두%'
                   or p.prosrc like '%회 이상이어야%' or p.prosrc like '%''회''%' or p.prosrc like '%1회 이용료%') loop
    def := pg_get_functiondef(r.oid); nd := def;
    for i in 1 .. array_length(reps, 1) loop
      nd := replace(nd, reps[i][1], reps[i][2]);
    end loop;
    if nd <> def then execute nd; end if;
  end loop;
end $$;

-- 실행 결과 확인용(두 숫자가 모두 0이면 정상)
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') like '%횟수%') as "횟수 문구가 남은 함수",
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc ~ '(한 번만 예약|회를 모두|회 이상이어야)') as "회 문구가 남은 함수";
