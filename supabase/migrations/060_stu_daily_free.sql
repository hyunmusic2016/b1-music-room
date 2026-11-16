-- 060_stu_daily_free.sql : 이용권이 있는 재원생도 하루 1시간 무료(2026-11-16 사용자 결정, A안)
-- · 재원생은 이용권이 있어도 그날 첫 1시간은 무료(이용권 차감 없음), 2시간째부터 이용권에서 1시간씩 차감.
--   이용권을 다 썼지만 기간이 남아 있어도 첫 1시간은 무료, 2시간째부터는 막음. 일반회원은 그대로.
-- · "그날 무료 1시간"(stu_day_taken)은 이용권도 슈퍼패스도 아닌 확정 예약만 셈(슈퍼패스는 안 셈: 사용자 선택 ④).
-- · 무료 예약을 취소·날짜 이동하면 그날 남은 이용권 예약 중 가장 이른 것을 무료로 바꾸고 1시간을 돌려줌(①, 트리거).
-- · 시간 변경(move_own)은 옮길 날짜 기준으로 무료/이용권을 다시 계산(②).
-- · 이미 잡힌 오늘·내일 예약 중 무료가 없는 날은 가장 이른 이용권 예약을 무료로 바꿈(③, 맨 아래).
-- · reserve·admin_reserve 응답에 free(무료 예약인지)·free_pass(이용권이 있는데 무료로 잡혔는지),
--   product_info에 free{오늘: 무료 남음, 내일: 무료 남음}(재원생).

CREATE OR REPLACE FUNCTION public.stu_day_taken(p_date date, p_uid bigint, p_name text, p_except bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.reservations
                  where date = p_date and status = 'confirmed' and not is_ext
                    and not is_super and product_id is null  -- 060: 그날 무료 1시간을 쓴 예약만(슈퍼패스·이용권 예약은 안 셈)
                    and (p_except is null or id <> p_except)
                    and case when p_uid is not null then user_id = p_uid
                             else user_id is null and name = p_name end)
$function$;

