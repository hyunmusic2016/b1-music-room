-- 035: 홈 안내 창 글(처음 오시는 분 필독!·오시는 길·시설 안내·재원생/일반회원 안내·주의사항)을 관리자가 직접 고치기(2026-11-04 사용자 요청)
-- · 관리자 > 설정 > 안내 글 변경에서 창마다 칸(제목 + 내용)을 고쳐 저장합니다. 저장한 창은 그 글이, 저장하지 않은 창은 화면 코드의 기본 글이 보입니다.
-- · [기본 글로 되돌리기] = 저장한 글을 지움(p_sections = null).
-- · 손님 누구나 보는 안내 글이라 공개 함수(info_pages)로 줍니다. 이용자 개인정보는 없습니다.
-- · 글은 그대로(문자)만 저장하고, 화면이 보여 줄 때 HTML로 해석하지 않습니다(굵게 **…** 만 화면이 따로 처리).

insert into public.settings (key, value) values ('info_pages', '{}'::jsonb)
  on conflict (key) do nothing;

create or replace function public.info_pages() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true, 'pages',
    coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb))
$$;

create or replace function public.admin_set_info_page(p_key text, p_sections jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s jsonb; out jsonb := '[]'::jsonb; t text; b text; cur jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_key is null or p_key not in ('first', 'way', 'room', 'stu', 'ext') then
    return public.fail('잘못된 안내 창입니다.'); end if;
  cur := coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb);
  if p_sections is null or p_sections = 'null'::jsonb then
    cur := cur - p_key;  -- 기본 글로 되돌리기
  else
    if jsonb_typeof(p_sections) <> 'array' then return public.fail('잘못된 요청입니다.'); end if;
    for s in select value from jsonb_array_elements(p_sections) loop
      t := trim(coalesce(s->>'t', '')); b := trim(coalesce(s->>'b', ''));
      continue when t = '' and b = '';  -- 제목·내용 둘 다 빈 칸은 버림
      if char_length(t) > 60 then return public.fail('칸 제목은 60자까지 쓸 수 있습니다.'); end if;
      if char_length(b) > 3000 then return public.fail('칸 하나의 내용은 3000자까지 쓸 수 있습니다.'); end if;
      out := out || jsonb_build_array(jsonb_build_object('t', t, 'b', b));
    end loop;
    if jsonb_array_length(out) = 0 then return public.fail('내용을 한 칸 이상 입력하십시오. 기본 글로 돌아가려면 [기본 글로 되돌리기]를 누르십시오.'); end if;
    if jsonb_array_length(out) > 20 then return public.fail('칸은 20개까지 만들 수 있습니다.'); end if;
    cur := cur || jsonb_build_object(p_key, jsonb_build_object('sections', out, 'updated_at', public.app_today()::text));
  end if;
  insert into public.settings (key, value) values ('info_pages', cur)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'info_page', jsonb_build_object('key', p_key, 'reset', p_sections is null or p_sections = 'null'::jsonb));
  return public.info_pages();
end $$;

revoke execute on function public.info_pages() from public, anon, authenticated;
revoke execute on function public.admin_set_info_page(text, jsonb) from public, anon, authenticated;
grant execute on function public.info_pages() to anon, authenticated;
grant execute on function public.admin_set_info_page(text, jsonb) to authenticated;
