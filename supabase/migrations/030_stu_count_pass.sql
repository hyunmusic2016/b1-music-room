-- 030_stu_count_pass.sql : 재원생도 횟수권 사용(2026-11-02 사용자 요청)
-- 사용자 결정:
--   · 재원생 횟수권도 일반회원 횟수권과 같음: 기간 안에 총 N회, 하루 제한 없음(상품 없는 재원생만 하루 1회).
--   · 명부 확인이 켜져 있어도, 그 날짜에 기간이 맞는 횟수권이 있는 등록 재원생은 명부에 없어도 예약 가능(정액권과 같은 예외).
-- 바뀐 함수:
--   · check_product        : "재원생은 정액권만" 제한 삭제(이용자 등록·수정에서 재원생 횟수권 등록 가능)
--   · admin_update_user    : 횟수권을 쓰는 일반회원을 재원생으로 바꾸는 것 허용(내용은 013과 같고 막던 두 줄만 뺌)
--   · stu_allowed          : 명부 예외에 횟수권 포함(다 쓴 경우는 이어서 "횟수권 N회를 모두 사용했습니다" 안내)
--   · reserve              : 재원생 예약 때 정액권뿐 아니라 횟수권도 찾아 1회 차감(내용은 025와 같고 상품 종류 조건만 바뀜)
--   · admin_set_prices / price_info : 이용료 표에 재원생 횟수권(stu_count) 칸 추가
-- 그대로인 것: move_own(예약 변경)·admin_reserve(관리자 예약)·cancel·product_info·내 예약은 이미 상품 종류와 관계없이 동작.

create or replace function public.check_product(t text, kind text, s date, days int, lim int, tot int) returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  if kind not in ('flat','count') then return public.fail('정액권·횟수권 종류를 확인하십시오.'); end if;
  -- 030: 재원생도 횟수권 가능(전에는 정액권만)
  if s is null or days is null or days not between 1 and 999 then
    return public.fail('시작일과 기간(일)을 확인하십시오. 기간은 1 이상의 숫자로 입력하십시오.'); end if;
  if kind = 'flat' and (lim is null or lim not between 1 and 99) then
    return public.fail('하루 이용 횟수를 1~99 사이의 숫자로 입력하십시오.'); end if;
  if kind = 'count' and (tot is null or tot not between 1 and 999) then
    return public.fail('총 이용 횟수를 1~999 사이의 숫자로 입력하십시오.'); end if;
  return null;
end $$;

