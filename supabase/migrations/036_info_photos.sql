-- 036: 홈 안내 창에 사진 넣기(2026-11-04 사용자 요청·선택: 관리자 화면에서 직접 올리기)
-- · 사진은 Supabase Storage의 공개 버킷 'info-photos'에 저장합니다(무료 플랜 저장 공간 1GB, 화면이 올리기 전에 약 200KB로 줄임).
-- · 누구나 사진을 볼 수 있지만(손님에게 보이는 안내 사진), 올리기·지우기는 관리자만 할 수 있습니다.
-- · 안내 글의 칸마다 사진 목록(imgs: 버킷 안 파일 이름)을 함께 저장합니다(035의 admin_set_info_page를 고침).

-- 1) 공개 버킷: 파일 하나 2MB까지, 그림 파일만
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('info-photos', 'info-photos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- 2) 관리자만 올리기·바꾸기·지우기(로그인 + admins 표에 있어야 함). 보기는 공개 버킷 주소로 누구나.
drop policy if exists "info_photos_admin_insert" on storage.objects;
drop policy if exists "info_photos_admin_update" on storage.objects;
drop policy if exists "info_photos_admin_delete" on storage.objects;
drop policy if exists "info_photos_admin_select" on storage.objects;
create policy "info_photos_admin_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'info-photos' and public.is_admin());
create policy "info_photos_admin_update" on storage.objects for update to authenticated
  using (bucket_id = 'info-photos' and public.is_admin()) with check (bucket_id = 'info-photos' and public.is_admin());
create policy "info_photos_admin_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'info-photos' and public.is_admin());
create policy "info_photos_admin_select" on storage.objects for select to authenticated
  using (bucket_id = 'info-photos' and public.is_admin());

-- 3) 안내 글 저장: 칸마다 사진(imgs) 6장까지, 파일 이름은 "창/숫자-글자.jpg" 모양만(다른 주소는 못 넣음)
create or replace function public.admin_set_info_page(p_key text, p_sections jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s jsonb; out jsonb := '[]'::jsonb; t text; b text; cur jsonb; imgs jsonb; im jsonb;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  if p_key is null or p_key not in ('first', 'way', 'room', 'stu', 'ext') then
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
      out := out || jsonb_build_array(jsonb_build_object('t', t, 'b', b) || case when jsonb_array_length(imgs) > 0 then jsonb_build_object('imgs', imgs) else '{}'::jsonb end);
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
