-- 로컬 시험 전용: 041의 옛 자료 변환 부분만(01_rules_test.sql이 불러 씀)
do $$
declare cur jsonb := coalesce((select value from public.settings where key = 'info_pages'), '{}'::jsonb);
  k text; pg jsonb; s jsonb; out jsonb; d text; n int; lay jsonb; changed boolean := false;
begin
  for k, pg in select key, value from jsonb_each(cur) loop
    continue when jsonb_typeof(pg->'sections') <> 'array';
    out := '[]'::jsonb;
    for s in select value from jsonb_array_elements(pg->'sections') loop
      if (s ? 'size' or s ? 'cols') and not (s ? 'lay') then
        n := coalesce(jsonb_array_length(case when jsonb_typeof(s->'imgs') = 'array' then s->'imgs' end), 0);
        d := case when coalesce(s->>'cols', '1') in ('2', '3') then s->>'cols' else '1' || coalesce(nullif(s->>'size', ''), 'l') end;
        s := s - 'size' - 'cols';
        if n > 0 and d <> '1l' then
          select jsonb_agg(to_jsonb(d)) into lay from generate_series(1, n);
          s := s || jsonb_build_object('lay', lay);
        end if;
        changed := true;
      end if;
      out := out || jsonb_build_array(s);
    end loop;
    cur := cur || jsonb_build_object(k, pg || jsonb_build_object('sections', out));
  end loop;
  if changed then update public.settings set value = cur where key = 'info_pages'; end if;
end $$;
