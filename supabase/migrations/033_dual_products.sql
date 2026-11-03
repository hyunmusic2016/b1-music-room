-- 033: 정액권과 횟수권을 한 사람이 동시에 가질 수 있게(2026-11-03 사용자 요청)
-- 규칙(사용자 선택):
--  · 한 이용자(재원생·일반회원 모두)는 아직 끝나지 않은 정액권 1개 + 횟수권 1개까지. 같은 종류끼리는 지금처럼 기간이 겹치면 막음.
--  · 예약 날짜에 두 상품을 모두 쓸 수 있으면 손님이 고름(p_kind). 고르지 않고 보내면 "선택하십시오" 응답(choose:true + options).
--  · 한쪽만 쓸 수 있으면(정액권 그날 횟수를 다 썼거나 횟수권을 다 씀) 남은 쪽으로 자동 예약하고 안내(note).
--  · 관리자 일반예약도 같음. 슈퍼패스는 상품을 쓰지 않음(그대로).
--  · 예약 변경은 원래 예약한 상품 그대로(move_own 변경 없음), 취소하면 그 상품 횟수를 돌려받음(그대로).
-- 응답에는 예전 칸('product', 'current')도 그대로 두고, 두 상품을 담은 'products'/'currents'를 더 줍니다.

-- 아직 끝나지 않은 상품들(정액권 먼저)
create or replace function public.current_products(uid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.product_json(id) order by (kind = 'count'), start_date, id), '[]'::jsonb)
    from public.products where user_id = uid and end_date >= public.app_today()
$$;

-- 그 날짜에 쓸 수 있는(기간 안) 상품들(정액권 먼저)
create or replace function public.products_on(uid bigint, d date) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.product_json(id) order by (kind = 'count'), id), '[]'::jsonb)
    from public.products where user_id = uid and start_date <= d and d <= end_date
$$;

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
    if fok and cok then
      return jsonb_build_object('fail', public.fail('정액권과 횟수권 중 어느 것을 사용할지 선택하십시오.')
        || jsonb_build_object('choose', true, 'options', jsonb_build_array(public.product_json(f.id), public.product_json(c.id))));
    elsif fok then
      return jsonb_build_object('pid', f.id, 'note', '횟수권 ' || c.total_count || '회를 모두 사용해 정액권으로 예약했습니다.');
    elsif cok then
      return jsonb_build_object('pid', c.id, 'note', '정액권 하루 이용 횟수(' || f.daily_limit || '회)를 모두 사용해 횟수권으로 예약했습니다.');
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

-- 공개 예약: p_kind(선택) 추가
drop function if exists public.reserve(date, int, text, text, boolean, text);
create or replace function public.reserve(p_date date, p_hour int, p_name text, p_pw text, p_consent boolean, p_mode text,
                                          p_kind text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n text := public.norm_name(p_name); t date := public.app_today();
  ext boolean := p_mode = 'ext'; uid bigint; pid bigint; p public.products; prob jsonb; rid bigint; c record; pk jsonb := '{}';
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

  pk := public.pick_product(uid, p_date, nullif(p_kind, ''), false);
  if pk ? 'fail' then return pk->'fail'; end if;
  pid := (pk->>'pid')::bigint;
  if pid is null and not ext then
    if public.stu_day_taken(p_date, uid, n) then
      return public.fail('하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
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
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end, 'note', pk->>'note');
end $$;

-- 관리자 예약: p_kind(선택) 추가
drop function if exists public.admin_reserve(date, int, text, bigint, boolean, boolean, text);
create or replace function public.admin_reserve(p_date date, p_hour int, p_name text, p_user_id bigint, p_ext boolean, p_super boolean,
                                                p_roster_no text default null, p_kind text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name); t date := public.app_today(); prob jsonb; rid bigint;
  u public.users; uid bigint; ext boolean; h text; sup boolean := coalesce(p_super, false); pid bigint; p public.products; pk jsonb := '{}';
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
    pk := public.pick_product(uid, p_date, nullif(p_kind, ''), true);
    if pk ? 'fail' then return pk->'fail'; end if;
    pid := (pk->>'pid')::bigint;
    if pid is not null then
      select * into p from public.products where id = pid;
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
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end, 'note', pk->>'note');
end $$;

