-- 025_roster.sql : 재원생 명부(구글 시트 "수강생대장") 연동(2026-11-02 사용자 결정)
-- · 구글 시트의 Apps Script가 1시간마다(또는 [지금 반영]) 학생의 등록번호·이름·전화번호 뒤 4자리만 roster_sync로 보냅니다.
--   전체 전화번호·보호자 이름·파트 등은 받지 않습니다. 뒤 4자리는 비밀번호처럼 bcrypt로 바꿔 저장합니다.
-- · 받을 때마다 명부 전체를 새 내용으로 바꿉니다(시트에서 빠진 학생은 명부에서도 빠짐).
--   안전장치: 0명이거나, 기존 10명 이상인데 한 번에 절반 넘게 빠지면 거절(시트 오류 대비). p_force=true면 그대로 반영.
-- · "명부 확인"(settings.roster.check)이 켜져 있으면 재원생 예약은 이름+비밀번호가 명부와 맞을 때만 됩니다.
--   예외(사용자 결정 (나)): 그 날짜에 쓸 수 있는 정액권이 있는 등록 재원생은 명부에 없어도 예약 가능.
--   관리자 예약(일반예약·슈퍼패스)은 명부를 보지 않습니다. 이미 잡힌 예약은 명부에서 빠져도 그대로 둡니다.
-- · 등록 재원생(users)과 명부 학생을 등록번호(users.roster_no)로 연결합니다. 연결된 학생의 비밀번호는 항상 명부의 뒤 4자리와 같게 맞춥니다.
-- · 연동 열쇠는 관리자가 화면에서 만들고(한 번만 보여 줌), 서버에는 bcrypt로 바꾼 값만 저장합니다.

create table if not exists public.roster (
  reg_no text primary key,
  name text not null,
  pw_hash text not null,
  synced_at timestamptz not null default now()
);
alter table public.roster enable row level security; -- 정책 없음: 직접 읽기·쓰기 모두 막고 함수로만 다룸
create index if not exists roster_name_idx on public.roster (name);

alter table public.users add column if not exists roster_no text;
create unique index if not exists users_roster_no_uniq on public.users (roster_no) where roster_no is not null;

-- 재원생이 아니게 되면(일반회원으로 바꿈) 명부 연결을 풉니다.
create or replace function public.users_roster_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.type <> 'stu' then new.roster_no := null; end if;
  return new;
end $$;
drop trigger if exists users_roster_guard on public.users;
create trigger users_roster_guard before insert or update on public.users for each row execute function public.users_roster_guard();
revoke execute on function public.users_roster_guard() from public, anon, authenticated;

insert into public.settings (key, value) values ('roster', '{"check":false,"token_hash":null,"synced_at":null,"count":0}')
  on conflict (key) do nothing;

create or replace function public.roster_on() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select (value->>'check')::boolean from public.settings where key = 'roster'), false)
$$;

-- 재원생 예약을 해도 되는가: 명부 확인이 꺼져 있으면 항상 됨. 켜져 있으면 명부와 맞거나, 그 날짜에 쓸 수 있는 정액권이 있어야 함.
create or replace function public.stu_allowed(n text, pw text, d date) returns boolean
language sql stable security definer set search_path = '' as $$
  select not public.roster_on()
      or exists (select 1 from public.roster r where r.name = n and public.pw_ok(pw, r.pw_hash))
      or exists (select 1 from public.users u join public.products p on p.user_id = u.id
                  where u.type = 'stu' and u.status = 'active' and u.name = n and p.kind = 'flat'
                    and d between p.start_date and p.end_date and public.pw_ok(pw, u.pw_hash))
$$;

