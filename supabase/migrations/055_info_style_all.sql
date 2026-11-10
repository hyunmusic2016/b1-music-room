-- 055: 안내 글 글자 모양을 모든 안내 창에 한꺼번에 + 칸마다 줄 상자 간격 (화면 v0.72.0, 2026-11-10 사용자 요청)
-- · settings.info_style = {ls: 자간(em, -0.1~0.1), fs: 전체 글씨(%, 70~160), tfs: 칸 제목 글씨(%, 70~160)} — 모든 안내 창(필독·오시는 길·시설·재원생·일반회원·이용권 안내)에 함께 적용
--   관리자 admin_set_info_style(p) 로 저장(기본값은 넣지 않음, null이면 지움), 공개 info_pages()가 style 로 줌
-- · 칸마다 gap: 줄 상자(✓ 항목) 사이 간격(px, 0~40, 기본 12)을 admin_set_info_page 가 저장(기본값이면 넣지 않음). 다른 규칙은 054와 같음.
-- · 054의 창마다 style 은 화면이 더 이상 보내지 않음(남아 있어도 화면은 쓰지 않음).

create or replace function public.admin_set_info_page(p_key text, p_sections jsonb, p_style jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s jsonb; out jsonb := '[]'::jsonb; t text; b text; cur jsonb; imgs jsonb; im jsonb; sz text; co text; lay jsonb; lv jsonb; dflt text; n int;
  lh numeric; fs numeric; gp numeric; st jsonb := '{}'::jsonb; page jsonb;
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
      if jsonb_array_length(imgs) > 100 then return public.fail('사진은 칸 하나에 100장까지 넣을 수 있습니다.'); end if;
      sz := coalesce(s->>'size', 'l'); co := coalesce(s->>'cols', '1');
      if sz not in ('l', 'm', 's') then return public.fail('사진 크기를 다시 고르십시오.'); end if;
      if co not in ('1', '2', '3') then return public.fail('한 줄 사진 수를 다시 고르십시오.'); end if;
      dflt := case when co = '1' then '1' || sz else co end;
      n := jsonb_array_length(imgs); lay := '[]'::jsonb;
      if jsonb_typeof(s->'lay') = 'array' and jsonb_array_length(s->'lay') <> n then
        return public.fail('사진 배치 정보가 올바르지 않습니다. 화면을 새로 고친 뒤 다시 저장하십시오.'); end if;
      for i in 0 .. n - 1 loop
        lv := case when jsonb_typeof(s->'lay') = 'array' then s->'lay'->i else to_jsonb(dflt) end;
        if jsonb_typeof(lv) <> 'string' or (lv #>> '{}') not in ('1l', '1m', '1s', '2', '3') then
          return public.fail('사진 배치를 다시 고르십시오.'); end if;
        lay := lay || jsonb_build_array(lv);
      end loop;
      lh := round(public.style_num(s->'lh', 1.0, 2.5), 2);
      fs := round(public.style_num(s->'fs', 70, 160));
      gp := round(public.style_num(s->'gap', 0, 40));
      out := out || jsonb_build_array(jsonb_build_object('t', t, 'b', b)
        || case when s->>'hide' = 'true' then jsonb_build_object('hide', true) else '{}'::jsonb end
        || case when n > 0 then jsonb_build_object('imgs', imgs) else '{}'::jsonb end
        || case when n > 0 and exists (select 1 from jsonb_array_elements_text(lay) x where x <> '1l') then jsonb_build_object('lay', lay) else '{}'::jsonb end
        || case when lh is not null then jsonb_build_object('lh', lh) else '{}'::jsonb end
        || case when fs is not null and fs <> 100 then jsonb_build_object('fs', fs) else '{}'::jsonb end
        || case when gp is not null and gp <> 12 then jsonb_build_object('gap', gp) else '{}'::jsonb end);
    end loop;
    if jsonb_array_length(out) = 0 then return public.fail('내용을 한 칸 이상 입력하십시오. 기본 글로 돌아가려면 [기본 글로 되돌리기]를 누르십시오.'); end if;
    if jsonb_array_length(out) > 20 then return public.fail('칸은 20개까지 만들 수 있습니다.'); end if;
    -- 창 전체 글자 모양(기본값은 넣지 않음)
    if jsonb_typeof(p_style) = 'object' then
      if coalesce(round(public.style_num(p_style->'ls', -0.1, 0.1), 3), 0) <> 0 then
        st := st || jsonb_build_object('ls', round(public.style_num(p_style->'ls', -0.1, 0.1), 3)); end if;
      if coalesce(round(public.style_num(p_style->'fs', 70, 160)), 100) <> 100 then
        st := st || jsonb_build_object('fs', round(public.style_num(p_style->'fs', 70, 160))); end if;
      if coalesce(round(public.style_num(p_style->'tfs', 70, 160)), 100) <> 100 then
        st := st || jsonb_build_object('tfs', round(public.style_num(p_style->'tfs', 70, 160))); end if;
    end if;
    page := jsonb_build_object('sections', out, 'updated_at', public.app_today()::text);
    if st <> '{}'::jsonb then page := page || jsonb_build_object('style', st); end if;
    cur := cur || jsonb_build_object(p_key, page);
  end if;
  insert into public.settings (key, value) values ('info_pages', cur)
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'info_page', jsonb_build_object('key', p_key, 'reset', p_sections is null or p_sections = 'null'::jsonb));
  return public.info_pages();
end $$;

create or replace function public.info_pages() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'pages', coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb),
    'titles', coalesce((select value from public.settings where key = 'info_titles'), '{}'::jsonb),
    'style', coalesce((select value from public.settings where key = 'info_style'), '{}'::jsonb))
$$;

create or replace function public.admin_set_info_style(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare st jsonb := '{}'::jsonb; ls numeric; fs numeric; tfs numeric;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p is not null and p <> 'null'::jsonb then
    if jsonb_typeof(p) <> 'object' then return public.fail('잘못된 요청입니다.'); end if;
    ls := round(public.style_num(p->'ls', -0.1, 0.1), 3);
    fs := round(public.style_num(p->'fs', 70, 160));
    tfs := round(public.style_num(p->'tfs', 70, 160));
    if coalesce(ls, 0) <> 0 then st := st || jsonb_build_object('ls', ls); end if;
    if coalesce(fs, 100) <> 100 then st := st || jsonb_build_object('fs', fs); end if;
    if coalesce(tfs, 100) <> 100 then st := st || jsonb_build_object('tfs', tfs); end if;
  end if;
  if st = '{}'::jsonb then delete from public.settings where key = 'info_style';
  else insert into public.settings (key, value) values ('info_style', st) on conflict (key) do update set value = excluded.value; end if;
  perform public.audit('admin', 'info_style', '{}'::jsonb);
  return public.info_pages();
end $$;

revoke execute on function public.admin_set_info_page(text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.info_pages() from public, anon, authenticated;
revoke execute on function public.admin_set_info_style(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_info_page(text, jsonb, jsonb) to authenticated;
grant execute on function public.info_pages() to anon, authenticated;
grant execute on function public.admin_set_info_style(jsonb) to authenticated;

-- 확인: 두 숫자가 모두 1이면 정상입니다(글자 모양 저장 함수가 있고, 공개 안내 글 조회에 style 칸이 있음).
select (select count(*) from pg_proc where proname = 'admin_set_info_style') as style_fn,
       (select case when public.info_pages() ? 'style' then 1 else 0 end) as style_in_info_pages;
