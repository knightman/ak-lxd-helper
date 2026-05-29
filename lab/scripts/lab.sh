#!/usr/bin/env bash
# lab.sh — thin CLI over the ak-lxd-helper dashboard API for spec-driven LXD experiments.
#
#   lab.sh profile-apply [name]      upload lab/profiles/<...> as an LXD profile (default base-ubuntu)
#   lab.sh create <name> [profile]   launch a VM from a cloud image + profile (default base-ubuntu)
#   lab.sh wait <name> [tries]       poll until cloud-init reports done (default 90 x 5s)
#   lab.sh exec <name> <cmd...>      run a command in the VM, stream stdout/stderr, exit with its code
#   lab.sh ip <name>                 print the VM's lxdbr0 IPv4
#   lab.sh verify <name>             assert project-001 acceptance criteria
#   lab.sh teardown <name>           stop + delete the VM
#
# Env: AK_LXD_URL (default http://127.0.0.1:8080), LAB_CPU, LAB_MEM, LAB_DISK,
#      LAB_RELEASE (default 24.04), LAB_IMAGE_SERVER.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB="$ROOT/lab"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

URL="${AK_LXD_URL:-http://127.0.0.1:8080}"
CPU="${LAB_CPU:-2}"; MEM="${LAB_MEM:-4GiB}"; DISK="${LAB_DISK:-20GiB}"
RELEASE="${LAB_RELEASE:-24.04}"
IMAGE_SERVER="${LAB_IMAGE_SERVER:-https://cloud-images.ubuntu.com/releases}"

die() { echo "error: $*" >&2; exit 1; }
api() { # api METHOD PATH [json]
  local m="$1" p="$2" d="${3:-}"
  if [ -n "$d" ]; then curl -fsS -X "$m" "$URL$p" -H 'content-type: application/json' -d "$d"
  else curl -fsS -X "$m" "$URL$p"; fi
}
# extract data.stdout (or '') from an exec response on stdin
_exec_stdout() { python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); sys.exit()
print((d.get('data') or {}).get('stdout','') if d.get('ok') else '')"; }

cmd_profile_apply() {
  local name="${1:-base-ubuntu}"
  local ci="$LAB/profiles/${name}.cloud-init.yaml"
  [ -f "$ci" ] || die "missing cloud-init file: $ci"
  local payload
  payload=$(python3 - "$ci" "$CPU" "$MEM" "$DISK" <<'PY'
import json,sys
ci=open(sys.argv[1]).read(); cpu,mem,disk=sys.argv[2:5]
print(json.dumps({
  "description":"ak-lxd-helper lab base (cloud-init: python3 + miniforge)",
  "config":{"limits.cpu":cpu,"limits.memory":mem,"cloud-init.user-data":ci},
  "devices":{
    "root":{"path":"/","pool":"default","type":"disk","size":disk},
    "eth0":{"name":"eth0","network":"lxdbr0","type":"nic"},
  },
}))
PY
)
  api PUT "/api/profiles/$name" "$payload" >/dev/null && echo "profile '$name' applied (cpu=$CPU mem=$MEM disk=$DISK)"
}

cmd_create() {
  local name="${1:?usage: create <name> [profile]}" profile="${2:-base-ubuntu}"
  local payload
  payload=$(python3 - "$name" "$profile" "$IMAGE_SERVER" "$RELEASE" <<'PY'
import json,sys
name,profile,server,alias=sys.argv[1:5]
print(json.dumps({"name":name,"type":"virtual-machine","start":True,
  "profiles":[profile],
  "image":{"server":server,"protocol":"simplestreams","alias":alias}}))
PY
)
  echo "creating $name (VM, ubuntu $RELEASE cloud image, profile $profile)..."
  api POST "/api/instances" "$payload" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('  ->', (d.get('data') or {}).get('status') if d.get('ok') else 'ERROR: '+str(d.get('error')))"
}

cmd_exec() {
  local name="${1:?usage: exec <name> <cmd...>}"; shift
  local out
  out=$(api POST "/api/instances/$name/exec" \
        "$(python3 -c 'import json,sys;print(json.dumps({"command":" ".join(sys.argv[1:])}))' "$@")")
  echo "$out" | python3 -c "import sys,json
d=json.load(sys.stdin); data=d.get('data') or {}
sys.stdout.write(data.get('stdout','')); sys.stderr.write(data.get('stderr',''))
sys.exit(0 if data.get('return')==0 else 1)"
}

cmd_wait() {
  local name="${1:?usage: wait <name> [tries]}" tries="${2:-90}"
  echo "waiting for lxd-agent + cloud-init on $name..."
  local i out
  for i in $(seq 1 "$tries"); do
    out=$(api POST "/api/instances/$name/exec" '{"command":"cloud-init status"}' 2>/dev/null | _exec_stdout || true)
    case "$out" in
      *"status: done"*)  echo "cloud-init: done"; return 0 ;;
      *"status: error"*) echo "cloud-init: ERROR"; echo "$out"; return 1 ;;
    esac
    sleep 5
  done
  die "timed out waiting for cloud-init on $name"
}

cmd_ip() {
  local name="${1:?usage: ip <name>}"
  api GET "/api/instances/$name" | python3 -c "import sys,json
d=json.load(sys.stdin)['data']; net=(d.get('state') or {}).get('network') or {}
for i,n in net.items():
  if i=='lo': continue
  for a in n.get('addresses',[]):
    if a.get('family')=='inet' and a.get('scope')=='global': print(a['address']); sys.exit()"
}

cmd_verify() {
  local name="${1:?usage: verify <name>}"; local fail=0
  echo "== verify $name =="
  _check() { printf '  %-22s ' "$1:"; if out=$(cmd_exec "$name" "${@:2}" 2>/dev/null); then echo "${out%%$'\n'*}"; else echo "FAIL"; fail=1; fi; }
  _check "cloud-init"  cloud-init status
  _check "python3"     python3 --version
  _check "conda"       conda --version
  _check "network(apt)" "apt-get update -qq >/dev/null 2>&1 && echo NET_OK || echo NET_FAIL"
  if [ "$fail" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; return 1; fi
}

cmd_teardown() {
  local name="${1:?usage: teardown <name>}"
  api POST "/api/instances/$name/state" '{"action":"stop","force":true}' >/dev/null 2>&1 || true
  api DELETE "/api/instances/$name" >/dev/null && echo "deleted $name"
}

sub="${1:-}"; shift || true
case "$sub" in
  profile-apply) cmd_profile_apply "$@" ;;
  create)        cmd_create "$@" ;;
  wait)          cmd_wait "$@" ;;
  exec)          cmd_exec "$@" ;;
  ip)            cmd_ip "$@" ;;
  verify)        cmd_verify "$@" ;;
  teardown)      cmd_teardown "$@" ;;
  *) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