-- 시트 → 서버. p_rows = [{no, name, pw4}]. 연동 열쇠가 맞을 때만.
create or replace function public.roster_sync(p_token text, p_rows jsonb, p_force boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  cfg jsonb := coalesce((select value from public.settings where key = 'roster'), '{}'::jsonb);
  row jsonb; no text; n text; pw text; o public.roster; u public.users; h text; i int;
  nos text[] := '{}'; names text[] := '{}'; pws text[] := '{}'; skipped text[] := '{}'; valid int := 0; before int; added int := 0; changed int := 0; removed int := 0; linked int := 0;
begin
  if public.is_locked('roster:sync') then return public.fail('연동 열쇠가 여러 번 틀려 15분 동안 막혔습니다.'); end if;
  if cfg->>'token_hash' is null or not public.pw_ok(p_token, cfg->>'token_hash') then
    perform public.fail_hit('roster:sync');
    return public.fail('연동 열쇠가 맞지 않습니다. 관리자 화면에서 새 열쇠를 만들어 넣으십시오.');
  end if;
  perform public.fail_reset('roster:sync');
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 3000 then return public.fail('잘못된 명부입니다.'); end if;
  perform pg_advisory_xact_lock(hashtext('roster:sync'));

  -- 먼저 올바른 줄만 추림(등록번호·이름·뒤 4자리). 같은 등록번호가 또 나오면 처음 것만.
  for row in select value from jsonb_array_elements(p_rows) loop
    no := left(trim(coalesce(row->>'no', '')), 20);
    n := public.norm_name(trim(coalesce(row->>'name', '')));
    pw := trim(coalesce(row->>'pw4', ''));
    if no = '' or not public.valid_name(n) or not public.valid_pw(pw) or no = any(nos) then
      skipped := skipped || coalesce(nullif(no, ''), '(번호 없음)'); continue; end if;
    nos := nos || no; names := names || n; pws := pws || pw; valid := valid + 1;
  end loop;

  select count(*) into before from public.roster;
  if valid = 0 then return public.fail('보낸 명부에 올바른 학생이 없습니다. 시트의 칸 이름(등록번호·이름/보호자·원생 전화번호)을 확인하십시오.'); end if;
  if not coalesce(p_force, false) and before >= 10 and valid < before * 0.5 then
    return public.fail('한 번에 절반 넘게 빠져서 반영하지 않았습니다(기존 ' || before || '명 → ' || valid || '명). 시트를 확인하시고, 맞으면 [강제로 반영]을 쓰십시오.');
  end if;

  -- 빠진 학생 지우기
  delete from public.roster r where not (r.reg_no = any(nos));
  get diagnostics removed = row_count;

  for i in 1 .. valid loop
    no := nos[i]; n := names[i]; pw := pws[i];
    select * into o from public.roster where reg_no = no;
    if not found then
      h := public.hash_pw(pw);
      insert into public.roster (reg_no, name, pw_hash) values (no, n, h); added := added + 1;
    elsif o.name is distinct from n or not public.pw_ok(pw, o.pw_hash) then
      h := case when public.pw_ok(pw, o.pw_hash) then o.pw_hash else public.hash_pw(pw) end;
      update public.roster set name = n, pw_hash = h, synced_at = now() where reg_no = no; changed := changed + 1;
    else
      h := o.pw_hash;
      update public.roster set synced_at = now() where reg_no = no;
    end if;
    -- 연결된 재원생: 비밀번호를 명부의 뒤 4자리와 같게(그 사람의 예약도 함께)
    select * into u from public.users where roster_no = no;
    if found then
      if not public.pw_ok(pw, u.pw_hash) then
        update public.users set pw_hash = h where id = u.id;
        update public.reservations set pw_hash = h, updated_at = now() where user_id = u.id;
      end if;
    else
      -- 아직 연결 안 된 등록 재원생 중 이름·비밀번호가 명부와 똑같은 사람이 딱 한 명이면 자동 연결
      if (select count(*) from public.users where type = 'stu' and roster_no is null and name = n and public.pw_ok(pw, pw_hash)) = 1 then
        update public.users set roster_no = no where type = 'stu' and roster_no is null and name = n and public.pw_ok(pw, pw_hash);
        linked := linked + 1;
      end if;
    end if;
  end loop;

  update public.settings set value = value || jsonb_build_object('synced_at', now(), 'count', valid) where key = 'roster';
  perform public.audit('sheet', 'roster_sync', jsonb_build_object('count', valid, 'added', added, 'changed', changed, 'removed', removed, 'linked', linked, 'skipped', cardinality(skipped)));
  return jsonb_build_object('ok', true, 'count', valid, 'added', added, 'changed', changed, 'removed', removed, 'linked', linked, 'skipped', to_jsonb(skipped));
end $$;

-- 관리자: 연동 상태(명부 인원, 마지막 반영, 열쇠 유무, 명부와 연결 안 된 재원생, 명부에서 빠진 연결 재원생)
create or replace function public.admin_roster_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cfg jsonb := coalesce((select value from public.settings where key = 'roster'), '{}'::jsonb);
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'check', coalesce((cfg->>'check')::boolean, false), 'has_token', cfg->>'token_hash' is not null,
    'synced_at', cfg->'synced_at', 'count', (select count(*) from public.roster),
    'unlinked', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name,
                   'prod', (select kind from public.products p where p.id = public.current_product(u.id)),
                   'in_roster', exists (select 1 from public.roster r where r.name = u.name)) order by u.name)
                 from public.users u where u.type = 'stu' and u.status = 'active' and u.roster_no is null), '[]'),
    'gone', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'no', u.roster_no,
                   'prod', (select kind from public.products p where p.id = public.current_product(u.id))) order by u.name)
                 from public.users u where u.roster_no is not null and not exists (select 1 from public.roster r where r.reg_no = u.roster_no)), '[]'));
