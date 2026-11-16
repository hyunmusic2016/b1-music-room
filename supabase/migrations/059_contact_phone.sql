-- 059_contact_phone.sql : [관리자 문의] 창의 전화번호를 관리자가 설정에서 바꿈(2026-11-16 사용자 요청)
-- · settings.contact_phone = {phone:'01083284984'(숫자만), updated_at:'YYYY-MM-DD'}, 처음 값 010-8328-4984
-- · 공개 contact_phone(): {ok, phone, updated_at} (손님 화면의 [관리자 문의] 창이 씀)
-- · 관리자 admin_set_contact_phone(p_phone): 숫자만 남겨 0으로 시작하는 9~11자리만 저장
--   (휴대전화 010…, 지역번호 02·032… 모두 가능). 바뀌면 수정 날짜 오늘로.

insert into public.settings (key, value)
values ('contact_phone', jsonb_build_object('phone', '01083284984', 'updated_at', public.app_today()::text))
on conflict (key) do nothing;

create or replace function public.contact_phone() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'phone', (select value->>'phone' from public.settings where key = 'contact_phone'),
    'updated_at', (select value->>'updated_at' from public.settings where key = 'contact_phone'))
$$;

create or replace function public.admin_set_contact_phone(p_phone text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); old jsonb; upd text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if d !~ '^0\d{8,10}$' then
    return public.fail('전화번호를 다시 확인하십시오. 0으로 시작하는 9~11자리 숫자여야 합니다.'); end if;
  old := coalesce((select value from public.settings where key = 'contact_phone'), '{}'::jsonb);
  upd := old->>'updated_at';
  if upd is null or old->>'phone' is distinct from d then upd := public.app_today()::text; end if;
  insert into public.settings (key, value) values ('contact_phone', jsonb_build_object('phone', d, 'updated_at', upd))
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'contact_phone', '{}'::jsonb);
  return public.contact_phone();
end $$;

revoke execute on function public.contact_phone() from public, anon, authenticated;
revoke execute on function public.admin_set_contact_phone(text) from public, anon, authenticated;
grant execute on function public.contact_phone() to anon, authenticated;
grant execute on function public.admin_set_contact_phone(text) to authenticated;

-- 확인: 저장된 전화번호(01083284984가 보이면 정상)
select value->>'phone' as 문의_전화번호 from public.settings where key = 'contact_phone';
