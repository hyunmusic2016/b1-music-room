-- 029_stu_phone_optional.sql : 이용자 등록·수정에서 재원생은 전화번호를 비워 둘 수 있게(2026-11-02 사용자 요청)
-- · 재원생(type stu)이고 전화번호 칸이 비어 있으면 빈 값('')으로 저장합니다. 적었는데 형식이 틀리면 전처럼 막습니다.
-- · 일반회원(ext)은 지금처럼 전화번호 필수입니다(비밀번호 = 연락하신 전화번호 뒤 4자리, 관리자 연락용).
-- · 나머지는 020의 check_user_fields와 같습니다.

create or replace function public.check_user_fields(p jsonb, need_pw boolean) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare n text := public.norm_name(trim(p->>'name')); ph text := public.fmt_phone(p->>'phone'); pw text := coalesce(p->>'pw', '');
begin
  if coalesce(p->>'type', '') not in ('stu','ext') then return public.fail('재원생 또는 일반회원을 선택하십시오.'); end if;
  if not public.valid_name(n) then return public.fail('이름을 한글 2~5자 또는 영문으로 입력하십시오.'); end if;
  if (need_pw or pw <> '') and not public.valid_pw(pw) then return public.fail('비밀번호는 숫자 4자리입니다.'); end if;
  if ph is null then
    if p->>'type' = 'stu' and trim(coalesce(p->>'phone', '')) = '' then ph := '';  -- 029: 재원생은 전화번호 없어도 됨
    elsif p->>'type' = 'stu' then return public.fail('전화번호를 올바르게 입력하시거나 비워 두십시오. (예: 010-1234-5678)');
    else return public.fail('전화번호를 올바르게 입력하십시오. (예: 010-1234-5678)'); end if;
  end if;
  return jsonb_build_object('ok', true, 'name', n, 'phone', ph,
    'part', left(trim(coalesce(p->>'part', '')), 20), 'memo', left(trim(coalesce(p->>'memo', '')), 100));
end $$;
revoke execute on function public.check_user_fields(jsonb, boolean) from public, anon, authenticated;