create or replace function public.admin_update_user(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u public.users; f jsonb; nt text := p->>'type'; pw text := nullif(p->>'pw', ''); c public.products;
  ep jsonb := nullif(p->'edit_prod', 'null'::jsonb); np jsonb := nullif(p->'new_prod', 'null'::jsonb);
  chk jsonb; s date; days int; e date; lim int; tot int; h text; used int; oldname text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  select * into u from public.users where id = (p->>'id')::bigint for update;
  if not found then return public.fail('없는 이용자입니다.', true); end if;
  f := public.check_user_fields(p, false);
  if not (f->>'ok')::boolean then return f; end if;
  select * into c from public.products where id = public.current_product(u.id) for update;
  -- 030: 횟수권 사용 중인 일반회원도 재원생으로 바꿀 수 있음(재원생도 횟수권 가능)
  if pw is not null and exists (select 1 from public.users where id <> u.id and type = nt and name = f->>'name'
                                 and public.pw_ok(pw, pw_hash)) then
    return public.fail('같은 이름과 비밀번호로 등록된 이용자가 이미 있습니다. 다른 비밀번호를 사용하십시오.'); end if;
  if c.id is not null and ep is not null then
    s := (ep->>'start')::date; days := (ep->>'days')::int;
    lim := case when c.kind = 'flat' then (ep->>'limit')::int end;
    tot := case when c.kind = 'count' then (ep->>'total')::int end;
    chk := public.check_product(nt, c.kind, s, days, lim, tot);
    if chk is not null then return chk; end if;
    e := s + days - 1;
    used := public.product_used(c.id);
    if c.kind = 'count' and tot < used then
      return public.fail('이미 ' || used || '회 사용했습니다. 총 이용 횟수는 ' || used || '회 이상이어야 합니다.'); end if;
    if exists (select 1 from public.products where user_id = u.id and id <> c.id and start_date <= e and end_date >= s
                 and end_date >= public.app_today()) then  -- 이미 끝난 상품은 겹쳐도 됨(013)
      return public.fail('이 이용자의 다른 상품과 기간이 겹칩니다.'); end if;
  elsif c.id is null and np is not null then
    s := (np->>'start')::date; days := (np->>'days')::int;
    chk := public.check_product(nt, np->>'kind', s, days, (np->>'limit')::int, (np->>'total')::int);
    if chk is not null then return chk; end if;
    if exists (select 1 from public.products where user_id = u.id and end_date >= s
                 and end_date >= public.app_today()) then  -- 이미 끝난 상품은 겹쳐도 됨(013)
      return public.fail('시작일이 지난 상품 기간과 겹칩니다. 시작일을 확인하십시오.'); end if;
  end if;

  -- 여기부터 저장
  oldname := u.name;
  h := case when pw is not null then public.hash_pw(pw) end;
  update public.users set type = nt, name = f->>'name', phone = f->>'phone', part = f->>'part', memo = f->>'memo',
         pw_hash = coalesce(h, pw_hash) where id = u.id;
  -- 이 이용자의 예약도 이름·비밀번호를 함께 바꾸고, 구분이 바뀌면 아직 끝나지 않은 확정 예약의 구분도 바꿉니다.
  update public.reservations set name = f->>'name', pw_hash = coalesce(h, pw_hash),
         is_ext = case when nt <> u.type and status = 'confirmed' and not public.slot_ended(date, hour) then nt = 'ext' else is_ext end,
         updated_at = now()
   where user_id = u.id;
  if c.id is not null and ep is not null then
    update public.products set start_date = s, end_date = e, daily_limit = lim, total_count = tot where id = c.id;
  elsif c.id is null and np is not null then
    insert into public.products (user_id, kind, start_date, end_date, daily_limit, total_count)
    values (u.id, np->>'kind', s, s + days - 1,
            case when np->>'kind' = 'flat' then (np->>'limit')::int end,
            case when np->>'kind' = 'count' then (np->>'total')::int end);
  end if;
  perform public.fail_reset(k) from unnest(array[oldname, 'ext:' || oldname, 'stu:' || oldname, 'info:' || oldname,
    f->>'name', 'ext:' || (f->>'name'), 'stu:' || (f->>'name'), 'info:' || (f->>'name')]) k;
  perform public.audit('admin', 'update_user', jsonb_build_object('id', u.id));
  return jsonb_build_object('ok', true, 'user', public.user_json(u.id));
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
  return public.fail('입력값을 확인하십시오.');
end $$;

create or replace function public.stu_allowed(n text, pw text, d date) returns boolean
language sql stable security definer set search_path = '' as $$
  select not public.roster_on()
      or exists (select 1 from public.roster r where r.name = n and public.pw_ok(pw, r.pw_hash))
      or exists (select 1 from public.users u join public.products p on p.user_id = u.id
                  where u.type = 'stu' and u.status = 'active' and u.name = n and p.kind in ('flat','count')
                    and d between p.start_date and p.end_date and public.pw_ok(pw, u.pw_hash))
$$;

create or replace function public.reserve(p_date date, p_hour int, p_name text, p_pw text, p_consent boolean, p_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n text := public.norm_name(p_name); t date := public.app_today();
  ext boolean := p_mode = 'ext'; uid bigint; pid bigint; p public.products; prob jsonb; rid bigint; c record;
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
    -- 재원생 명부 확인(025): 명부와 맞거나 그 날짜의 정액권이 있어야 함. 틀린 횟수는 세어 5번이면 15분 잠금
    if public.is_locked('stu:' || n) then return public.fail('시도 횟수를 초과했습니다. 15분 뒤에 다시 시도하십시오.'); end if;
    if not public.stu_allowed(n, p_pw, p_date) then
      perform public.fail_hit('stu:' || n);
      return public.fail('재원생 명부에서 확인되지 않습니다. 이름과 비밀번호(학원에 등록된 전화번호 뒤 4자리)를 확인하시거나 관리자에게 문의하십시오.');
    end if;
    perform public.fail_reset('stu:' || n);
  end if;

  prob := public.slot_problem(p_date, p_hour);
  if prob is not null then return prob; end if;

  if ext then
    pid := public.product_on(uid, p_date);
  else
    for c in select p2.id as pid, u.id as uid, u.pw_hash from public.products p2 join public.users u on u.id = p2.user_id
              where u.type = 'stu' and u.status = 'active' and u.name = n and p2.kind in ('flat','count')  -- 030: 재원생 횟수권도
                and p_date between p2.start_date and p2.end_date loop
      if public.pw_ok(p_pw, c.pw_hash) then pid := c.pid; uid := c.uid; exit; end if;
    end loop;
    if pid is null then
      uid := public.find_user('stu', n, p_pw);
      if public.stu_day_taken(p_date, uid, n) then
        return public.fail('하루에 한 번만 예약할 수 있습니다. 해당 날짜에 이미 예약이 있습니다.'); end if;
    end if;
  end if;

  if pid is not null then
    select * into p from public.products where id = pid for update;
    if p.kind = 'count' and public.product_used(p.id) >= p.total_count then
      return public.fail('횟수권 ' || p.total_count || '회를 모두 사용했습니다. 관리자에게 문의하십시오.'); end if;
    if p.kind = 'flat' and public.product_used(p.id, p_date) >= p.daily_limit then
      return public.fail('정액권 하루 이용 횟수(' || p.daily_limit || '회)를 모두 사용했습니다.'); end if;
  end if;

  begin
    insert into public.reservations (date, hour, name, pw_hash, user_id, is_ext, product_id, product_kind)
    values (p_date, p_hour, n, public.hash_pw(p_pw), uid, ext, p.id, p.kind) returning id into rid;
  exception when unique_violation then
    return public.fail('다른 분이 방금 예약한 시간입니다. 다른 시간을 선택하십시오.', true);
  end;
  perform public.audit('public', 'reserve', jsonb_build_object('id', rid));
  return jsonb_build_object('ok', true, 'id', rid, 'date', p_date, 'hour', p_hour, 'name', n, 'ext', ext,
    'prod', p.kind, 'product', case when p.id is not null then public.product_json(p.id) end);
end $$;

create or replace function public.admin_set_prices(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fee text := replace(replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', ''), ' ', '');
  k text; lbl text; maxn int; arr jsonb; row jsonb; n text; pr text; out jsonb := '{}'; lst jsonb; i int;
  old jsonb; old_fee text; upd text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('1회 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  foreach k in array array['ext_flat','ext_count','stu_flat','stu_count'] loop
    lbl := case k when 'ext_flat' then '일반회원 정액권' when 'ext_count' then '일반회원 횟수권' when 'stu_flat' then '재원생 정액권' else '재원생 횟수권' end;
    maxn := case when k in ('ext_count','stu_count') then 999 else 99 end;
    arr := coalesce(p->k, '[]'::jsonb);
    if jsonb_typeof(arr) <> 'array' then return public.fail('잘못된 요청입니다.'); end if;
    if jsonb_array_length(arr) > 10 then return public.fail(lbl || '은 10개까지 만들 수 있습니다.'); end if;
    lst := '[]'; i := 0;
    for row in select value from jsonb_array_elements(arr) loop
      i := i + 1;
      n := replace(replace(trim(coalesce(row->>'n', '')), '회', ''), ' ', '');
      pr := replace(replace(replace(trim(coalesce(row->>'price', '')), ',', ''), '원', ''), ' ', '');
      continue when n = '' and pr = '';
      if n !~ '^[0-9]{1,3}$' or n::int < 1 or n::int > maxn then
        return public.fail(lbl || ' ' || i || '번째 줄: 횟수를 1~' || maxn || ' 사이 숫자로 입력하십시오.'); end if;
      if pr !~ '^[0-9]{1,7}$' then
        return public.fail(lbl || ' ' || i || '번째 줄: 가격을 숫자로 입력하십시오.'); end if;
      lst := lst || jsonb_build_array(jsonb_build_object('n', n::int, 'price', pr));
    end loop;
    out := out || jsonb_build_object(k, lst);
  end loop;
  -- 바뀐 것이 있을 때만 수정 날짜를 오늘로
  old := coalesce((select value from public.settings where key = 'price_list'), '{}'::jsonb);
  old_fee := coalesce((select value->>'fee' from public.settings where key = 'pay_account'), '');
  upd := old->>'updated_at';
  -- 030: 예전 표에 stu_count가 없으면 빈 목록으로 보고 비교(새 칸이 생긴 것만으로 날짜가 바뀌지 않게)
  old := old || jsonb_build_object('stu_count', coalesce(old->'stu_count', '[]'::jsonb));
  if upd is null or (old - 'updated_at') is distinct from out or old_fee is distinct from fee then
    upd := public.app_today()::text;
  end if;
  out := out || jsonb_build_object('updated_at', upd);
  insert into public.settings (key, value) values ('price_list', out)
    on conflict (key) do update set value = excluded.value;
  update public.settings set value = value || jsonb_build_object('fee', fee) where key = 'pay_account';
  if not found then
    insert into public.settings (key, value) values ('pay_account', jsonb_build_object('bank','','holder','','number','','fee',fee));
  end if;
  perform public.audit('admin', 'price_list', '{}'::jsonb);
  return public.price_info();
end $$;

create or replace function public.price_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'fee', coalesce((select value->>'fee' from public.settings where key = 'pay_account'), ''))
    || '{"ext_flat":[],"ext_count":[],"stu_flat":[],"stu_count":[]}'::jsonb
    || coalesce((select value from public.settings where key = 'price_list'), '{}'::jsonb)
$$;

revoke execute on function public.check_product(text, text, date, int, int, int) from public, anon, authenticated;
revoke execute on function public.admin_update_user(jsonb) from public, anon, authenticated;
revoke execute on function public.stu_allowed(text, text, date) from public, anon, authenticated;
revoke execute on function public.reserve(date, int, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function public.admin_set_prices(jsonb) from public, anon, authenticated;
revoke execute on function public.price_info() from public, anon, authenticated;
grant execute on function public.admin_update_user(jsonb) to authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
grant execute on function public.admin_set_prices(jsonb) to authenticated;
grant execute on function public.price_info() to anon, authenticated;
