-- 065_list_price.sql : 이용권 정상가(할인 표기)(2026-11-27 사용자 요청)
--   · 이용료 표(settings.price_list)의 이용권 줄마다 정상가(orig)를 선택으로 저장합니다(일반회원·제휴회원 모두).
--   · 정상가를 넣으면 화면이 "정상가 35,000원(빗금) / [7,000원 할인] 28,000원"으로 보여 줍니다. 비우면 지금처럼 가격 하나만.
--   · 정상가는 판매가(price)보다 커야 합니다. price_info는 바꾸지 않음(저장된 표를 그대로 줌).
--   · 051의 admin_set_prices에 정상가 확인만 더함(061의 "제휴회원" 문구 포함). 두 번 실행해도 같음.
create or replace function public.admin_set_prices(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fee text := replace(replace(replace(trim(coalesce(p->>'fee', '')), ',', ''), '원', ''), ' ', '');
  k text; lbl text; maxn int; arr jsonb; row jsonb; n text; pr text; og text; out jsonb := '{}'; lst jsonb; i int;
  old jsonb; old_fee text; upd text; sx text; pd text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if fee <> '' and fee !~ '^[0-9]{1,7}$' then return public.fail('1시간 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  -- 047: 제휴회원 추가 이용료(하루 1시간 무료 이후 1시간마다). 보내지 않으면 지금 값 그대로
  sx := case when p ? 'stu_extra'
    then replace(replace(replace(trim(coalesce(p->>'stu_extra', '')), ',', ''), '원', ''), ' ', '')
    else coalesce((select value->>'stu_extra' from public.settings where key = 'price_list'), '') end;
  if sx <> '' and sx !~ '^[0-9]{1,7}$' then return public.fail('제휴회원 추가 이용료는 숫자만 입력하십시오(비워 둘 수 있음).'); end if;
  -- 051: 이용권 기간(일). 보내지 않으면 지금 값(없으면 30)
  pd := case when p ? 'pass_days'
    then replace(replace(trim(coalesce(p->>'pass_days', '')), '일', ''), ' ', '')
    else coalesce((select value->>'pass_days' from public.settings where key = 'price_list'), '30') end;
  if pd !~ '^[0-9]{1,3}$' or pd::int < 1 or pd::int > 999 then
    return public.fail('이용권 기간은 1~999 사이 숫자(일)로 입력하십시오.'); end if;
  foreach k in array array['ext_count','stu_count'] loop
    lbl := case k when 'ext_count' then '일반회원 이용권' else '제휴회원 이용권' end;
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
      -- 065: 정상가(선택). 비우면 할인 표기 없음. 넣으면 판매가보다 커야 함
      og := replace(replace(replace(trim(coalesce(row->>'orig', '')), ',', ''), '원', ''), ' ', '');
      if og <> '' and og !~ '^[0-9]{1,7}$' then
        return public.fail(lbl || ' ' || i || '번째 줄: 정상가를 숫자로 입력하십시오(비워 둘 수 있음).'); end if;
      if og <> '' and og::bigint <= pr::bigint then
        return public.fail(lbl || ' ' || i || '번째 줄: 정상가는 판매가보다 커야 합니다(할인이 없으면 정상가를 비우십시오).'); end if;
      lst := lst || jsonb_build_array(jsonb_build_object('n', n::int, 'price', pr)
        || case when og <> '' then jsonb_build_object('orig', og) else '{}'::jsonb end);
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

revoke execute on function public.admin_set_prices(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_prices(jsonb) to authenticated;

-- 실행 결과 확인용: 지금 저장된 이용권 줄 수(정상가는 관리자 > 설정 > 이용료 변경에서 넣으십시오)
select jsonb_array_length(coalesce((public.price_info())->'ext_count','[]')) as "일반회원 이용권 줄 수",
       jsonb_array_length(coalesce((public.price_info())->'stu_count','[]')) as "제휴회원 이용권 줄 수";
