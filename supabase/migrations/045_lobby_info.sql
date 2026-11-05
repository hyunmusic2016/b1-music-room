-- 045_lobby_info.sql : 학원 로비 PC 화면(room.hyunmusic.com/academy/)의 오른쪽 안내 상자(2026-11-05 사용자 요청)
-- · settings.lobby_info = {boxes:[{id,type,title,body,style,scale,hidden}], ls, updated_at}
--   type: text(글 상자) | qr(예약 주소 QR 상자), style: list(목록) | alert(가운데 빨강) | plain(일반) | center(가운데)
--   scale: 글씨 크기 70~160(%), ls: 전체 자간(em, -0.1~0.05)
-- · 공개 lobby_info(): 저장된 상자(없으면 boxes null → 화면의 기본 글)
-- · 관리자 admin_set_lobby_info(p): 저장, p가 null이면 지움(기본 글로 되돌리기). 글은 문자 그대로 저장(화면이 HTML을 막음).

create or replace function public.lobby_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('ok', true,
    'boxes', (select value->'boxes' from public.settings where key = 'lobby_info'),
    'ls', coalesce((select value->'ls' from public.settings where key = 'lobby_info'), '0'::jsonb),
    'updated_at', (select value->'updated_at' from public.settings where key = 'lobby_info'))
$$;

create or replace function public.admin_set_lobby_info(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b jsonb; out jsonb := '[]'::jsonb; i int := 0; t text; st text; sc int; ls numeric; id text;
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
    out := out || jsonb_build_array(jsonb_build_object('id', id, 'type', t, 'title', coalesce(b->>'title', ''),
      'body', coalesce(b->>'body', ''), 'style', st, 'scale', sc, 'hidden', coalesce((b->>'hidden')::boolean, false)));
  end loop;
  begin ls := coalesce((p->>'ls')::numeric, 0); exception when others then ls := 0; end;
  ls := greatest(-0.1, least(0.05, ls));
  insert into public.settings (key, value) values ('lobby_info',
    jsonb_build_object('boxes', out, 'ls', ls, 'updated_at', public.app_today()::text))
    on conflict (key) do update set value = excluded.value;
  perform public.audit('admin', 'lobby_info', '{}'::jsonb);
  return public.lobby_info();
end $$;

revoke execute on function public.lobby_info() from public, anon, authenticated;
revoke execute on function public.admin_set_lobby_info(jsonb) from public, anon, authenticated;
grant execute on function public.lobby_info() to anon, authenticated;
grant execute on function public.admin_set_lobby_info(jsonb) to authenticated;
