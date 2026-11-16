-- 063_my_res_super.sql : 예약 목록에 슈퍼패스 여부(super)를 함께 줌(2026-11-16 사용자 요청)
-- · 내 예약(my_reservations)·관리자 이용자 정보(admin_user)의 예약 목록에 'super' 추가.
--   화면이 제휴회원의 "무료" 배지(이용권도 슈퍼패스도 아닌 예약)를 붙일 때 씀. 규칙·권한은 그대로. 두 번 실행해도 같음.
do $$
declare r record; def text; nd text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('my_reservations', 'admin_user')
              and p.prosrc not like '%''super'', is_super%' loop
    def := pg_get_functiondef(r.oid);
    nd := replace(def, '''prod'', product_kind, ''ext'', is_ext,', '''prod'', product_kind, ''ext'', is_ext, ''super'', is_super,');
    if nd <> def then execute nd; end if;
  end loop;
end $$;

-- 확인: super를 주는 함수 수(2이면 정상)
select count(*) as super_주는_함수 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('my_reservations', 'admin_user') and p.prosrc like '%''super'', is_super%';
