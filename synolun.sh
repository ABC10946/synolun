#!/usr/bin/env bash
# CLI for Synology DSM iSCSI LUN management via the DSM Web API
# (the same API synology-csi uses: SYNO.Core.ISCSI.LUN).
#
# Config (env vars):
#   DSM_HOST      required, e.g. 192.168.10.50
#   DSM_PORT      default 5000
#   DSM_SCHEME    default http (use https for port 5001)
#   DSM_INSECURE  set to 1 to skip TLS verification (self-signed certs)
#
# Usage:
#   ./synolun.sh login <account>          # prompts for password, caches session
#   ./synolun.sh logout
#   ./synolun.sh list                     # list all LUNs
#   ./synolun.sh get <uuid>               # show one LUN's detail
#   ./synolun.sh delete <uuid> [uuid...]  # delete one or more LUNs (confirms unless -y)
#
# Session is cached in ~/.config/synolun/session (mode 600) so login is only
# needed once per shell session / until the sid expires.

set -euo pipefail

DSM_PORT="${DSM_PORT:-5000}"
DSM_SCHEME="${DSM_SCHEME:-http}"
SESSION_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/synolun"
SESSION_FILE="$SESSION_DIR/session"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

curl_opts=(-s)
[ "${DSM_INSECURE:-0}" = "1" ] && curl_opts+=(-k)

base_url() {
  : "${DSM_HOST:?Set DSM_HOST to the NAS address, e.g. 192.168.10.50}"
  echo "${DSM_SCHEME}://${DSM_HOST}:${DSM_PORT}"
}

require_session() {
  [ -f "$SESSION_FILE" ] || { echo "Not logged in. Run: $0 login <account>" >&2; exit 1; }
  cat "$SESSION_FILE"
}

# json_get <json> <dotted.path>  -- e.g. json_get "$resp" data.sid
json_get() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    d = d[k]
print(d if isinstance(d, str) else json.dumps(d))
' "$1" "$2"
}

json_success() {
  python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("success") else 1)' "$1"
}

cmd_login() {
  local account="${1:?usage: $0 login <account>}"
  local password
  read -r -s -p "Password for ${account}@${DSM_HOST}: " password
  echo >&2

  local resp
  resp=$(curl "${curl_opts[@]}" -G "$(base_url)/webapi/auth.cgi" \
    --data-urlencode "api=SYNO.API.Auth" \
    --data-urlencode "version=6" \
    --data-urlencode "method=login" \
    --data-urlencode "account=${account}" \
    --data-urlencode "passwd=${password}" \
    --data-urlencode "session=FileStation" \
    --data-urlencode "format=sid")

  if ! json_success "$resp"; then
    echo "Login failed: $resp" >&2
    exit 1
  fi

  local sid
  sid=$(json_get "$resp" data.sid)

  mkdir -p "$SESSION_DIR"
  printf '%s\n%s\n' "$(base_url)" "$sid" > "$SESSION_FILE"
  chmod 600 "$SESSION_FILE"
  echo "Logged in. Session cached at $SESSION_FILE"
}

cmd_logout() {
  if [ -f "$SESSION_FILE" ]; then
    local url sid
    url=$(sed -n 1p "$SESSION_FILE")
    sid=$(sed -n 2p "$SESSION_FILE")
    curl "${curl_opts[@]}" -G "$url/webapi/auth.cgi" \
      --data-urlencode "api=SYNO.API.Auth" \
      --data-urlencode "version=6" \
      --data-urlencode "method=logout" \
      --data-urlencode "session=FileStation" \
      --data-urlencode "_sid=$sid" >/dev/null || true
    rm -f "$SESSION_FILE"
  fi
  echo "Logged out."
}

api_post() {
  # api_post <api> <version> <method> [extra curl --data-urlencode args...]
  local api="$1" version="$2" method="$3"; shift 3
  local session url sid
  session=$(require_session)
  url=$(echo "$session" | sed -n 1p)
  sid=$(echo "$session" | sed -n 2p)

  curl "${curl_opts[@]}" -X POST "$url/webapi/entry.cgi" \
    --data-urlencode "api=${api}" \
    --data-urlencode "version=${version}" \
    --data-urlencode "method=${method}" \
    --data-urlencode "_sid=${sid}" \
    "$@"
}

cmd_list() {
  local resp
  resp=$(api_post "SYNO.Core.ISCSI.LUN" 1 list \
    --data-urlencode 'additional=["status","size","is_mapped","location"]')

  if ! json_success "$resp"; then
    echo "List failed: $resp" >&2
    exit 1
  fi

  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
luns = d["data"]["luns"]
fmt = "{:<38} {:<28} {:>10} {:<10} {}"
print(fmt.format("UUID", "NAME", "SIZE(GiB)", "MAPPED", "STATUS"))
for l in luns:
    size_gib = round(int(l.get("size", 0)) / 1024**3, 1)
    print(fmt.format(l.get("uuid",""), l.get("name",""), size_gib, str(l.get("is_mapped","")), l.get("status","")))
' "$resp"
}

cmd_get() {
  local uuid="${1:?usage: $0 get <uuid>}"
  local resp
  resp=$(api_post "SYNO.Core.ISCSI.LUN" 1 get \
    --data-urlencode "uuid=\"${uuid}\"" \
    --data-urlencode 'additional=["status","size","is_mapped","location","mapped_targets"]')

  if ! json_success "$resp"; then
    echo "Get failed: $resp" >&2
    exit 1
  fi
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["data"], indent=2, ensure_ascii=False))' "$resp"
}

cmd_delete() {
  local yes=0
  local uuids=()
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) yes=1 ;;
      *) uuids+=("$arg") ;;
    esac
  done
  [ "${#uuids[@]}" -ge 1 ] || { echo "usage: $0 delete [-y] <uuid> [uuid...]" >&2; exit 1; }

  if [ "$yes" -ne 1 ]; then
    echo "About to delete ${#uuids[@]} LUN(s):"
    printf '  %s\n' "${uuids[@]}"
    read -r -p "Type 'yes' to proceed: " confirm
    [ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
  fi

  for uuid in "${uuids[@]}"; do
    local resp
    resp=$(api_post "SYNO.Core.ISCSI.LUN" 1 delete --data-urlencode "uuid=\"${uuid}\"")
    if json_success "$resp"; then
      echo "deleted: $uuid"
    else
      echo "FAILED:  $uuid -> $resp" >&2
    fi
  done
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    login)   cmd_login "$@" ;;
    logout)  cmd_logout "$@" ;;
    list)    cmd_list "$@" ;;
    get)     cmd_get "$@" ;;
    delete)  cmd_delete "$@" ;;
    *)
      echo "usage: $0 {login|logout|list|get|delete} ..." >&2
      exit 1
      ;;
  esac
}

main "$@"
