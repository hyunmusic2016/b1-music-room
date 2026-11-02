-- 027_my_roster.sql : 재원생 명부에 있는 학생은 예약이 하나도 없어도 '내 예약'을 조회할 수 있게(2026-11-02 사용자 요청)
-- · 전에는 이름+비밀번호에 맞는 예약도 등록 이용자도 없으면 "일치하지 않거나 예약이 없습니다"로 실패했습니다.
-- · 이제 이름+비밀번호(뒤 4자리)가 재원생 명부(025 roster)와 맞으면 빈 목록으로 성공합니다(구분 stu).
--   명부 확인을 켜고 끄는 것과 관계없이 명부에 있으면 조회됩니다.
-- · 틀린 경우의 횟수 세기·잠금(이름 기준 5번 15분)은 그대로입니다. 나머지는 012와 같습니다.

create or replace function public.my_reservations(p_name text, p_pw text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); kf date := public.keep_from(); list jsonb; uid bigint; cur bigint; ros boolean := false;
begin
  if public.is_locked(n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
  if not public.valid_name(n) or not public.valid_pw(p_pw) then
    return public.fail('이름 또는 비밀번호가 일치하지 않거나 예약이 없습니다.'); end if;
  select jsonb_agg(jsonb_build_object('id', id, 'date', date, 'hour', hour, 'status', status, 'reason', cancel_reason,
           'prod', product_kind, 'ext', is_ext, 'started', public.slot_started(date, hour), 'ended', public.slot_ended(date, hour))
           order by date, hour)
    into list from public.reservations where name = n and date >= kf and public.pw_ok(p_pw, pw_hash);
  select id into uid from public.users where name = n and public.pw_ok(p_pw, pw_hash)
   order by (status = 'active') desc, id desc limit 1;
  if list is null and uid is null then
    -- 027: 명부에 있는 재원생이면 예약이 없어도 조회 성공
    ros := exists (select 1 from public.roster r where r.name = n and public.pw_ok(p_pw, r.pw_hash));
    if not ros then
      perform public.fail_hit(n);
      return public.fail('이름 또는 비밀번호가 일치하지 않거나 예약이 없습니다.');
    end if;
  end if;
  perform public.fail_reset(n);
  if uid is not null then cur := public.current_product(uid); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'list', coalesce(list, '[]'),
    -- 등록 이용자면 구분(stu/ext), 미등록이면 null(화면은 예약의 구분으로 판단). 명부로만 확인된 사람은 stu
    'user_type', coalesce((select type from public.users where id = uid), case when ros then 'stu' end),
    'product', public.product_json(cur),
    'old_products', coalesce((select jsonb_agg(public.product_json(id) order by end_date desc) from public.products
                     where user_id = uid and end_date < public.app_today() and end_date >= kf), '[]'));
end $$;

revoke execute on function public.my_reservations(text, text) from public, anon, authenticated;
grant execute on function public.my_reservations(text, text) to anon, authenticated;
