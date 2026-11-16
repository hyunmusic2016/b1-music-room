-- 061_partner_wording.sql : 서버 문구 "재원생" → "제휴회원"(2026-11-16 사용자 요청: 학원이 운영하는 것처럼 보이지 않게)
-- · 048·049처럼 서버 함수 정의 글을 읽어 글자만 바꿔 다시 만듦(규칙·권한·데이터는 그대로). 두 번 실행해도 같음.
-- · 코드 값(stu)·표 이름(roster 등)은 그대로.
-- · 관리자 화면에서 저장한 안내 글(안내 창 글·안내 창 제목·학원 로비 안내·문의 시간 메모)의 "재원생"도 "제휴회원"으로 바꿈(사용자 요청: 모두).
do $$
declare r record; def text; nd text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' and p.prosrc like '%재원생%' loop
    def := pg_get_functiondef(r.oid);
    nd := replace(def, '재원생', '제휴회원');
    if nd <> def then execute nd; end if;
  end loop;
end $$;

update public.settings set value = replace(value::text, '재원생', '제휴회원')::jsonb
 where key in ('info_pages', 'info_titles', 'lobby_info', 'contact_hours') and value::text like '%재원생%';

-- 확인: "재원생" 글자가 남은 서버 함수 수와 저장된 글 수(둘 다 0이면 정상)
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.prosrc like '%재원생%') as 재원생_남은_함수,
       (select count(*) from public.settings where value::text like '%재원생%') as 재원생_남은_저장글;
