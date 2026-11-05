-- 043_contact_off.sql : 문의 가능 시간의 예외(문의 안 받는 기간)(2026-11-05 사용자 요청)
-- · 휴가 등으로 원래 문의 가능 시간인데도 연락을 받지 못하는 기간을 날짜·시각 + 사유로 넣습니다.
-- · settings.contact_hours.off = [{id, from, to, reason}] (from·to는 서울 시각 'YYYY-MM-DD HH:MM', to는 그 시각 전까지)
-- · contact_info(): 지금이 예외 기간 안이면 open=false, off_now={to, reason}. 이미 끝난 예외는 보여 주지 않음.
-- · admin_add_contact_off / admin_del_contact_off: 관리자만. 추가할 때 이미 끝난 예외는 정리.
-- · admin_set_contact_hours(042)는 요일 시간을 저장할 때 예외 목록을 지우지 않게 다시 만듭니다.

create or replace function public.contact_info() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare h jsonb; d jsonb; n timestamp := public.app_now(); m int; is_open boolean := false;
  offs jsonb := '[]'::jsonb; o jsonb; now_off jsonb;
begin
  h := coalesce((select value from public.settings where key = 'contact_hours'), '{}'::jsonb);
  d := h->'days'->(extract(isodow from n)::int - 1);
  m := extract(hour from n)::int * 60 + extract(minute from n)::int;
  if d is not null and coalesce((d->>'on')::boolean, false) then
    is_open := m >= public.hm_min(d->>'start') and m < public.hm_min(d->>'end');
  end if;
  for o in select value from jsonb_array_elements(coalesce(h->'off', '[]'::jsonb)) loop
    continue when (o->>'to')::timestamp <= n;  -- 끝난 예외는 빼고
    offs := offs || jsonb_build_array(o);
    if (o->>'from')::timestamp <= n and now_off is null then now_off := o; end if;
  end loop;
  if now_off is not null then is_open := false; end if;
  return jsonb_build_object('ok', true, 'hours', (h - 'off') || jsonb_build_object('off', offs),
    'open', coalesce(is_open, false), 'off_now', now_off, 'now', to_char(n, 'YYYY-MM-DD"T"HH24:MI'));
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
  if upd is null or (old - 'updated_at' - 'off') is distinct from c then upd := public.app_today()::text; end if;
  c := c || jsonb_build_object('updated_at', upd, 'off', coalesce(old->'off', '[]'::jsonb));  -- 예외 목록은 그대로
  insert into public.settings (key, value) values ('contact_hours', c)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'contact_hours', '{}'::jsonb);
  return public.contact_info();
end $$;

create or replace function public.admin_add_contact_off(p_from text, p_to text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f timestamp; t timestamp; r text := trim(coalesce(p_reason, '')); h jsonb; keep jsonb := '[]'::jsonb; o jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if coalesce(p_from, '') !~ '^\d{4}-\d{2}-\d{2} \d{2}:(00|30)$' or coalesce(p_to, '') !~ '^\d{4}-\d{2}-\d{2} \d{2}:(00|30)$' then
    return public.fail('날짜와 시각을 다시 고르십시오.'); end if;
  begin f := p_from::timestamp; t := p_to::timestamp;
  exception when others then return public.fail('날짜와 시각을 다시 고르십시오.'); end;
  if t <= f then return public.fail('끝 날짜·시각은 시작보다 늦어야 합니다.'); end if;
  if t <= public.app_now() then return public.fail('이미 지난 기간입니다.'); end if;
  if t - f > interval '366 days' then return public.fail('예외 기간은 1년까지 넣을 수 있습니다.'); end if;
  if char_length(r) > 60 then return public.fail('사유는 60자까지 쓸 수 있습니다.'); end if;
  h := coalesce((select value from public.settings where key = 'contact_hours'), '{}'::jsonb);
  for o in select value from jsonb_array_elements(coalesce(h->'off', '[]'::jsonb)) loop
    continue when (o->>'to')::timestamp <= public.app_now();  -- 끝난 예외는 정리
    keep := keep || jsonb_build_array(o);
  end loop;
  if jsonb_array_length(keep) >= 20 then return public.fail('예외는 20개까지 넣을 수 있습니다. 지난 것을 지운 뒤 넣으십시오.'); end if;
  keep := keep || jsonb_build_array(jsonb_build_object('id', md5(clock_timestamp()::text || random()::text),
    'from', to_char(f, 'YYYY-MM-DD HH24:MI'), 'to', to_char(t, 'YYYY-MM-DD HH24:MI'), 'reason', r));
  select coalesce(jsonb_agg(x order by x->>'from'), '[]'::jsonb) into keep from jsonb_array_elements(keep) x;
  h := (h - 'off') || jsonb_build_object('off', keep);
  insert into public.settings (key, value) values ('contact_hours', h)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'contact_off_add', '{}'::jsonb);
  return public.contact_info();
end $$;

create or replace function public.admin_del_contact_off(p_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare h jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  h := coalesce((select value from public.settings where key = 'contact_hours'), '{}'::jsonb);
  h := (h - 'off') || jsonb_build_object('off', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(h->'off', '[]'::jsonb)) x
    where x->>'id' is distinct from p_id), '[]'::jsonb));
  insert into public.settings (key, value) values ('contact_hours', h)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'contact_off_del', '{}'::jsonb);
  return public.contact_info();
end $$;

revoke execute on function public.contact_info() from public, anon, authenticated;
revoke execute on function public.admin_set_contact_hours(jsonb) from public, anon, authenticated;
revoke execute on function public.admin_add_contact_off(text, text, text) from public, anon, authenticated;
revoke execute on function public.admin_del_contact_off(text) from public, anon, authenticated;
grant execute on function public.contact_info() to anon, authenticated;
grant execute on function public.admin_set_contact_hours(jsonb) to authenticated;
grant execute on function public.admin_add_contact_off(text, text, text) to authenticated;
grant execute on function public.admin_del_contact_off(text) to authenticated;
