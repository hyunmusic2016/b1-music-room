-- 044_contact_off_edit.sql : 넣어 둔 문의 예외(문의 안 받는 기간) 수정(2026-11-05 사용자 요청)
-- · admin_edit_contact_off(p_id, p_from, p_to, p_reason): 같은 id의 예외를 새 기간·사유로 바꿈(관리자만).
--   검사 규칙은 043의 추가와 같음(형식, 끝 > 시작, 이미 지난 기간 막음, 1년까지, 사유 60자).

create or replace function public.admin_edit_contact_off(p_id text, p_from text, p_to text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f timestamp; t timestamp; r text := trim(coalesce(p_reason, '')); h jsonb; keep jsonb := '[]'::jsonb; o jsonb; found boolean := false;
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
    if o->>'id' = p_id then
      found := true;
      o := jsonb_build_object('id', p_id, 'from', to_char(f, 'YYYY-MM-DD HH24:MI'), 'to', to_char(t, 'YYYY-MM-DD HH24:MI'), 'reason', r);
    elsif (o->>'to')::timestamp <= public.app_now() then
      continue;  -- 끝난 예외는 정리
    end if;
    keep := keep || jsonb_build_array(o);
  end loop;
  if not found then return public.fail('이미 지워졌거나 기간이 끝난 예외입니다. 화면을 새로 고치십시오.'); end if;
  select coalesce(jsonb_agg(x order by x->>'from'), '[]'::jsonb) into keep from jsonb_array_elements(keep) x;
  h := (h - 'off') || jsonb_build_object('off', keep);
  insert into public.settings (key, value) values ('contact_hours', h)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'contact_off_edit', '{}'::jsonb);
  return public.contact_info();
end $$;

revoke execute on function public.admin_edit_contact_off(text, text, text, text) from public, anon, authenticated;
grant execute on function public.admin_edit_contact_off(text, text, text, text) to authenticated;
