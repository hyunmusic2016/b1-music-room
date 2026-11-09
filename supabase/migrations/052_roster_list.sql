-- 052_roster_list.sql : 이용자 현황에 재원생 명부(구글 시트) 전체를 보여 주기(2026-11-09 사용자 요청)
--   · 관리자 함수 admin_roster_list(): 명부 학생 전체(등록번호·이름)와 연결된 이용자 번호, 마지막 반영 시각·인원.
--   · 전화번호 뒤 4자리(암호화된 값)는 주지 않습니다. 명부는 구글 시트에서 반영될 때마다(1시간마다·[지금 반영]) 바뀌고,
--     화면은 이용자 현황을 열 때마다 이 함수를 새로 불러 항상 최신 명부를 보여 줍니다.
create or replace function public.admin_roster_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cfg jsonb := coalesce((select value from public.settings where key = 'roster'), '{}'::jsonb);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'synced_at', cfg->'synced_at', 'count', (select count(*) from public.roster),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('no', r.reg_no, 'name', r.name,
              'user_id', (select u.id from public.users u where u.roster_no = r.reg_no)) order by r.name, r.reg_no)
            from public.roster r), '[]'));
end $$;

revoke execute on function public.admin_roster_list() from public, anon, authenticated;
grant execute on function public.admin_roster_list() to authenticated;

-- 실행 결과 확인용: 지금 명부 인원
select count(*) as "명부 인원" from public.roster;
