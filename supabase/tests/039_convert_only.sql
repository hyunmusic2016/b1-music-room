-- 로컬 시험 전용: 039의 옛 자료 변환 부분만(01_rules_test.sql이 불러 씀)
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
