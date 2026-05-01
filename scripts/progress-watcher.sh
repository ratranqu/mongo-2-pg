#!/usr/bin/env bash
# Watch a database's restore progress against the target server and print one
# line per poll showing percentage, rate, and ETA.
#
# Usage: progress-watcher.sh <target-uri> <db-name> <total-docs> <total-bytes> [interval-seconds]
#
# Designed to be backgrounded by migrate.sh and SIGTERM'd when the migration
# finishes; exits on its own once <db-name> reaches >= total-docs.
set -euo pipefail

TARGET_URI="${1:?Usage: progress-watcher.sh <target-uri> <db-name> <total-docs> <total-bytes> [interval]}"
DB_NAME="${2:?Missing db-name}"
TOTAL_DOCS="${3:?Missing total-docs}"
TOTAL_BYTES="${4:?Missing total-bytes}"
INTERVAL="${5:-30}"

(( INTERVAL <= 0 )) && exit 0
[[ "$TOTAL_DOCS" =~ ^[0-9]+$ ]] || exit 0
(( TOTAL_DOCS == 0 ))         && exit 0

_fmt_duration() {
  local s=$1
  if   (( s <  60 )); then printf '%ds'      "$s"
  elif (( s < 3600 )); then printf '%dm%02ds' $((s/60)) $((s%60))
  elif (( s < 86400 )); then printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
  else                      printf '%dd%02dh' $((s/86400)) $(((s%86400)/3600))
  fi
}

_fmt_size() {
  awk -v b="$1" 'BEGIN {
    if      (b >= 1099511627776) printf "%.1f TB", b/1099511627776
    else if (b >= 1073741824)    printf "%.1f GB", b/1073741824
    else if (b >= 1048576)       printf "%.0f MB", b/1048576
    else if (b >= 1024)          printf "%.0f KB", b/1024
    else                         printf "%d B",    b
  }'
}

TOTAL_FMT=$(_fmt_size "$TOTAL_BYTES")

START_TS=$(date +%s)
LAST_DOCS=0
LAST_TS=$START_TS

# Settle a couple of seconds before the first poll so the migration has had a
# chance to issue its first inserts.
sleep 2

while :; do
  cur=$(mongosh --quiet --norc "$TARGET_URI" --eval "
    let t = 0;
    const d = db.getSiblingDB('${DB_NAME}');
    d.getCollectionNames().forEach(c => {
      try { t += d.getCollection(c).estimatedDocumentCount(); } catch (e) {}
    });
    print(t);
  " 2>/dev/null | tail -1)
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0

  now=$(date +%s)
  pct=$(awk -v c="$cur" -v t="$TOTAL_DOCS" 'BEGIN { printf "%.1f", (t>0 ? c/t*100 : 0) }')
  rate=0
  (( now > LAST_TS )) && rate=$(( (cur - LAST_DOCS) / (now - LAST_TS) ))

  if (( rate > 0 && cur < TOTAL_DOCS )); then
    eta=$(_fmt_duration $(( (TOTAL_DOCS - cur) / rate )))
  else
    eta="?"
  fi

  printf '    %-32s %5s%%  %s/%s docs  %s total  %s docs/s  ETA %s\n' \
    "$DB_NAME" "$pct" "$cur" "$TOTAL_DOCS" "$TOTAL_FMT" "$rate" "$eta"

  (( cur >= TOTAL_DOCS )) && exit 0

  LAST_DOCS=$cur
  LAST_TS=$now
  sleep "$INTERVAL"
done