-- 그날 무료 예약이 없으면 그 사람의 가장 이른 이용권 예약을 무료로 바꿈(이용권 1시간 돌려받음). 지난 날짜는 손대지 않음
create or replace function public.stu_rebalance(p_date date, p_uid bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare rid bigint;
begin
  if p_uid is null or p_date is null or p_date < public.app_today() then return; end if;
  if public.stu_day_taken(p_date, p_uid, null) then return; end if;
  select id into rid from public.reservations
   where date = p_date and user_id = p_uid and status = 'confirmed' and not is_ext and not is_super and product_id is not null
   order by hour limit 1;
  if rid is null then return; end if;
  update public.reservations set product_id = null, product_kind = null, updated_at = now() where id = rid;
  perform public.audit('system', 'stu_free_swap', jsonb_build_object('id', rid));
end $$;

create or replace function public.stu_rebalance_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not old.is_ext and old.user_id is not null then perform public.stu_rebalance(old.date, old.user_id); end if;
  return null;
end $$;

drop trigger if exists reservations_stu_rebalance on public.reservations;
create trigger reservations_stu_rebalance after update of status, date, product_id, is_super or delete on public.reservations
  for each row execute function public.stu_rebalance_trg();

revoke execute on function public.stu_rebalance(date, bigint) from public, anon, authenticated;
revoke execute on function public.stu_rebalance_trg() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reserve(p_date date, p_hour integer, p_name text, p_pw text, p_consent boolean, p_mode text, p_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  n text := public.norm_name(p_name); t date := public.app_today();
  ext boolean := p_mode = 'ext'; uid bigint; pid bigint; p public.products; prob jsonb; rid bigint; c record; pk jsonb := '{}'; free boolean := false;
begin
  if p_mode not in ('stu','ext') then return public.fail('잘못된 요청입니다.'); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not coalesce(p_consent, false) then return public.fail('개인정보 수집에 동의해 주십시오.'); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if not public.valid_pw(p_pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  perform pg_advisory_xact_lock(hashtext('name:' || n));

  if ext then
    if public.is_locked('ext:' || n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
    uid := public.find_user('ext', n, p_pw);
    if uid is null then
      if exists (select 1 from public.users where type = 'ext' and name = n and status = 'blacklisted' and public.pw_ok(p_pw, pw_hash)) then
        perform public.fail_reset('ext:' || n);
        return public.fail('현재 예약이 제한되어 있습니다. 관리자에게 문의하십시오.');
      end if;
      perform public.fail_hit('ext:' || n);
      return public.fail('등록된 일반회원 정보와 일치하지 않습니다. 처음 이용하시는 경우 010-7753-8730으로 연락하시기 바랍니다.')
             || jsonb_build_object('ext', true);
    end if;
    perform public.fail_reset('ext:' || n);
  elsif public.roster_on() then
    if public.is_locked('stu:' || n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
    if not public.stu_allowed(n, p_pw, p_date) then
      perform public.fail_hit('stu:' || n);
      return public.fail('재원생 명부에서 확인되지 않습니다. 이름과 비밀번호(학원에 등록된 전화번호 뒤 4자리)를 확인하시거나 관리자에게 문의하십시오.');
    end if;
    perform public.fail_reset('stu:' || n);
  end if;

  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if not ext then
    -- 그 날짜에 상품이 있는 재원생 중 비밀번호가 맞는 사람
    for c in select distinct u.id as uid, u.pw_hash from public.products p2 join public.users u on u.id = p2.user_id
              where u.type = 'stu' and u.status = 'active' and u.name = n and p2.kind in ('flat','count')
                and p_date between p2.start_date and p2.end_date loop
      if public.pw_ok(p_pw, c.pw_hash) then uid := c.uid; exit; end if;
    end loop;
    if uid is null then uid := public.find_user('stu', n, p_pw); end if;
  end if;

  -- 060: 재원생은 이용권이 있어도 그날 첫 1시간은 무료(이용권 차감 없음), 2시간째부터 이용권
  if not ext and not public.stu_day_taken(p_date, uid, n) then
    free := true;
  else
    pk := public.pick_product(uid, p_date, nullif(p_kind, ''), false);
    if pk ? 'fail' then return pk->'fail'; end if;
    pid := (pk->>'pid')::bigint;
    if pid is null and not ext then
      return public.fail('하루 1시간만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
  end if;
  if pid is not null then select * into p from public.products where id = pid; end if;

  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, product_id, product_kind)
    values (p_date, p_hour, n, public.hash_pw(p_pw), uid, ext, p.id, p.kind) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('public', 'reserve', jsonb_build_object('id', rid));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', ext,
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end, 'note', pk->>'note',
    'free', free, 'free_pass', free and public.product_on(uid, p_date) is not null);
end $function$;

CREATE OR REPLACE FUNCTION public.admin_reserve(p_date date, p_hour integer, p_name text, p_user_id bigint, p_ext boolean, p_super boolean, p_roster_no text DEFAULT NULL::text, p_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n text := public.norm_name(p_name); t date := public.app_today(); prob jsonb; rid bigint;
  u public.users; uid bigint; ext boolean; h text; sup boolean := coalesce(p_super, false); pid bigint; p public.products; pk jsonb := '{}'; free boolean := false;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 예약할 수 있습니다.', true); end if;
  if not public.valid_name(n) then return public.fail('본명을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  perform pg_advisory_xact_lock(hashtext('name:' || n));
  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if p_user_id is not null then
    select * into u from public.users where id = p_user_id and status in ('active', 'blacklisted');
    if not found or u.name <> n then return public.fail('선택한 이용자를 찾을 수 없습니다. 이름을 다시 입력하십시오.', true); end if;
    if u.status = 'blacklisted' and not sup then
      return public.fail('블랙리스트 이용자입니다. 일반예약은 할 수 없습니다. 꼭 필요하면 슈퍼패스로 예약하십시오.'); end if;
    uid := u.id; ext := u.type = 'ext'; h := u.pw_hash;
  elsif nullif(trim(coalesce(p_roster_no, '')), '') is not null then
    select pw_hash into h from public.roster where reg_no = trim(p_roster_no) and name = n;
    if h is null then return public.fail('재원생 명부에서 그 학생을 찾을 수 없습니다. 이름을 다시 입력하십시오.', true); end if;
    ext := false;
  else
    ext := coalesce(p_ext, false);
  end if;

  if not sup then
    if ext and uid is null then
      return public.fail('등록되지 않은 일반회원입니다. 슈퍼패스로 예약하거나 먼저 이용자 등록을 하십시오.'); end if;
    -- 060: 재원생은 이용권이 있어도 그날 첫 1시간은 무료, 2시간째부터 이용권
    if not ext and not public.stu_day_taken(p_date, uid, n) then
      free := true;
    else
      pk := public.pick_product(uid, p_date, nullif(p_kind, ''), true);
      if pk ? 'fail' then return pk->'fail'; end if;
      pid := (pk->>'pid')::bigint;
      if pid is not null then
        select * into p from public.products where id = pid;
      elsif not ext then
        return public.fail('재원생은 하루 1시간만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.');
      end if;
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
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end, 'note', pk->>'note',
    'free', free, 'free_pass', free and public.product_on(uid, p_date) is not null);
end $function$;

CREATE OR REPLACE FUNCTION public.move_own(p_id bigint, p_name text, p_pw text, p_date date, p_hour integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n text := public.norm_name(p_name); r public.reservations; p public.products; t date := public.app_today(); prob jsonb; np bigint; pk jsonb;
begin
  if public.is_locked(n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
  perform pg_advisory_xact_lock(hashtext('name:' || n));
  select * into r from public.reservations where id = p_id for update;
  if not found or r.name <> n or not public.pw_ok(p_pw, r.pw_hash) then
    perform public.fail_hit(n); return public.fail('본인의 예약이 아닙니다.'); end if;
  if r.status <> 'confirmed' then return public.fail('취소된 예약은 변경할 수 없습니다.', true); end if;
  if public.slot_started(r.date, r.hour) then return public.fail('시작된 예약은 직접 변경할 수 없습니다. 학원에 문의하십시오.'); end if;
  if p_date is null or p_date not in (t, t + 1) then return public.fail('오늘과 내일만 선택할 수 있습니다.', true); end if;
  if p_hour is null or p_hour not between 0 and 23 then return public.fail('잘못된 시간입니다.'); end if;
  if r.date = p_date and r.hour = p_hour then return public.fail('현재 예약과 같은 시간입니다.'); end if;
  prob := public.slot_problem(p_date, p_hour, r.id);
  if prob is not null then return prob; end if;
  if not r.is_ext and not r.is_super then
    -- 060: 재원생은 옮길 날짜 기준으로 다시 계산. 그날 무료 1시간이 비어 있으면 무료(이용권 1시간 돌려받음),
    --      이미 있으면 이용권(지금 이용권이 그 날짜에 쓸 수 있으면 그대로, 아니면 그 날짜에 쓸 이용권에서 차감)
    if not public.stu_day_taken(p_date, r.user_id, r.name, r.id) then
      np := null;
    elsif r.product_id is not null and exists (select 1 from public.products where id = r.product_id
                                                  and p_date between start_date and end_date) then
      np := r.product_id;
    else
      pk := public.pick_product(r.user_id, p_date, null, false);
      if pk ? 'fail' then return pk->'fail'; end if;
      np := (pk->>'pid')::bigint;
      if np is null then
        return public.fail('하루 1시간만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
    end if;
  elsif r.product_id is not null then
    -- 일반회원 이용권 예약: 이용권 기간 안에서만 이동(시간 변화 없음)
    select * into p from public.products where id = r.product_id for update;
    if not found or p_date not between p.start_date and p.end_date then
      return public.fail('이용권 기간 밖의 날짜입니다.'); end if;
    np := r.product_id;
  else
    np := r.product_id;
  end if;
  begin
    update public.reservations set date = p_date, hour = p_hour, product_id = np,
      product_kind = (select kind from public.products where id = np), updated_at = now() where id = r.id;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('public', 'move_own', jsonb_build_object('id', r.id, 'from', r.date || ' ' || r.hour, 'to', p_date || ' ' || p_hour));
  return jsonb_build_object('ok', true, 'id', r.id, 'date', p_date, 'hour', p_hour, 'name', r.name, 'ext', r.is_ext,
    'prod', (select kind from public.products where id = np), 'free', not r.is_ext and not r.is_super and np is null);
end $function$;

CREATE OR REPLACE FUNCTION public.product_info(p_mode text, p_name text, p_pw text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  n text := public.norm_name(p_name); uid bigint; pid bigint; k text := 'info:' || public.norm_name(p_name);
  ro jsonb := '{}'::jsonb; ok boolean; hit boolean := false;
begin
  if p_mode not in ('stu','ext') or not public.valid_name(n) or not public.valid_pw(p_pw) then
    return jsonb_build_object('ok', true, 'product', null); end if;
  if public.is_locked(k) then
    return jsonb_build_object('ok', true, 'product', null, 'locked', true); end if;
  if p_mode = 'stu' and public.roster_on() then
    ok := exists (select 1 from public.roster r where r.name = n and public.pw_ok(p_pw, r.pw_hash));
    ro := jsonb_build_object('roster', ok);
    if not ok and exists (select 1 from public.roster r where r.name = n) then hit := true; end if;
  end if;
  uid := public.find_user(p_mode, n, p_pw);
  if uid is null then
    if exists (select 1 from public.users u join public.products p on p.user_id = u.id
                where u.type = p_mode and u.name = n and u.status = 'active' and p.end_date >= public.app_today() - 7) then
      hit := true; end if;
    if hit then perform public.fail_hit(k); end if;
    return jsonb_build_object('ok', true, 'product', null) || ro;
  end if;
  pid := public.current_product(uid);
  if pid is null then
    select id into pid from public.products
     where user_id = uid and end_date < public.app_today() and end_date >= public.app_today() - 7
     order by end_date desc, id desc limit 1;
  end if;
  return jsonb_build_object('ok', true, 'registered', true, 'product', public.product_json(pid),
    'products', public.current_products(uid),
    -- 060: 재원생의 그날 무료 1시간이 남았는지(true = 아직 안 씀)
    'free', case when p_mode = 'stu' then jsonb_build_object(
      public.app_today()::text, not public.stu_day_taken(public.app_today(), uid, n),
      (public.app_today() + 1)::text, not public.stu_day_taken(public.app_today() + 1, uid, n)) end) || ro;
end $function$;

-- ③ 이미 잡힌 오늘·내일 예약: 무료가 없는 날은 가장 이른 이용권 예약을 무료로
select public.stu_rebalance(x.date, x.user_id)
  from (select distinct date, user_id from public.reservations
         where status = 'confirmed' and not is_ext and not is_super and product_id is not null
           and user_id is not null and date >= public.app_today()) x;

-- 확인: 오늘·내일 이용권 예약이 있는데 무료 예약이 없는 재원생 수(0이면 정상)
select count(*) as 무료_빠진_재원생 from (select distinct date, user_id from public.reservations r
  where status = 'confirmed' and not is_ext and not is_super and product_id is not null and user_id is not null
    and date >= public.app_today() and not public.stu_day_taken(r.date, r.user_id, null)) x;
