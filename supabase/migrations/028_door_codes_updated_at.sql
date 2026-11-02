-- 028_door_codes_updated_at.sql : 출입 비밀번호 마지막 수정 날짜(2026-11-02 사용자 요청)
-- · 관리자가 출입 비밀번호 변경에서 [저장]할 때, 세 비밀번호 중 하나라도 실제로 바뀌었으면(또는 날짜가 아직 없으면)
--   그날(서울 날짜)을 settings.door_codes.updated_at에 남깁니다. 아무것도 안 바꾸고 저장하면 날짜는 그대로입니다.
-- · door_codes()가 updated_at을 함께 주므로 my_codes(공개, 예약이 있을 때만)·admin_door_codes·저장 결과에 날짜가 들어갑니다.
--   화면은 출입 비밀번호 상자 맨 아래에 "○년 ○월 ○일 기준 최신 출입 비밀번호입니다."를 보여 줍니다.
-- · 작업 기록에는 비밀번호 값을 남기지 않습니다(011과 같음).

create or replace function public.admin_set_door_codes(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text; v text; c jsonb := '{}'::jsonb; old jsonb; upd text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  foreach k in array array['gate','room','toilet'] loop
    v := trim(coalesce(p->>k, ''));
    if v = '' or char_length(v) > 20 then
      return public.fail(case k when 'gate' then '정문' when 'room' then '연습실' else '화장실' end || ' 비밀번호를 1~20자로 입력하십시오.');
    end if;
    c := c || jsonb_build_object(k, v);
  end loop;
  old := coalesce((select value from public.settings where key = 'door_codes'), '{}'::jsonb);
  upd := old->>'updated_at';
  if upd is null or (old - 'updated_at') is distinct from c then
    upd := public.app_today()::text;
  end if;
  c := c || jsonb_build_object('updated_at', upd);
  insert into public.settings (key, value) values ('door_codes', c)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'door_codes', '{}'::jsonb);  -- 비밀번호 자체는 기록에 남기지 않음
  return jsonb_build_object('ok', true, 'codes', c);
end $$;

revoke execute on function public.admin_set_door_codes(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_door_codes(jsonb) to authenticated;
