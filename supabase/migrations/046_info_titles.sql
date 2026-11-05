-- 046_info_titles.sql : 안내 글 제목 바꾸기(2026-11-05 사용자 요청)
-- · 관리자 > 설정 > 홈 화면 안내 > 안내 글 변경에서 글마다 제목(홈 화면 버튼·안내 창 제목)을 바꿉니다.
-- · settings.info_titles = {창: 제목}. 비우면 지움(화면 코드의 기본 제목).
-- · 공개 info_pages()가 titles도 함께 줍니다(글의 칸·사진 저장 함수 admin_set_info_page는 그대로).

insert into public.settings (key, value) values ('info_titles', '{}'::jsonb)
  on conflict (key) do nothing;

create or replace function public.info_pages() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'pages', coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb),
    'titles', coalesce((select value from public.settings where key = 'info_titles'), '{}'::jsonb))
$$;

create or replace function public.admin_set_info_title(p_key text, p_title text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t text := trim(coalesce(p_title, '')); cur jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_key is null or p_key not in ('first', 'way', 'room', 'stu', 'ext', 'price') then
    return public.fail('잘못된 안내 창입니다.'); end if;
  if char_length(t) > 30 then return public.fail('제목은 30자까지 쓸 수 있습니다.'); end if;
  if t ~ '[\r\n]' then return public.fail('제목은 한 줄로 쓰십시오.'); end if;
  cur := coalesce((select value from public.settings where key = 'info_titles'), '{}'::jsonb);
  cur := case when t = '' then cur - p_key else cur || jsonb_build_object(p_key, t) end;
  insert into public.settings (key, value) values ('info_titles', cur)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'info_title', jsonb_build_object('key', p_key));
  return public.info_pages();
end $$;

revoke execute on function public.info_pages() from public, anon, authenticated;
revoke execute on function public.admin_set_info_title(text, text) from public, anon, authenticated;
grant execute on function public.info_pages() to anon, authenticated;
grant execute on function public.admin_set_info_title(text, text) to authenticated;
