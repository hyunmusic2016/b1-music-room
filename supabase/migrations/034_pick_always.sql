-- 034: 정액권·횟수권을 둘 다 가진 사람이 그날 한쪽만 쓸 수 있을 때(2026-11-03 사용자 결정 변경)
-- 033은 남은 쪽으로 자동 예약 + 안내였으나, 이제는 고르는 창을 항상 띄우고 다 쓴 쪽은 막습니다(사용자 선택).
-- 서버 응답: choose:true + options[각 상품 + usable(쓸 수 있는지) + why(못 쓰는 이유)]. 다 쓴 쪽을 p_kind로 보내면 지금처럼 막힘.
-- 둘 다 다 쓰면 지금처럼 막힘. 공개 예약·관리자 일반예약 모두 같은 함수(pick_product)를 씁니다.

-- 예약에 쓸 상품 고르기. 결과: {pid} 또는 {pid, note}(자동) 또는 {fail: 실패 응답}. 그날 상품이 없으면 {}.
create or replace function public.pick_product(uid bigint, d date, k text, adm boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.products; c public.products; fok boolean; cok boolean; fmsg text; cmsg text;
begin
  if uid is null then return '{}'::jsonb; end if;
  select * into f from public.products where user_id = uid and kind = 'flat' and start_date <= d and d <= end_date
   order by end_date desc, id desc limit 1 for update;
  select * into c from public.products where user_id = uid and kind = 'count' and start_date <= d and d <= end_date
   order by end_date desc, id desc limit 1 for update;
  if f.id is null and c.id is null then return '{}'::jsonb; end if;
  fok := f.id is not null and public.product_used(f.id, d) < f.daily_limit;
  cok := c.id is not null and public.product_used(c.id) < c.total_count;
  fmsg := '정액권 하루 이용 횟수(' || f.daily_limit || '회)를 모두 사용했습니다.';
  cmsg := '횟수권 ' || c.total_count || '회를 모두 사용했습니다. '
          || case when adm then '이용자 현황 > 수정에서 횟수를 늘리거나 슈퍼패스로 예약하십시오.' else '관리자에게 문의하십시오.' end;
  if k is not null and k not in ('flat','count') then return jsonb_build_object('fail', public.fail('잘못된 요청입니다.')); end if;
  if k = 'flat' then
    if f.id is null then return jsonb_build_object('fail', public.fail('그 날짜에 쓸 수 있는 정액권이 없습니다.', true)); end if;
    if not fok then return jsonb_build_object('fail', public.fail(fmsg, true)); end if;
    return jsonb_build_object('pid', f.id);
  elsif k = 'count' then
    if c.id is null then return jsonb_build_object('fail', public.fail('그 날짜에 쓸 수 있는 횟수권이 없습니다.', true)); end if;
    if not cok then return jsonb_build_object('fail', public.fail(cmsg, true)); end if;
    return jsonb_build_object('pid', c.id);
  end if;
  -- 고르지 않음
  if f.id is not null and c.id is not null then
    if fok or cok then
      -- 034: 한쪽만 남아도 자동으로 고르지 않고 고르는 창을 띄움. 다 쓴 쪽은 usable:false(화면에서 막힘)
      return jsonb_build_object('fail', public.fail('정액권과 횟수권 중 어느 것을 사용할지 선택하십시오.')
        || jsonb_build_object('choose', true, 'options', jsonb_build_array(
             public.product_json(f.id) || jsonb_build_object('usable', fok, 'why', case when not fok then fmsg end),
             public.product_json(c.id) || jsonb_build_object('usable', cok, 'why', case when not cok then cmsg end))));
    else
      return jsonb_build_object('fail', public.fail('정액권 하루 이용 횟수(' || f.daily_limit || '회)와 횟수권 ' || c.total_count
        || '회를 모두 사용했습니다. ' || case when adm then '이용자 현황 > 수정에서 횟수를 늘리거나 슈퍼패스로 예약하십시오.' else '관리자에게 문의하십시오.' end));
    end if;
  elsif f.id is not null then
    if not fok then return jsonb_build_object('fail', public.fail(fmsg)); end if;
    return jsonb_build_object('pid', f.id);
  else
    if not cok then return jsonb_build_object('fail', public.fail(cmsg)); end if;
    return jsonb_build_object('pid', c.id);
  end if;
end $$;

revoke execute on function public.pick_product(bigint, date, text, boolean) from public, anon, authenticated;
