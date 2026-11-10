-- 056: 줄 상자 간격을 모든 안내 창 글자 모양에 (화면 v0.72.1, 2026-11-10 사용자 요청)
-- · admin_set_info_style 이 gap(✓ 항목 사이 간격, px 0~40, 기본 12)도 저장(기본값이면 넣지 않음). 나머지는 055와 같음.
-- · 055의 칸마다 gap 은 화면이 더 이상 보내지 않고 쓰지 않음.

create or replace function public.admin_set_info_style(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare st jsonb := '{}'::jsonb; ls numeric; fs numeric; tfs numeric; gp numeric;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p is not null and p <> 'null'::jsonb then
    if jsonb_typeof(p) <> 'object' then return public.fail('잘못된 요청입니다.'); end if;
    ls := round(public.style_num(p->'ls', -0.1, 0.1), 3);
    fs := round(public.style_num(p->'fs', 70, 160));
    tfs := round(public.style_num(p->'tfs', 70, 160));
    gp := round(public.style_num(p->'gap', 0, 40));
    if coalesce(ls, 0) <> 0 then st := st || jsonb_build_object('ls', ls); end if;
    if coalesce(fs, 100) <> 100 then st := st || jsonb_build_object('fs', fs); end if;
    if coalesce(tfs, 100) <> 100 then st := st || jsonb_build_object('tfs', tfs); end if;
    if coalesce(gp, 12) <> 12 then st := st || jsonb_build_object('gap', gp); end if;
  end if;
  if st = '{}'::jsonb then delete from public.settings where key = 'info_style';
  else insert into public.settings (key, value) values ('info_style', st) on conflict (key) do update set value = excluded.value; end if;
  perform public.audit('admin', 'info_style', '{}'::jsonb);
  return public.info_pages();
end $$;

revoke execute on function public.admin_set_info_style(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_info_style(jsonb) to authenticated;

-- 확인: 1이 나오면 정상입니다(새 저장 함수에 줄 상자 간격이 들어 있음).
select (select count(*) from pg_proc where proname = 'admin_set_info_style' and prosrc like '%''gap''%') as gap_in_style_fn;
