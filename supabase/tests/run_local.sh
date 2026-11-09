#!/usr/bin/env bash
# 로컬 PostgreSQL에 빈 DB를 만들고 마이그레이션 + 시험을 실행합니다.
# 사용법: PGHOST=<소켓 폴더> PGPORT=<포트> bash supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
P="psql -U postgres -v ON_ERROR_STOP=1 -q -tA"
$P -c "drop database if exists drum_test" -c "create database drum_test"
# 01 시험은 047까지의 규칙을 시험하고, 048(정액권 없애기)은 그 결과(남은 정액권 등) 위에 실행한 뒤 03으로 시험합니다.
for f in supabase/tests/00_local_shim.sql supabase/migrations/00*.sql supabase/migrations/0[1-3]*.sql supabase/migrations/04[0-7]*.sql \
         supabase/tests/01_rules_test.sql supabase/migrations/04[8-9]*.sql supabase/migrations/0[5-9]*.sql supabase/tests/03_no_flat_test.sql; do
  [ -e "$f" ] || continue
  echo "== $f"
  $P -d drum_test -f "$f"
done
