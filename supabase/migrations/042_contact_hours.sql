-- 042_contact_hours.sql : 문의 가능 시간(2026-11-05 사용자 요청)
-- · 손님 화면의 전화번호·전화 버튼을 홈 화면 맨 아래 [관리자 문의] 하나로 모으고, 그 창에 문의 가능 시간을 보여 줍니다.
-- · 관리자 > 설정 > 문의 가능 시간에서 요일마다 [문의 가능] + 시작·끝 시각(30분 단위, 끝은 24:00까지) + 메모 한 줄을 저장합니다.
-- · 지금이 문의 가능 시간인지(open)는 서버 시각(서울)으로 서버가 판단합니다.
-- · settings.contact_hours = {days:[{on,start,end} × 7 (월~일)], memo, updated_at}
-- · 처음 값: 매일 09:00 ~ 22:00(이전 화면 코드의 "매일 오전 9시 ~ 밤 10시"와 같음).

insert into public.settings (key, value) values ('contact_hours', jsonb_build_object(
  'days', (select jsonb_agg(jsonb_build_object('on', true, 'start', '09:00', 'end', '22:00')) from generate_series(1, 7)),
  'memo', '', 'updated_at', null))
  on conflict (key) do nothing;

-- "HH:MM"(30분 단위) → 분. 형식이 틀리면 null. 24:00은 끝 시각으로만 씀.
create or replace function public.hm_min(v text) returns int
language sql immutable set search_path = '' as $$
  select case when v ~ '^([01][0-9]|2[0-4]):(00|30)$' and v <= '24:00'
    then split_part(v, ':', 1)::int * 60 + split_part(v, ':', 2)::int end
$$;

create or replace function public.contact_info() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare h jsonb; d jsonb; n timestamp := public.app_now(); m int; is_open boolean := false;
begin
  h := coalesce((select value from public.settings where key = 'contact_hours'), '{}'::jsonb);
  d := h->'days'->(extract(isodow from n)::int - 1);
  m := extract(hour from n)::int * 60 + extract(minute from n)::int;
  if d is not null and coalesce((d->>'on')::boolean, false) then
    is_open := m >= public.hm_min(d->>'start') and m < public.hm_min(d->>'end');
  end if;
  return jsonb_build_object('ok', true, 'hours', h, 'open', coalesce(is_open, false),
    'now', to_char(n, 'YYYY-MM-DD"T"HH24:MI'));
end $$;

create or replace function public.admin_set_contact_hours(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare names text[] := array['월','화','수','목','금','토','일']; i int; d jsonb; s int; e int;
  out jsonb := '[]'::jsonb; memo text; old jsonb; upd text; c jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p is null or jsonb_typeof(p->'days') <> 'array' or jsonb_array_length(p->'days') <> 7 then
    return public.fail('잘못된 요청입니다.'); end if;
  for i in 0..6 loop
    d := p->'days'->i;
    if coalesce((d->>'on')::boolean, false) then
      s := public.hm_min(d->>'start'); e := public.hm_min(d->>'end');
      if s is null or e is null or s >= 1440 then
        return public.fail(names[i + 1] || '요일 시각을 다시 고르십시오.'); end if;
      if e <= s then
        return public.fail(names[i + 1] || '요일 끝 시각은 시작 시각보다 늦어야 합니다.'); end if;
      out := out || jsonb_build_array(jsonb_build_object('on', true, 'start', d->>'start', 'end', d->>'end'));
    else
      out := out || jsonb_build_array(jsonb_build_object('on', false,
        'start', coalesce(d->>'start', '09:00'), 'end', coalesce(d->>'end', '22:00')));
    end if;
  end loop;
  memo := trim(coalesce(p->>'memo', ''));
  if char_length(memo) > 100 then return public.fail('메모는 100자까지 쓸 수 있습니다.'); end if;
  old := coalesce((select value from public.settings where key = 'contact_hours'), '{}'::jsonb);
  c := jsonb_build_object('days', out, 'memo', memo);
  upd := old->>'updated_at';
  if upd is null or (old - 'updated_at') is distinct from c then upd := public.app_today()::text; end if;
  c := c || jsonb_build_object('updated_at', upd);
  insert into public.settings (key, value) values ('contact_hours', c)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'contact_hours', '{}'::jsonb);
  return public.contact_info();
end $$;

revoke execute on function public.hm_min(text) from public, anon, authenticated;
revoke execute on function public.contact_info() from public, anon, authenticated;
revoke execute on function public.admin_set_contact_hours(jsonb) from public, anon, authenticated;
grant execute on function public.contact_info() to anon, authenticated;
grant execute on function public.admin_set_contact_hours(jsonb) to authenticated;
