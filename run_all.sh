#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

export SA_PASSWORD="${SA_PASSWORD:-Recon_local_2026}"
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

# public kaggle dataset, no login needed for this endpoint
if [ ! -f data/olist/olist_orders_dataset.csv ]; then
  echo "downloading olist dataset..."
  mkdir -p data/olist
  curl -fsSL -o data/olist/olist.zip https://www.kaggle.com/api/v1/datasets/download/olistbr/brazilian-ecommerce
  unzip -o -q data/olist/olist.zip -d data/olist
  rm data/olist/olist.zip
fi

docker compose up -d

# -I because sqlcmd defaults QUOTED_IDENTIFIER off, -b so errors stop the run
sql() {
  docker compose exec -T db "$SQLCMD" -S localhost -U sa -P "$SA_PASSWORD" -C -b -I -W "$@"
}

echo "waiting for sql server..."
for i in $(seq 1 90); do
  if sql -Q "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "sql server never came up" >&2
    docker compose logs --tail 40 db
    exit 1
  fi
  sleep 2
done

for f in sql/[0-9]*.sql; do
  echo
  echo "== $f"
  start=$SECONDS
  sql -i "/sql/$(basename "$f")"
  echo "   ($((SECONDS - start))s)"
done