-- 이용자 정보: 'currents'(아직 끝나지 않은 상품들) 추가
create or replace function public.user_json(uid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name, 'phone', u.phone, 'part', u.part, 'memo', u.memo,
    'status', u.status, 'status_at', u.status_at, 'created_at', u.created_at,
    'current', public.product_json(public.current_product(u.id)),
    'currents', public.current_products(u.id),
    'last', public.product_json((select id from public.products where user_id = u.id order by end_date desc, id desc limit 1)),
    'last_used', public.user_last_used(u.id), 'dormant', public.user_dormant(u.id),
    'black_reason', u.black_reason, 'black_count', u.black_count, 'black_at', u.black_at, 'black_restored_at', u.black_restored_at,
    'roster_no', u.roster_no, 'roster_in', u.roster_no is not null and exists (select 1 from public.roster r where r.reg_no = u.roster_no))
  from public.users u where u.id = uid
$$;

-- 상품 입력 확인(종류 한 개씩). 결과 null이면 통과
create or replace function public.prod_items(p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  -- 'prods' 배열이 있으면 그것을, 없으면 예전 'prod' 하나를 배열로
  select case when jsonb_typeof(p->'prods') = 'array' then p->'prods'
              when nullif(p->'prod', 'null'::jsonb) is not null then jsonb_build_array(p->'prod')
              else '[]'::jsonb end
$$;

create or replace function public.admin_create_user(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f jsonb; t text := p->>'type'; prs jsonb := public.prod_items(p); pr jsonb; chk jsonb; uid bigint; h text;
  s date; days int; rno text := nullif(trim(coalesce(p->>'roster_no', '')), ''); r public.roster;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if rno is not null then
    if t <> 'stu' then return public.fail('명부 연결은 재원생만 할 수 있습니다.'); end if;
    select * into r from public.roster where reg_no = rno;
    if not found then return public.fail('명부에 없는 등록번호입니다. 명부를 다시 찾아 고르십시오.'); end if;
    if exists (select 1 from public.users where roster_no = rno) then return public.fail('이 명부 학생은 이미 등록되어 있습니다. 이용자 현황에서 찾아 수정하십시오.'); end if;
    f := public.check_user_fields(p - 'pw', false);
    if not (f->>'ok')::boolean then return f; end if;
    if f->>'name' <> r.name then return public.fail('이름이 명부(' || r.name || ')와 다릅니다.'); end if;
    h := r.pw_hash;
  else
    f := public.check_user_fields(p, true);
    if not (f->>'ok')::boolean then return f; end if;
    if exists (select 1 from public.users where type = t and name = f->>'name' and public.pw_ok(p->>'pw', pw_hash)) then
      return public.fail('같은 이름과 비밀번호로 등록된 이용자가 이미 있습니다. 다른 비밀번호를 사용하십시오.'); end if;
    h := public.hash_pw(p->>'pw');
  end if;
  if jsonb_array_length(prs) > 2 then return public.fail('정액권과 횟수권은 한 개씩만 등록할 수 있습니다.'); end if;
  if jsonb_array_length(prs) = 2 and prs->0->>'kind' = prs->1->>'kind' then
    return public.fail('같은 종류의 상품은 한 개만 등록할 수 있습니다.'); end if;
  for pr in select value from jsonb_array_elements(prs) loop
    chk := public.check_product(t, pr->>'kind', (pr->>'start')::date, (pr->>'days')::int, (pr->>'limit')::int, (pr->>'total')::int);
    if chk is not null then return chk; end if;
  end loop;
  insert into public.users (type, name, pw_hash, phone, part, memo, roster_no)
  values (t, f->>'name', h, f->>'phone', f->>'part', f->>'memo', rno) returning id into uid;
  if rno is null then
    update public.reservations set user_id = uid where user_id is null and name = f->>'name' and public.pw_ok(p->>'pw', pw_hash);
  end if;
  for pr in select value from jsonb_array_elements(prs) loop
    s := (pr->>'start')::date; days := (pr->>'days')::int;
    insert into public.products (user_id, kind, start_date, end_date, daily_limit, total_count)
    values (uid, pr->>'kind', s, s + days - 1,
            case when pr->>'kind' = 'flat' then (pr->>'limit')::int end,
            case when pr->>'kind' = 'count' then (pr->>'total')::int end);
  end loop;
  perform public.fail_reset(k) from unnest(array[f->>'name', 'ext:' || (f->>'name'), 'stu:' || (f->>'name'), 'info:' || (f->>'name')]) k;
  perform public.audit('admin', 'create_user', jsonb_build_object('id', uid));
  return jsonb_build_object('ok', true, 'user', public.user_json(uid));
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
  return public.fail('입력값을 확인하십시오.');
end $$;

-- 이용자 수정: 'prods' 배열 [{id(있으면 기존 상품 수정), kind(새 상품), start, days, limit|total}]
-- 예전 형식(edit_prod = 지금 상품 수정, new_prod = 새 상품)도 받음.
create or replace function public.admin_update_user(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u public.users; f jsonb; nt text := p->>'type'; pw text := nullif(p->>'pw', ''); c public.products;
  items jsonb := '[]'; it jsonb; chk jsonb; s date; days int; e date; lim int; tot int; h text; used int; oldname text;
  k text; kinds text[] := '{}';
begin
  if not public.is_admin() then return public.not_admin(); end if;
  select * into u from public.users where id = (p->>'id')::bigint for update;
  if not found then return public.fail('없는 이용자입니다.', true); end if;
  f := public.check_user_fields(p, false);
  if not (f->>'ok')::boolean then return f; end if;
  if pw is not null and exists (select 1 from public.users where id <> u.id and type = nt and name = f->>'name'
                                 and public.pw_ok(pw, pw_hash)) then
    return public.fail('같은 이름과 비밀번호로 등록된 이용자가 이미 있습니다. 다른 비밀번호를 사용하십시오.'); end if;

  if jsonb_typeof(p->'prods') = 'array' then
    items := p->'prods';
  else
    if nullif(p->'edit_prod', 'null'::jsonb) is not null and public.current_product(u.id) is not null then
      items := items || jsonb_build_array((p->'edit_prod') || jsonb_build_object('id', public.current_product(u.id)));
    elsif nullif(p->'new_prod', 'null'::jsonb) is not null and public.current_product(u.id) is null then
      items := items || jsonb_build_array((p->'new_prod') - 'id'::text);
    end if;
  end if;
  if jsonb_array_length(items) > 2 then return public.fail('정액권과 횟수권은 한 개씩만 등록할 수 있습니다.'); end if;

  -- 1) 모두 확인
  for it in select value from jsonb_array_elements(items) loop
    s := (it->>'start')::date; days := (it->>'days')::int;
    if it ? 'id' and nullif(it->>'id', '') is not null then
      select * into c from public.products where id = (it->>'id')::bigint and user_id = u.id and end_date >= public.app_today();
      if not found then return public.fail('이미 끝났거나 없는 상품입니다. 화면을 새로 고치십시오.', true); end if;
      k := c.kind;
      lim := case when k = 'flat' then (it->>'limit')::int end;
      tot := case when k = 'count' then (it->>'total')::int end;
      chk := public.check_product(nt, k, s, days, lim, tot);
      if chk is not null then return chk; end if;
      e := s + days - 1;
      used := public.product_used(c.id);
      if k = 'count' and tot < used then
        return public.fail('이미 ' || used || '회 사용했습니다. 총 이용 횟수는 ' || used || '회 이상이어야 합니다.'); end if;
      if exists (select 1 from public.products where user_id = u.id and id <> c.id and kind = k and start_date <= e and end_date >= s
                   and end_date >= public.app_today()) then
        return public.fail('이 이용자의 다른 ' || case k when 'flat' then '정액권' else '횟수권' end || '과 기간이 겹칩니다.'); end if;
    else
      k := it->>'kind';
      chk := public.check_product(nt, k, s, days, (it->>'limit')::int, (it->>'total')::int);
      if chk is not null then return chk; end if;
      -- 같은 종류의 아직 끝나지 않은 상품이 있으면 새로 추가할 수 없음(다른 종류와는 겹쳐도 됨, 033)
      if exists (select 1 from public.products where user_id = u.id and kind = k and end_date >= s
                   and end_date >= public.app_today()) then
        return public.fail('이미 사용 중이거나 시작 예정인 ' || case k when 'flat' then '정액권' else '횟수권' end
          || '이 있습니다. 같은 종류는 한 개만 쓸 수 있습니다.'); end if;
    end if;
    if k = any(kinds) then return public.fail('같은 종류의 상품은 한 개만 등록할 수 있습니다.'); end if;
    kinds := kinds || k;
  end loop;

  -- 2) 저장
  oldname := u.name;
  h := case when pw is not null then public.hash_pw(pw) end;
  update public.users set type = nt, name = f->>'name', phone = f->>'phone', part = f->>'part', memo = f->>'memo',
         pw_hash = coalesce(h, pw_hash) where id = u.id;
  update public.reservations set name = f->>'name', pw_hash = coalesce(h, pw_hash),
         is_ext = case when nt <> u.type and status = 'confirmed' and not public.slot_ended(date, hour) then nt = 'ext' else is_ext end,
         updated_at = now()
   where user_id = u.id;
  for it in select value from jsonb_array_elements(items) loop
    s := (it->>'start')::date; days := (it->>'days')::int;
    if it ? 'id' and nullif(it->>'id', '') is not null then
      select * into c from public.products where id = (it->>'id')::bigint for update;
      update public.products set start_date = s, end_date = s + days - 1,
             daily_limit = case when c.kind = 'flat' then (it->>'limit')::int end,
             total_count = case when c.kind = 'count' then (it->>'total')::int end
       where id = c.id;
    else
      insert into public.products (user_id, kind, start_date, end_date, daily_limit, total_count)
      values (u.id, it->>'kind', s, s + days - 1,
              case when it->>'kind' = 'flat' then (it->>'limit')::int end,
              case when it->>'kind' = 'count' then (it->>'total')::int end);
    end if;
  end loop;
  perform public.fail_reset(k2) from unnest(array[oldname, 'ext:' || oldname, 'stu:' || oldname, 'info:' || oldname,
    f->>'name', 'ext:' || (f->>'name'), 'stu:' || (f->>'name'), 'info:' || (f->>'name')]) k2;
  perform public.audit('admin', 'update_user', jsonb_build_object('id', u.id));
  return jsonb_build_object('ok', true, 'user', public.user_json(u.id));
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
  return public.fail('입력값을 확인하십시오.');
end $$;

-- 예약 창 상품 정보: 'products'(아직 끝나지 않은 상품들) 추가
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
    'products', public.current_products(uid)) || ro;
