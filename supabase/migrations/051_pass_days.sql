-- 051_pass_days.sql : 이용권 기간(일)을 이용료 변경에서 정하기(2026-11-09 사용자 요청·선택: 모든 이용권 같은 기간)
--   · 이용료 표(settings.price_list)에 pass_days(처음 값 30)를 둡니다. admin_set_prices가 받고(보내지 않으면 그대로), price_info가 줍니다.
--   · 화면은 이 값으로 가격표·이용료 보기·안내 글({이용권 기간})의 "N일"과 새 이용권 등록의 기본 기간을 보여 줍니다.
--   · 이미 등록된 이용권의 기간은 바뀌지 않습니다(각 이용권은 자기 시작일·종료일을 그대로 가짐).
--   · 기간을 바꾸면 이용료 수정 날짜도 오늘로 바뀝니다.
create or replace function public.admin_set_prices(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fee text := replace(replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', ''), ' ', '');
  k text; lbl text; maxn int; arr jsonb; row jsonb; n text; pr text; out jsonb := '{}'; lst jsonb; i int;
  old jsonb; old_fee text; upd text; sx text; pd text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('1시간 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  -- 047: 재원생 추가 이용료(하루 1시간 무료 이후 1시간마다). 보내지 않으면 지금 값 그대로
  sx := case when p ? 'stu_extra'
    then replace(replace(replace(trim(coalesce(p->>'stu_extra', '')), ',', ''), '원', ''), ' ', '')
    else coalesce((select value->>'stu_extra' from public.settings where key = 'price_list'), '') end;
  if sx <> '' and sx !~ '^[0-9]{1,7}$' then return public.fail('재원생 추가 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  -- 051: 이용권 기간(일). 보내지 않으면 지금 값(없으면 30)
  pd := case when p ? 'pass_days'
    then replace(replace(trim(coalesce(p->>'pass_days', '')), '일', ''), ' ', '')
    else coalesce((select value->>'pass_days' from public.settings where key = 'price_list'), '30') end;
  if pd !~ '^[0-9]{1,3}$' or pd::int < 1 or pd::int > 999 then
    return public.fail('이용권 기간은 1~999 사이 숫자(일)로 입력하십시오.'); end if;
  foreach k in array array['ext_count','stu_count'] loop
    lbl := case k when 'ext_count' then '일반회원 이용권' else '재원생 이용권' end;
    maxn := 999;
    arr := coalesce(p->k, '[]'::jsonb);
    if jsonb_typeof(arr) <> 'array' then return public.fail('잘못된 요청입니다.'); end if;
    if jsonb_array_length(arr) > 10 then return public.fail(lbl || '은 10개까지 만들 수 있습니다.'); end if;
    lst := '[]'; i := 0;
    for row in select value from jsonb_array_elements(arr) loop
      i := i + 1;
      n := replace(replace(replace(trim(coalesce(row->>'n', '')), '시간', ''), '회', ''), ' ', '');
      pr := replace(replace(replace(trim(coalesce(row->>'price', '')), ',', ''), '원', ''), ' ', '');
      continue when n = '' and pr = '';
      if n !~ '^[0-9]{1,3}$' or n::int < 1 or n::int > maxn then
        return public.fail(lbl || ' ' || i || '번째 줄: 시간을 1~' || maxn || ' 사이 숫자로 입력하십시오.'); end if;
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
  old := old || jsonb_build_object('stu_count', coalesce(old->'stu_count', '[]'::jsonb));
  old := old || jsonb_build_object('stu_extra', coalesce(old->>'stu_extra', ''));
  old := old || jsonb_build_object('pass_days', coalesce((old->>'pass_days')::int, 30)); -- 예전 표엔 칸이 없음 = 30
  out := out || jsonb_build_object('stu_extra', sx, 'pass_days', pd::int);
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
    || '{"ext_count":[],"stu_count":[],"stu_extra":"","pass_days":30}'::jsonb
    || coalesce((select value from public.settings where key = 'price_list'), '{}'::jsonb)
$$;

revoke execute on function public.admin_set_prices(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_prices(jsonb) to authenticated;
revoke execute on function public.price_info() from public, anon, authenticated;
grant execute on function public.price_info() to anon, authenticated;

-- 실행 결과 확인용: 이용권 기간(처음이면 30)
select (public.price_info())->>'pass_days' as "이용권 기간(일)";
