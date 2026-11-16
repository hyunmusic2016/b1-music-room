-- 062_no_academy_wording.sql : 손님에게 보이는 서버 문구에서 "학원"을 뺌(2026-11-16 사용자 요청)
-- · "학원에 문의하십시오" → "관리자에게 문의하십시오"(예약 취소·변경), "(학원에 등록된 전화번호 뒤 4자리)" → "(등록된 전화번호 뒤 4자리)"
-- · 048·061처럼 함수 정의 글을 읽어 글자만 바꿔 다시 만듦(규칙·권한 그대로). 두 번 실행해도 같음. 061 다음에 실행.
-- · 저장된 안내 글·로비 글의 같은 문구도 바꿈: "학원에/학원으로 문의하십시오" → "관리자에게 문의하십시오",
--   "학원 제휴회원 명부" → "제휴회원 명부", "학원 오시기 전 연습실 예약 현황" → "연습실 오시기 전 예약 현황".
--   "현실용음악학원"(제휴 학원 이름)은 그대로.
do $$
declare r record; def text; nd text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and (p.prosrc like '%학원에 문의하십시오%' or p.prosrc like '%학원에 등록된 전화번호%') loop
    def := pg_get_functiondef(r.oid);
    nd := replace(replace(def, '학원에 문의하십시오', '관리자에게 문의하십시오'), '학원에 등록된 전화번호', '등록된 전화번호');
    if nd <> def then execute nd; end if;
  end loop;
end $$;

update public.settings
   set value = replace(replace(replace(replace(value::text,
         '학원에 문의하십시오', '관리자에게 문의하십시오'),
         '학원으로 문의하십시오', '관리자에게 문의하십시오'),
         '학원 제휴회원 명부', '제휴회원 명부'),
         '학원 오시기 전 연습실 예약 현황', '연습실 오시기 전 예약 현황')::jsonb
 where key in ('info_pages', 'info_titles', 'lobby_info', 'contact_hours')
   and value::text ~ '학원에 문의하십시오|학원으로 문의하십시오|학원 제휴회원 명부|학원 오시기 전 연습실 예약 현황';

-- 확인: 고칠 문구가 남은 서버 함수 수와 저장된 글 수(둘 다 0이면 정상)
select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and (p.prosrc like '%학원에 문의하십시오%' or p.prosrc like '%학원에 등록된 전화번호%')) as 학원_남은_함수,
       (select count(*) from public.settings where key in ('info_pages', 'info_titles', 'lobby_info', 'contact_hours')
          and value::text ~ '학원에 문의하십시오|학원으로 문의하십시오|학원 제휴회원 명부|학원 오시기 전 연습실 예약 현황') as 학원_남은_저장글;
