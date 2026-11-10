-- 054: 안내 글·로비 안내의 글자 모양 (화면 v0.70.0, 2026-11-10 사용자 요청)
-- · 안내 글(창)마다 style = {ls: 자간(em, -0.1~0.1), fs: 전체 글씨(%, 70~160), tfs: 칸 제목 글씨(%, 70~160)}
--   → settings.info_pages[창].style 에 저장(기본값이면 넣지 않음)
-- · 칸마다 lh: 행간(1.0~2.5), fs: 칸 글씨(%, 70~160) → 칸 안에 저장(기본값이면 넣지 않음)
-- · 로비 안내: 전체 fs·tfs(%, 70~160) 추가, 상자마다 lh(1.0~2.5) 추가(scale = 상자 글씨, ls = 전체 자간은 그대로)
-- · admin_set_info_page 는 세 번째 인자 p_style(생략 가능)을 받도록 바꿈(옛 2인자판은 지움). 다른 규칙은 053과 같음.

create or replace function public.style_num(v jsonb, lo numeric, hi numeric) returns numeric
language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
  if v is null or jsonb_typeof(v) not in ('number', 'string') then return null; end if;
  begin n := (v #>> '{}')::numeric; exception when others then return null; end;
  return greatest(lo, least(hi, n));
end $$;

drop function if exists public.admin_set_info_page(text, jsonb);

create or replace function public.admin_set_info_page(p_key text, p_sections jsonb, p_style jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s jsonb; out jsonb := '[]'::jsonb; t text; b text; cur jsonb; imgs jsonb; im jsonb; sz text; co text; lay jsonb; lv jsonb; dflt text; n int;
  lh numeric; fs numeric; st jsonb := '{}'::jsonb; page jsonb;
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
      out := out || jsonb_build_array(jsonb_build_object('t', t, 'b', b)
        || case when s->>'hide' = 'true' then jsonb_build_object('hide', true) else '{}'::jsonb end
        || case when n > 0 then jsonb_build_object('imgs', imgs) else '{}'::jsonb end
        || case when n > 0 and exists (select 1 from jsonb_array_elements_text(lay) x where x <> '1l') then jsonb_build_object('lay', lay) else '{}'::jsonb end
        || case when lh is not null then jsonb_build_object('lh', lh) else '{}'::jsonb end
        || case when fs is not null and fs <> 100 then jsonb_build_object('fs', fs) else '{}'::jsonb end);
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

create or replace function public.lobby_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'boxes', (select value->'boxes' from public.settings where key = 'lobby_info'),
    'ls', coalesce((select value->'ls' from public.settings where key = 'lobby_info'), '0'::jsonb),
    'fs', coalesce((select value->'fs' from public.settings where key = 'lobby_info'), '100'::jsonb),
    'tfs', coalesce((select value->'tfs' from public.settings where key = 'lobby_info'), '100'::jsonb),
    'updated_at', (select value->'updated_at' from public.settings where key = 'lobby_info'))
$$;

create or replace function public.admin_set_lobby_info(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b jsonb; out jsonb := '[]'::jsonb; i int := 0; t text; st text; sc int; ls numeric; id text; lh numeric; fs numeric; tfs numeric;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p is null or p = 'null'::jsonb then
    delete from public.settings where key = 'lobby_info';
    perform public.audit('admin', 'lobby_info_reset', '{}'::jsonb);
    return public.lobby_info();
  end if;
  if jsonb_typeof(p->'boxes') <> 'array' then return public.fail('잘못된 요청입니다.'); end if;
  if jsonb_array_length(p->'boxes') > 20 then return public.fail('상자는 20개까지 넣을 수 있습니다.'); end if;
  for b in select value from jsonb_array_elements(p->'boxes') loop
    i := i + 1;
    t := coalesce(b->>'type', 'text');
    if t not in ('text', 'qr') then return public.fail(i || '번째 상자의 종류가 잘못되었습니다.'); end if;
    st := coalesce(b->>'style', 'list');
    if st not in ('list', 'alert', 'plain', 'center') then return public.fail(i || '번째 상자의 모양이 잘못되었습니다.'); end if;
    if char_length(coalesce(b->>'title', '')) > 60 then return public.fail(i || '번째 상자의 제목은 60자까지 쓸 수 있습니다.'); end if;
    if char_length(coalesce(b->>'body', '')) > 2000 then return public.fail(i || '번째 상자의 내용은 2000자까지 쓸 수 있습니다.'); end if;
    begin sc := coalesce((b->>'scale')::int, 100); exception when others then sc := 100; end;
    sc := greatest(70, least(160, sc));
    id := coalesce(b->>'id', '');
    if id !~ '^[A-Za-z0-9_-]{1,40}$' then id := 'b' || i; end if;
    lh := round(public.style_num(b->'lh', 1.0, 2.5), 2);
    out := out || jsonb_build_array(jsonb_build_object('id', id, 'type', t, 'title', coalesce(b->>'title', ''),
      'body', coalesce(b->>'body', ''), 'style', st, 'scale', sc, 'hidden', coalesce((b->>'hidden')::boolean, false))
      || case when lh is not null then jsonb_build_object('lh', lh) else '{}'::jsonb end);
  end loop;
  begin ls := coalesce((p->>'ls')::numeric, 0); exception when others then ls := 0; end;
  ls := greatest(-0.1, least(0.05, ls));
  fs := coalesce(round(public.style_num(p->'fs', 70, 160)), 100);
  tfs := coalesce(round(public.style_num(p->'tfs', 70, 160)), 100);
  insert into public.settings (key, value) values ('lobby_info',
    jsonb_build_object('boxes', out, 'ls', ls, 'fs', fs, 'tfs', tfs, 'updated_at', public.app_today()::text))
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'lobby_info', '{}'::jsonb);
  return public.lobby_info();
end $$;

revoke execute on function public.style_num(jsonb, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.admin_set_info_page(text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.lobby_info() from public, anon, authenticated;
revoke execute on function public.admin_set_lobby_info(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_info_page(text, jsonb, jsonb) to authenticated;
grant execute on function public.lobby_info() to anon, authenticated;
grant execute on function public.admin_set_lobby_info(jsonb) to authenticated;

-- 확인: 아래 두 숫자가 모두 1이면 정상입니다(새 함수가 있고, 옛 2인자 함수는 없음 → 0이어야 할 칸은 마지막 숫자).
select (select count(*) from pg_proc where proname = 'admin_set_info_page' and pronargs = 3) as new_fn,
       (select count(*) from pg_proc where proname = 'admin_set_info_page' and pronargs = 2) as old_fn_should_be_0;
