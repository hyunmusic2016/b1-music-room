-- 032: 일반회원 예약의 입금 확인 표시(관리자 전용, 2026-11-03 사용자 요청)
-- 대상: 일반회원(is_ext)이 정액권·횟수권 없이(product_id 없음) 한 확정 예약, 슈퍼패스 제외(사용자 선택).
-- 예약 자체에는 아무 영향이 없습니다(확인하지 않아도 예약은 그대로 확정). 관리자가 입금을 봤는지 표시만 합니다.
-- 공개 응답(public_board, my_reservations 등)에는 넣지 않습니다.

alter table public.reservations add column if not exists pay_ok boolean not null default false;
alter table public.reservations add column if not exists pay_ok_at timestamptz;

-- 관리자 예약 목록: 입금 확인 대상 여부(pay_need)와 확인 여부(pay_ok)를 함께 줍니다.
create or replace function public.admin_reservations() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then return public.not_admin(); end if;
  return jsonb_build_object('ok', true, 'now', public.app_now(), 'list', coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'date', r.date, 'hour', r.hour, 'name', r.name, 'status', r.status,
             'reason', r.cancel_reason, 'prod', r.product_kind, 'ext', r.is_ext, 'by_admin', r.by_admin, 'super', r.is_super,
             'user_id', r.user_id, 'ended', public.slot_ended(r.date, r.hour),
             'pay_need', (r.is_ext and r.product_id is null and not r.is_super),
             'pay_ok', r.pay_ok) order by r.date, r.hour)
      from public.reservations r where r.date >= public.keep_from()), '[]'));
end $$;

-- 입금 확인 / 확인 취소
create or replace function public.admin_set_paid(p_id bigint, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.reservations;
begin
  if not public.is_admin() then return public.not_admin(); end if;
  select * into r from public.reservations where id = p_id for update;
  if not found then return public.fail('없는 예약입니다.', true); end if;
  if r.status <> 'confirmed' then return public.fail('취소된 예약은 입금 확인을 할 수 없습니다.', true); end if;
  if not (r.is_ext and r.product_id is null and not r.is_super) then
    return public.fail('입금 확인은 일반회원이 정액권·횟수권 없이 한 예약에만 할 수 있습니다.', true);
  end if;
  update public.reservations set pay_ok = coalesce(p_ok, false),
         pay_ok_at = case when coalesce(p_ok, false) then now() else null end
   where id = p_id;
  perform public.audit('admin', 'set_paid', jsonb_build_object('id', p_id, 'ok', coalesce(p_ok, false)));
  return jsonb_build_object('ok', true, 'id', p_id, 'pay_ok', coalesce(p_ok, false));
end $$;

revoke execute on function public.admin_reservations() from public, anon, authenticated;
revoke execute on function public.admin_set_paid(bigint, boolean) from public, anon, authenticated;
grant execute on function public.admin_reservations() to authenticated;
grant execute on function public.admin_set_paid(bigint, boolean) to authenticated;
