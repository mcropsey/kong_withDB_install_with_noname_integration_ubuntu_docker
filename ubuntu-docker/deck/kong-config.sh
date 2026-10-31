#!/usr/bin/env bash
# Manage Kong with kong.yaml as the source of truth (decK wrapper).
#
#   ./kong-config.sh validate   check kong.yaml: syntax, then against Kong's live schemas (changes nothing)
#   ./kong-config.sh diff       show what apply would create/update/delete (changes nothing)
#   ./kong-config.sh apply      validate, back up live config, show diff, confirm, sync
#   ./kong-config.sh apply -y   same, without the confirmation prompt
#   ./kong-config.sh backup     dump the live config to $BACKUP_DIR
#   ./kong-config.sh restore F  sync a backup file F back into Kong (backs up first)
#
# Env overrides:
#   KONG_ADDR   Admin API (default http://localhost:8001)
#   KONG_YAML   config file (default: kong.yaml next to this script)
#   BACKUP_DIR  where backups go (default ~/kong-backups)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
KONG_ADDR=${KONG_ADDR:-http://localhost:8001}
KONG_YAML=${KONG_YAML:-$HERE/kong.yaml}
BACKUP_DIR=${BACKUP_DIR:-$HOME/kong-backups}
DECK=(deck --kong-addr "$KONG_ADDR")

command -v deck >/dev/null || { echo "deck not installed: see ../deck-yaml-config.md" >&2; exit 1; }

validate() {
  local f=${1:-$KONG_YAML}
  deck file validate "$f"                     # offline: YAML + decK format
  "${DECK[@]}" gateway validate "$f"          # online: plugin/entity schemas from this Kong
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local out
  out="$BACKUP_DIR/kong-$(date +%Y%m%d-%H%M%S).yaml"
  "${DECK[@]}" gateway dump -o "$out" --yes >/dev/null
  echo "live config backed up to $out" >&2
}

sync_file() {   # sync_file <file> [-y]
  local f=$1 yes=${2:-}
  validate "$f"
  backup
  echo "--- planned changes ($f -> $KONG_ADDR) ---"
  "${DECK[@]}" gateway diff "$f"
  if [ "$yes" != "-y" ]; then
    read -r -p "Apply these changes? [y/N] " ans
    [[ $ans == [yY]* ]] || { echo "aborted, nothing changed"; exit 1; }
  fi
  "${DECK[@]}" gateway sync "$f"
}

case ${1:-} in
  validate) validate ;;
  diff)     "${DECK[@]}" gateway diff "$KONG_YAML" ;;
  apply)    sync_file "$KONG_YAML" "${2:-}" ;;
  backup)   backup ;;
  restore)  [ -f "${2:-}" ] || { echo "usage: $0 restore <backup.yaml>" >&2; exit 2; }
            sync_file "$2" "${3:-}" ;;
  *)        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