end $$;

-- 내 예약: 'products' 추가
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
    ros := exists (select 1 from public.roster r where r.name = n and public.pw_ok(p_pw, r.pw_hash));
    if not ros then
      perform public.fail_hit(n);
      return public.fail('이름 또는 비밀번호가 일치하지 않거나 예약이 없습니다.');
    end if;
  end if;
  perform public.fail_reset(n);
  if uid is not null then cur := public.current_product(uid); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'list', coalesce(list, '[]'),
    'user_type', coalesce((select type from public.users where id = uid), case when ros then 'stu' end),
    'product', public.product_json(cur),
    'products', case when uid is not null then public.current_products(uid) else '[]'::jsonb end,
    'old_products', coalesce((select jsonb_agg(public.product_json(id) order by end_date desc) from public.products
                     where user_id = uid and end_date < public.app_today() and end_date >= kf), '[]'));
end $$;

-- 관리자 예약 창 이름 찾기: 'products'(그 날짜에 쓸 수 있는 상품들) 추가
create or replace function public.admin_find_users(p_name text, p_date date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n text := public.norm_name(p_name);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'name', n,
    'day_taken', public.stu_day_taken(p_date, null, n),
    'users', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name,
                 'phone4', right(u.phone, 4), 'part', u.part, 'status', u.status,
                 'day_taken', u.type = 'stu' and public.stu_day_taken(p_date, u.id, n),
                 'product', public.product_json(public.product_on(u.id, p_date)),
                 'products', public.products_on(u.id, p_date)) order by u.id desc)
               from public.users u where u.name = n and u.status in ('active', 'blacklisted')), '[]'));
