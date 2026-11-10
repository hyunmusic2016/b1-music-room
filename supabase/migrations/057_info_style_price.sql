-- 057: [이용료 보기] 가격 글씨 크기를 안내 글 글자 모양에 (화면 v0.72.2, 2026-11-10 사용자 요청)
-- · admin_set_info_style 이 pfs(이용료 보기 창의 금액 글씨, %, 70~160, 기본 100)도 저장(기본값이면 넣지 않음). 나머지는 056과 같음.
-- · 안내 글 변경의 글자 모양(자간·전체 글씨·칸 제목 글씨·줄 상자 간격)은 화면이 [이용료 보기] 창 전체에도 적용.

create or replace function public.admin_set_info_style(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare st jsonb := '{}'::jsonb; ls numeric; fs numeric; tfs numeric; gp numeric; pf numeric;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p is not null and p <> 'null'::jsonb then
    if jsonb_typeof(p) <> 'object' then return public.fail('잘못된 요청입니다.'); end if;
    ls := round(public.style_num(p->'ls', -0.1, 0.1), 3);
    fs := round(public.style_num(p->'fs', 70, 160));
    tfs := round(public.style_num(p->'tfs', 70, 160));
    gp := round(public.style_num(p->'gap', 0, 40));
    pf := round(public.style_num(p->'pfs', 70, 160));
    if coalesce(ls, 0) <> 0 then st := st || jsonb_build_object('ls', ls); end if;
    if coalesce(fs, 100) <> 100 then st := st || jsonb_build_object('fs', fs); end if;
    if coalesce(tfs, 100) <> 100 then st := st || jsonb_build_object('tfs', tfs); end if;
    if coalesce(gp, 12) <> 12 then st := st || jsonb_build_object('gap', gp); end if;
    if coalesce(pf, 100) <> 100 then st := st || jsonb_build_object('pfs', pf); end if;
  end if;
  if st = '{}'::jsonb then delete from public.settings where key = 'info_style';
  else insert into public.settings (key, value) values ('info_style', st) on conflict (key) do update set value = excluded.value; end if;
  perform public.audit('admin', 'info_style', '{}'::jsonb);
  return public.info_pages();
end $$;

revoke execute on function public.admin_set_info_style(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_info_style(jsonb) to authenticated;

-- 확인: 1이 나오면 정상입니다(새 저장 함수에 가격 글씨가 들어 있음).
select (select count(*) from pg_proc where proname = 'admin_set_info_style' and prosrc like '%''pfs''%') as pfs_in_style_fn;