end $$;

-- 관리자: 새 연동 열쇠(한 번만 돌려줌, 전에 쓰던 열쇠는 바로 못 씀)
create or replace function public.admin_roster_token() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare tk text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  if not public.is_admin() then return public.not_admin(); end if;
  update public.settings set value = value || jsonb_build_object('token_hash', public.hash_pw(tk)) where key = 'roster';
  perform public.fail_reset('roster:sync');
  perform public.audit('admin', 'roster_token', '{}'::jsonb);
  return jsonb_build_object('ok', true, 'token', tk);
end $$;

-- 관리자: 명부 확인 켜기/끄기(켜려면 명부가 한 명 이상 있어야 함)
create or replace function public.admin_set_roster_check(p_on boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if coalesce(p_on, false) and not exists (select 1 from public.roster) then
    return public.fail('명부가 비어 있습니다. 먼저 구글 시트에서 [지금 반영]으로 명부를 보내십시오.'); end if;
  update public.settings set value = value || jsonb_build_object('check', coalesce(p_on, false)) where key = 'roster';
  perform public.audit('admin', 'roster_check', jsonb_build_object('on', coalesce(p_on, false)));
  return public.admin_roster_status();
end $$;

-- 관리자: 이름으로 명부 찾기(이용자 등록·연결용). 등록번호와 이미 연결된 이용자 여부만(뒤 4자리는 주지 않음)
create or replace function public.admin_roster_find(p_name text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare n text := public.norm_name(trim(coalesce(p_name, '')));
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((select jsonb_agg(jsonb_build_object('no', r.reg_no, 'name', r.name,
           'linked', (select u.id from public.users u where u.roster_no = r.reg_no)) order by r.reg_no)
         from public.roster r where r.name = n), '[]'));
end $$;

-- 관리자: 등록 재원생을 명부 학생과 연결(비밀번호를 명부의 뒤 4자리로 바꾸고, 그 사람의 예약도 함께)
create or replace function public.admin_link_roster(p_user_id bigint, p_no text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u public.users; r public.roster;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  select * into u from public.users where id = p_user_id for update;
  if not found or u.type <> 'stu' then return public.fail('재원생만 명부와 연결할 수 있습니다.'); end if;
  select * into r from public.roster where reg_no = p_no;
  if not found then return public.fail('명부에 없는 등록번호입니다.'); end if;
  if r.name <> u.name then return public.fail('이름이 명부(' || r.name || ')와 다릅니다. 먼저 이용자 수정에서 이름을 명부와 같게 고치십시오.'); end if;
  if exists (select 1 from public.users where roster_no = p_no and id <> u.id) then return public.fail('이 명부 학생은 이미 다른 이용자와 연결되어 있습니다.'); end if;
  update public.users set roster_no = p_no, pw_hash = r.pw_hash where id = u.id;
  update public.reservations set pw_hash = r.pw_hash, updated_at = now() where user_id = u.id;
  perform public.audit('admin', 'link_roster', jsonb_build_object('id', u.id));
  return jsonb_build_object('ok', true, 'user', public.user_json(u.id));
end $$;

-- 이용자 정보 묶음에 명부 등록번호 추가(나머지는 016과 같음)
create or replace function public.user_json(uid bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', u.id, 'type', u.type, 'name', u.name, 'phone', u.phone, 'part', u.part, 'memo', u.memo,
    'status', u.status, 'status_at', u.status_at, 'created_at', u.created_at,
    'current', public.product_json(public.current_product(u.id)),
    'last', public.product_json((select id from public.products where user_id = u.id order by end_date desc, id desc limit 1)),
    'last_used', public.user_last_used(u.id), 'dormant', public.user_dormant(u.id),
    'black_reason', u.black_reason, 'black_count', u.black_count, 'black_at', u.black_at, 'black_restored_at', u.black_restored_at,
    'roster_no', u.roster_no, 'roster_in', u.roster_no is not null and exists (select 1 from public.roster r where r.reg_no = u.roster_no))
  from public.users u where u.id = uid
$$;

-- 이용자 등록: p.roster_no가 있으면(재원생만) 비밀번호 대신 명부의 뒤 4자리를 쓰고 명부와 연결(나머지는 003과 같음)
create or replace function public.admin_create_user(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f jsonb; t text := p->>'type'; pr jsonb := nullif(p->'prod', 'null'::jsonb); chk jsonb; uid bigint; h text;
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
  if pr is not null then
    s := (pr->>'start')::date; days := (pr->>'days')::int;
    chk := public.check_product(t, pr->>'kind', s, days, (pr->>'limit')::int, (pr->>'total')::int);
    if chk is not null then return chk; end if;
  end if;
  insert into public.users (type, name, pw_hash, phone, part, memo, roster_no)
  values (t, f->>'name', h, f->>'phone', f->>'part', f->>'memo', rno) returning id into uid;
  -- 등록 전에 같은 이름·비밀번호로 한 예약을 이 이용자에게 연결(명부 연결은 비밀번호 원문이 없어 건너뜀)
  if rno is null then
    update public.reservations set user_id = uid where user_id is null and name = f->>'name' and public.pw_ok(p->>'pw', pw_hash);
  end if;
  if pr is not null then
    insert into public.products (user_id, kind, start_date, end_date, daily_limit, total_count)
    values (uid, pr->>'kind', s, s + days - 1,
            case when pr->>'kind' = 'flat' then (pr->>'limit')::int end,
            case when pr->>'kind' = 'count' then (pr->>'total')::int end);
  end if;
  perform public.fail_reset(k) from unnest(array[f->>'name', 'ext:' || (f->>'name'), 'stu:' || (f->>'name'), 'info:' || (f->>'name')]) k;
  perform public.audit('admin', 'create_user', jsonb_build_object('id', uid));
  return jsonb_build_object('ok', true, 'user', public.user_json(uid));
exception when invalid_text_representation or datetime_field_overflow or numeric_value_out_of_range then
  return public.fail('입력값을 확인하십시오.');
end $$;

-- 예약: 재원생 명부 확인 추가(나머지는 020과 같음)
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
              where u.type = 'stu' and u.status = 'active' and u.name = n and p2.kind = 'flat'
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

revoke execute on function public.roster_on() from public, anon, authenticated;
revoke execute on function public.stu_allowed(text, text, date) from public, anon, authenticated;
revoke execute on function public.roster_sync(text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.admin_roster_status() from public, anon, authenticated;
revoke execute on function public.admin_roster_token() from public, anon, authenticated;
revoke execute on function public.admin_set_roster_check(boolean) from public, anon, authenticated;
revoke execute on function public.admin_roster_find(text) from public, anon, authenticated;
revoke execute on function public.admin_link_roster(bigint, text) from public, anon, authenticated;
revoke execute on function public.user_json(bigint) from public, anon, authenticated;
revoke execute on function public.admin_create_user(jsonb) from public, anon, authenticated;
revoke execute on function public.reserve(date, int, text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.roster_sync(text, jsonb, boolean) to anon, authenticated;
grant execute on function public.admin_roster_status() to authenticated;
grant execute on function public.admin_roster_token() to authenticated;
grant execute on function public.admin_set_roster_check(boolean) to authenticated;
grant execute on function public.admin_roster_find(text) to authenticated;
grant execute on function public.admin_link_roster(bigint, text) to authenticated;
grant execute on function public.admin_create_user(jsonb) to authenticated;
grant execute on function public.reserve(date, int, text, text, boolean, text) to anon, authenticated;
