-- 047_stu_extra_fee.sql : 재원생 추가 이용료(2026-11-06 사용자 요청)
-- 재원생은 하루 1시간 무료, 더 쓰려면 1시간마다 추가 이용료(처음 값 3,000원). 정액권·횟수권과는 다른 것.
--   · settings.price_list.stu_extra : 추가 1회(1시간) 가격(숫자 글자, 비면 표시 안 함)
--   · admin_set_prices : p.stu_extra를 받음(보내지 않으면 그대로), 바뀌면 수정 날짜가 오늘로
--   · price_info : stu_extra를 함께 줌
-- 예약 규칙(재원생 하루 1회)은 바꾸지 않음.

create or replace function public.admin_set_prices(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fee text := replace(replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', ''), ' ', '');
  k text; lbl text; maxn int; arr jsonb; row jsonb; n text; pr text; out jsonb := '{}'; lst jsonb; i int;
  old jsonb; old_fee text; upd text; sx text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('1회 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  -- 047: 재원생 추가 이용료(하루 1시간 무료 이후 1시간마다). 보내지 않으면 지금 값 그대로
  sx := case when p ? 'stu_extra'
    then replace(replace(replace(trim(coalesce(p->>'stu_extra', '')), ',', ''), '원', ''), ' ', '')
    else coalesce((select value->>'stu_extra' from public.settings where key = 'price_list'), '') end;
  if sx <> '' and sx !~ '^[0-9]{1,7}$' then return public.fail('재원생 추가 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
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
  old := old || jsonb_build_object('stu_extra', coalesce(old->>'stu_extra', ''));
  out := out || jsonb_build_object('stu_extra', sx);
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
    || '{"ext_flat":[],"ext_count":[],"stu_flat":[],"stu_count":[],"stu_extra":""}'::jsonb
    || coalesce((select value from public.settings where key = 'price_list'), '{}'::jsonb)
$$;


-- 처음 값 3,000원(이미 값이 있으면 그대로). 새 가격이 생긴 것이므로 수정 날짜를 오늘로
update public.settings set value = value || jsonb_build_object('stu_extra', '3000', 'updated_at', public.app_today()::text)
  where key = 'price_list' and not (value ? 'stu_extra');
insert into public.settings (key, value)
  select 'price_list', jsonb_build_object('ext_flat','[]'::jsonb,'ext_count','[]'::jsonb,'stu_flat','[]'::jsonb,'stu_count','[]'::jsonb,
    'stu_extra','3000','updated_at',public.app_today()::text)
  where not exists (select 1 from public.settings where key = 'price_list');

revoke execute on function public.admin_set_prices(jsonb) from public, anon, authenticated;
revoke execute on function public.price_info() from public, anon, authenticated;
grant execute on function public.admin_set_prices(jsonb) to authenticated;
grant execute on function public.price_info() to anon, authenticated;
