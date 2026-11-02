-- 031_admin_reserve_roster.sql : 관리자 예약에서 명부 학생(이용자 등록 안 함)을 고르면 '내 예약'에서도 보이게(2026-11-02 사용자 요청)
-- · 전에는 등록 이용자가 아닌 이름으로 관리자가 예약하면 비밀번호가 비어 있어 본인의 '내 예약'에 나오지 않았음.
--   명부 학생은 이름 + 뒤 4자리로 '내 예약'을 조회할 수 있으므로(027), 관리자 예약에도 명부의 뒤 4자리(해시)를 붙임.
-- · admin_reserve에 p_roster_no(명부 등록번호, 선택)를 더함. 주면: 명부에서 그 등록번호 + 같은 이름을 찾아 재원생으로 예약,
--   예약 비밀번호 = 명부의 해시. 못 찾으면 막음. 하루 1회 등 규칙은 전과 같음(미등록 재원생 규칙).
-- · 알려진 한계: 그 뒤 시트에서 전화번호가 바뀌면 이미 잡힌 이 예약의 비밀번호는 옛 번호 그대로(이용자 등록·명부 연결을 하면 함께 바뀜).
-- · 나머지는 020의 admin_reserve와 같습니다.

drop function if exists public.admin_reserve(date, int, text, bigint, boolean, boolean);

create or replace function public.admin_reserve(p_date date, p_hour int, p_name text, p_user_id bigint, p_ext boolean, p_super boolean, p_roster_no text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); t date := public.app_today(); prob jsonb; rid bigint;
  u public.users; uid bigint; ext boolean; h text; sup boolean := coalesce(p_super, false); pid bigint; p public.products;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  -- 같은 이름의 예약은 한 번에 하나씩 처리(공개 예약과 같은 잠금)
  perform pg_advisory_xact_lock(hashtext('name:' || n));
  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if p_user_id is not null then
    select * into u from public.users where id = p_user_id and status in ('active', 'blacklisted');
    if not found or u.name <> n then return public.fail('선택한 이용자를 찾을 수 없습니다. 이름을 다시 입력하십시오.', true); end if;
    -- 블랙리스트 이용자: 일반예약은 막고 슈퍼패스만 허용(015)
    if u.status = 'blacklisted' and not sup then
      return public.fail('블랙리스트 이용자입니다. 일반예약은 할 수 없습니다. 꼭 필요하면 슈퍼패스로 예약하십시오.'); end if;
    uid := u.id; ext := u.type = 'ext'; h := u.pw_hash;
  elsif nullif(trim(coalesce(p_roster_no, '')), '') is not null then
    -- 031: 이용자 등록을 안 한 명부 학생 → 재원생, 명부의 뒤 4자리(해시)를 예약에 붙여 '내 예약'에서 보이게
    select pw_hash into h from public.roster where reg_no = trim(p_roster_no) and name = n;
    if h is null then return public.fail('재원생 명부에서 그 학생을 찾을 수 없습니다. 이름을 다시 입력하십시오.', true); end if;
    ext := false;
  else
    ext := coalesce(p_ext, false);
  end if;

  if not sup then
    if ext and uid is null then
      return public.fail('등록되지 않은 일반회원입니다. 슈퍼패스로 예약하거나 먼저 이용자 등록을 하십시오.'); end if;
    if uid is not null then pid := public.product_on(uid, p_date); end if;
    if pid is not null then
      select * into p from public.products where id = pid for update; -- 같은 상품 동시 사용 방지
      if p.kind = 'count' and public.product_used(p.id) >= p.total_count then
        return public.fail('횟수권 ' || p.total_count || '회를 모두 사용했습니다. 이용자 현황 > 수정에서 횟수를 늘리거나 슈퍼패스로 예약하십시오.'); end if;
      if p.kind = 'flat' and public.product_used(p.id, p_date) >= p.daily_limit then
        return public.fail('정액권 하루 이용 횟수(' || p.daily_limit || '회)를 모두 사용했습니다.'); end if;
    elsif not ext then
      if public.stu_day_taken(p_date, uid, n) then
        return public.fail('재원생은 하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
    end if;
  end if;

  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, by_admin, is_super, product_id, product_kind)
    values (p_date, p_hour, n, h, uid, ext, true, sup, p.id, p.kind) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('admin', 'reserve', jsonb_build_object('id', rid, 'super', sup));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', ext, 'super', sup,
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end);
end $$;

revoke execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean, text) to authenticated;