end $$;

revoke execute on function public.current_products(bigint) from public, anon, authenticated;
revoke execute on function public.products_on(bigint, date) from public, anon, authenticated;
revoke execute on function public.pick_product(bigint, date, text, boolean) from public, anon, authenticated;
revoke execute on function public.prod_items(jsonb) from public, anon, authenticated;
revoke execute on function public.reserve(date, int, text, text, boolean, text, text) from public, anon, authenticated;
revoke execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean, text, text) from public, anon, authenticated;
revoke execute on function public.user_json(bigint) from public, anon, authenticated;
revoke execute on function public.admin_create_user(jsonb) from public, anon, authenticated;
revoke execute on function public.admin_update_user(jsonb) from public, anon, authenticated;
revoke execute on function public.product_info(text, text, text) from public, anon, authenticated;
revoke execute on function public.my_reservations(text, text) from public, anon, authenticated;
revoke execute on function public.admin_find_users(text, date) from public, anon, authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text, text) to anon, authenticated;
grant execute on function public.product_info(text, text, text) to anon, authenticated;
grant execute on function public.my_reservations(text, text) to anon, authenticated;
grant execute on function public.admin_reserve(date, int, text, bigint, boolean, boolean, text, text) to authenticated;
grant execute on function public.admin_create_user(jsonb) to authenticated;
grant execute on function public.admin_update_user(jsonb) to authenticated;
grant execute on function public.admin_find_users(text, date) to authenticated;
