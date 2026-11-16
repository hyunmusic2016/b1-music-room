-- 064_pass_used_up.sql : 이용권 시간을 모두 쓰면 기간이 남아 있어도 종료로 봄(2026-11-16 사용자 요청)
-- · prod_live(id): 이용권(count)은 남은 시간이 있어야 "사용 중". 날짜는 그대로 두고 계산으로만 판단하므로
--   이용권 예약을 취소해 1시간을 돌려받으면 기간 안에서는 다시 사용 중이 됨.
-- · 사용 중 이용권을 찾는 함수(current_product·current_products·product_on·products_on·stu_allowed·pick_product)가
--   다 쓴 이용권을 빼고 찾음 → 일반회원은 1시간 이용료 예약(사용자 선택), 제휴회원은 이용권 없는 제휴회원과 같음.
-- · 관리자 이용자 수정: 다 쓴 이용권이 있어도 새 이용권을 추가할 수 있음(기간 겹침 검사에서 뺌).
-- · product_json에 used_up(모두 사용), product_info에 used_up(기간 안에서 모두 쓴 이용권), 내 예약의 만료된 이용권 목록에 포함.
-- · 함수 정의 글을 읽어 해당 부분만 바꿔 다시 만듦(권한 그대로). 두 번 실행해도 같음.

create or replace function public.prod_live(pid bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select kind <> 'count' or public.product_used(id) < coalesce(total_count, 0)
                     from public.products where id = pid), false)
$$;
revoke execute on function public.prod_live(bigint) from public, anon, authenticated;

do $$
declare r record; def text; nd text; f text; i int;
  reps text[][] := array[
    -- 함수 이름, 이미 바뀌었는지 보는 글자, 바꿀 글자, 새 글자(정규식)
    array['current_product',  'prod_live', 'where user_id = uid and end_date >= public\.app_today\(\)', 'where user_id = uid and end_date >= public.app_today() and public.prod_live(id)'],
    array['current_products', 'prod_live', 'where user_id = uid and end_date >= public\.app_today\(\)', 'where user_id = uid and end_date >= public.app_today() and public.prod_live(id)'],
    array['product_on',       'prod_live', 'start_date <= d and d <= end_date', 'start_date <= d and d <= end_date and public.prod_live(id)'],
    array['products_on',      'prod_live', 'start_date <= d and d <= end_date', 'start_date <= d and d <= end_date and public.prod_live(id)'],
    array['stu_allowed',      'prod_live', 'and d between p\.start_date and p\.end_date', 'and d between p.start_date and p.end_date and public.prod_live(p.id)'],
    array['pick_product',     'prod_live', 'kind = ''count'' and start_date <= d and d <= end_date', 'kind = ''count'' and start_date <= d and d <= end_date and public.prod_live(id)'],
    array['admin_update_user','prod_live', 'and end_date >= public\.app_today\(\)\) then', 'and end_date >= public.app_today() and public.prod_live(id)) then'],
    array['product_json',     'used_up',   '''left'', lf,', '''left'', lf, ''used_up'', p.kind = ''count'' and used >= coalesce(p.total_count, 0),'],
    array['my_reservations',  'prod_live', 'where user_id = uid and end_date < public\.app_today\(\) and end_date >= kf', 'where user_id = uid and (end_date < public.app_today() or not public.prod_live(id)) and end_date >= kf'],
    array['product_info',     'used_up',   '''products'', public\.current_products\(uid\),', '''products'', public.current_products(uid),
    ''used_up'', public.product_json((select id from public.products where user_id = uid and kind = ''count''
                   and end_date >= public.app_today() and not public.prod_live(id) order by end_date desc, id desc limit 1)),']
  ];
begin
  for i in 1 .. array_length(reps, 1) loop
    f := reps[i][1];
    for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = f loop
      def := pg_get_functiondef(r.oid);
      if position(reps[i][2] in def) > 0 then continue; end if;  -- 이미 바뀜
      nd := regexp_replace(def, reps[i][3], reps[i][4], 'g');
      if nd = def then raise exception '064: % 함수에서 바꿀 곳을 찾지 못했습니다.', f; end if;
      execute nd;
    end loop;
  end loop;
end $$;

-- 확인: 바뀐 함수 수(10이면 정상)
select count(*) as 바뀐_함수 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('current_product','current_products','product_on','products_on','stu_allowed',
   'pick_product','admin_update_user','product_json','my_reservations','product_info')
   and (p.prosrc like '%prod_live%' or p.prosrc like '%used_up%');
