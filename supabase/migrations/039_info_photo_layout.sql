-- 039: 안내 사진 배치를 두 가지로 나눔(2026-11-04 사용자 요청: "보통 크기로 한 줄에 1장"처럼 따로 고르기)
-- · cols: 한 줄에 몇 장(1·2·3, 기본 1) / size: 사진들 전체 폭(l 크게 100%·m 보통 약 70%·s 작게 약 45%, 기본 l)
-- · 038까지의 size(m = 한 줄 2장, s = 한 줄 3장)는 보이는 모양이 그대로 남도록 cols 2·3 + size 없음(크게)으로 바꿉니다.

do $$
declare cur jsonb := coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb);
  k text; pg jsonb; secs jsonb; s jsonb; out jsonb; changed boolean := false;
begin
  for k, pg in select key, value from jsonb_each(cur) loop
    secs := pg->'sections';
    continue when jsonb_typeof(secs) <> 'array';
    out := '[]'::jsonb;
    for s in select value from jsonb_array_elements(secs) loop
      if s ? 'size' and not (s ? 'cols') and s->>'size' in ('m', 's') then
        s := (s - 'size') || jsonb_build_object('cols', case s->>'size' when 'm' then 2 else 3 end);
        changed := true;
      end if;
      out := out || jsonb_build_array(s);
    end loop;
    cur := cur || jsonb_build_object(k, pg || jsonb_build_object('sections', out));
  end loop;
  if changed then update public.settings set value = cur where key = 'info_pages'; end if;
end $$;

create or replace function public.admin_set_info_page(p_key text, p_sections jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s jsonb; out jsonb := '[]'::jsonb; t text; b text; cur jsonb; imgs jsonb; im jsonb; sz text; co text;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_key is null or p_key not in ('first', 'way', 'room', 'stu', 'ext', 'price') then
    return public.fail('잘못된 안내 창입니다.'); end if;
  cur := coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb);
  if p_sections is null or p_sections = 'null'::jsonb then
    cur := cur - p_key;
  else
    if jsonb_typeof(p_sections) <> 'array' then return public.fail('잘못된 요청입니다.'); end if;
    for s in select value from jsonb_array_elements(p_sections) loop
      t := trim(coalesce(s->>'t', '')); b := trim(coalesce(s->>'b', ''));
      imgs := '[]'::jsonb;
      if jsonb_typeof(s->'imgs') = 'array' then
        for im in select value from jsonb_array_elements(s->'imgs') loop
          if jsonb_typeof(im) <> 'string' or (im #>> '{}') !~ ('^' || p_key || '/[0-9A-Za-z_-]{1,60}\.(jpg|png|webp)$') then
            return public.fail('사진 정보가 올바르지 않습니다. 사진을 다시 올리십시오.'); end if;
          imgs := imgs || jsonb_build_array(im);
        end loop;
      end if;
      continue when t = '' and b = '' and jsonb_array_length(imgs) = 0;
      if char_length(t) > 60 then return public.fail('칸 제목은 60자까지 쓸 수 있습니다.'); end if;
      if char_length(b) > 3000 then return public.fail('칸 하나의 내용은 3000자까지 쓸 수 있습니다.'); end if;
      if jsonb_array_length(imgs) > 6 then return public.fail('사진은 칸 하나에 6장까지 넣을 수 있습니다.'); end if;
      sz := coalesce(s->>'size', 'l'); co := coalesce(s->>'cols', '1');
      if sz not in ('l', 'm', 's') then return public.fail('사진 크기를 다시 고르십시오.'); end if;
      if co not in ('1', '2', '3') then return public.fail('한 줄 사진 수를 다시 고르십시오.'); end if;
      out := out || jsonb_build_array(jsonb_build_object('t', t, 'b', b)
        || case when jsonb_array_length(imgs) > 0 then jsonb_build_object('imgs', imgs) else '{}'::jsonb end
        || case when jsonb_array_length(imgs) > 0 and sz <> 'l' then jsonb_build_object('size', sz) else '{}'::jsonb end
        || case when jsonb_array_length(imgs) > 0 and co <> '1' then jsonb_build_object('cols', co::int) else '{}'::jsonb end);
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

revoke execute on function public.admin_set_info_page(text, jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_info_page(text, jsonb) to authenticated;
