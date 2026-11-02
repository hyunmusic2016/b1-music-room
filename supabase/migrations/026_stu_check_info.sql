-- 026_stu_check_info.sql : 재원생 예약 창에서 이름+비밀번호를 넣으면 "재원생 확인" 여부를 미리 알려 줌(2026-11-02 사용자 요청)
-- · product_info에 재원생(p_mode='stu')이고 명부 확인이 켜져 있을 때만 roster(true/false)를 더 줍니다.
--     roster=true  : 이름+비밀번호(뒤 4자리)가 명부와 맞음
--     roster=false : 명부와 맞지 않음(화면은 그 날짜의 정액권이 있으면 예약 가능으로 보여 줌, 서버 판단은 025의 stu_allowed 그대로)
--   명부 확인이 꺼져 있으면 roster를 주지 않습니다(화면은 아무것도 표시하지 않음).
-- · 명부에 있는 이름인데 비밀번호가 틀리면 맞혀 보기 횟수를 셉니다(info:이름, 5번이면 15분 잠금, 예약 창 상품 표시와 같은 키).
--   잠겨 있으면 locked:true를 줍니다.
-- · 공개 응답에는 맞다/아니다만 넣고 등록번호·이름 원본·전화번호는 넣지 않습니다.
-- · 나머지는 019의 product_info와 같습니다.

create or replace function public.product_info(p_mode text, p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n text := public.norm_name(p_name); uid bigint; pid bigint; k text := 'info:' || public.norm_name(p_name);
  ro jsonb := '{}'::jsonb; ok boolean; hit boolean := false;
begin
  if p_mode not in ('stu','ext') or not public.valid_name(n) or not public.valid_pw(p_pw) then
    return jsonb_build_object('ok', true, 'product', null); end if;
  if public.is_locked(k) then
    return jsonb_build_object('ok', true, 'product', null, 'locked', true); end if;
  -- 026: 재원생 명부 확인
  if p_mode = 'stu' and public.roster_on() then
    ok := exists (select 1 from public.roster r where r.name = n and public.pw_ok(p_pw, r.pw_hash));
    ro := jsonb_build_object('roster', ok);
    if not ok and exists (select 1 from public.roster r where r.name = n) then hit := true; end if;
  end if;
  uid := public.find_user(p_mode, n, p_pw);
  if uid is null then
    -- 상품이 있는(또는 7일 안에 끝난) 사람의 비밀번호를 맞혀 보는 시도는 횟수를 셉니다.
    if exists (select 1 from public.users u join public.products p on p.user_id = u.id
                where u.type = p_mode and u.name = n and u.status = 'active' and p.end_date >= public.app_today() - 7) then
      hit := true; end if;
    if hit then perform public.fail_hit(k); end if;
    return jsonb_build_object('ok', true, 'product', null) || ro;
  end if;
  pid := public.current_product(uid);
  if pid is null then  -- 017: 끝난 지 7일 안의 상품
    select id into pid from public.products
     where user_id = uid and end_date < public.app_today() and end_date >= public.app_today() - 7
     order by end_date desc, id desc limit 1;
  end if;
  return jsonb_build_object('ok', true, 'registered', true, 'product', public.product_json(pid)) || ro;
end $$;

revoke execute on function public.product_info(text, text, text) from public, anon, authenticated;
grant execute on function public.product_info(text, text, text) to anon, authenticated;
