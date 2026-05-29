#!/usr/bin/env bash
# lab.sh — thin CLI over the ak-lxd-helper dashboard API for spec-driven LXD experiments.
#
#   lab.sh profile-apply [name]      upload lab/profiles/<...> as an LXD profile (default base-ubuntu)
#   lab.sh expose-lan <name>         give an EXISTING VM a LAN IP (macvlan) + password SSH
#   lab.sh create <name> [profile]   launch a VM from a cloud image + profile (default base-ubuntu)
#   lab.sh wait <name> [tries]       poll until cloud-init reports done (default 90 x 5s)
#   lab.sh exec <name> <cmd...>      run a command in the VM, stream stdout/stderr, exit with its code
#   lab.sh ip <name>                 print the VM's lxdbr0 IPv4
#   lab.sh verify <name>             assert project-001 acceptance criteria
#   lab.sh start|stop|restart <name> lifecycle
#   lab.sh snapshots <name>          list snapshots
#   lab.sh snapshot <name> <snap>    create a snapshot
#   lab.sh restore <name> <snap>     restore a snapshot
#   lab.sh snap-rm <name> <snap>     delete a snapshot
#   lab.sh pkg <name> update|upgrade|install [pkgs]   package management (via exec)
#   lab.sh device-add <name> <dev> <type> [key=val...]   attach a device
#   lab.sh device-rm <name> <dev>    detach a device
#   lab.sh teardown|delete <name>    stop + delete the VM
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
VM_USER="${LAB_VM_USER:-lab}"; VM_PASSWORD="${LAB_VM_PASSWORD:-}"
LAN_PARENT="${LAB_LAN_PARENT:-enP7s7}"

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
  [ -n "$VM_PASSWORD" ] || die "LAB_VM_PASSWORD is empty — set it in .env (used for VM SSH login)"
  local payload
  payload=$(python3 - "$ci" "$CPU" "$MEM" "$DISK" "$VM_USER" "$VM_PASSWORD" "$LAN_PARENT" <<'PY'
import json,sys
ci=open(sys.argv[1]).read(); cpu,mem,disk,user,pw,parent=sys.argv[2:8]
ci=ci.replace("__LAB_VM_USER__",user).replace("__LAB_VM_PASSWORD__",pw)
print(json.dumps({
  "description":"ak-lxd-helper lab base (python3 + miniforge, LAN macvlan, pw SSH)",
  "config":{"limits.cpu":cpu,"limits.memory":mem,"cloud-init.user-data":ci},
  "devices":{
    "root":{"path":"/","pool":"default","type":"disk","size":disk},
    "eth0":{"name":"eth0","network":"lxdbr0","type":"nic"},
    "eth1":{"name":"eth1","nictype":"macvlan","parent":parent,"type":"nic"},
  },
}))
PY
)
  api PUT "/api/profiles/$name" "$payload" >/dev/null \
    && echo "profile '$name' applied (cpu=$CPU mem=$MEM disk=$DISK; LAN macvlan parent=$LAN_PARENT; user=$VM_USER)"
}

# Bring LAN SSH to an EXISTING VM (created before macvlan/creds were in the profile):
# hot-add the eth1 macvlan NIC, ensure the user+password exist, enable password SSH,
# and DHCP the new interface. New VMs get all this from the profile automatically.
cmd_expose_lan() {
  local name="${1:?usage: expose-lan <name>}"
  [ -n "$VM_PASSWORD" ] || die "LAB_VM_PASSWORD is empty — set it in .env"
  echo "adding eth1 macvlan (parent $LAN_PARENT) to $name ..."
  api POST "/api/instances/$name/devices" \
    "$(python3 -c 'import json,sys;print(json.dumps({"name":"eth1","device":{"type":"nic","nictype":"macvlan","parent":sys.argv[1],"name":"eth1"}}))' "$LAN_PARENT")" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('  device:', 'ok' if d.get('ok') else d.get('error'))"
  echo "configuring user + password SSH + DHCP on the new NIC ..."
  # runs as root via exec; idempotent
  cmd_exec "$name" "
    id $VM_USER >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $VM_USER;
    echo '$VM_USER:$VM_PASSWORD' | chpasswd;
    printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-lab.conf;
    sed -i 's/^[# ]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null;
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null;
    IF=\$(for i in \$(ls /sys/class/net | grep -E '^en'); do ip -4 addr show \$i | grep -q 'inet ' || echo \$i; done | head -1);
    if [ -n \"\$IF\" ]; then printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      dhcp4: true\n      optional: true\n' \$IF > /etc/netplan/99-lab-lan.yaml; chmod 600 /etc/netplan/99-lab-lan.yaml; netplan apply; fi;
    echo done" >/dev/null 2>&1 || true
  sleep 4
  echo "LAN IP: $(api GET "/api/instances/$name/access" | python3 -c "import sys,json;print(json.load(sys.stdin)['data'].get('lan_ip') or 'pending (re-check in a few seconds)')")"
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

# -- lifecycle -------------------------------------------------------------
_state() {  # _state <name> <action> <force>
  api POST "/api/instances/$1/state" "{\"action\":\"$2\",\"force\":${3:-false}}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('$2:', (d.get('data') or {}).get('status') if d.get('ok') else d.get('error'))"
}
cmd_start()   { _state "${1:?usage: start <name>}" start false; }
cmd_stop()    { _state "${1:?usage: stop <name>}" stop true; }
cmd_restart() { _state "${1:?usage: restart <name>}" restart true; }

# -- snapshots -------------------------------------------------------------
cmd_snapshots() {
  api GET "/api/instances/${1:?usage: snapshots <name>}/snapshots" | python3 -c "
import sys,json
d=json.load(sys.stdin).get('data') or []
names=[ (s.get('name') if isinstance(s,dict) else str(s)).rsplit('/',1)[-1] for s in d ]
print('\n'.join('  - '+n for n in names) if names else '  (no snapshots)')"
}
cmd_snapshot() {
  local n="${1:?usage: snapshot <name> <snap>}" s="${2:?usage: snapshot <name> <snap>}"
  api POST "/api/instances/$n/snapshots" "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$s")" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('snapshot:', (d.get('data') or {}).get('status') if d.get('ok') else d.get('error'))"
}
cmd_restore() {
  local n="${1:?usage: restore <name> <snap>}" s="${2:?usage: restore <name> <snap>}"
  api POST "/api/instances/$n/snapshots/restore" "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1]}))' "$s")" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('restore:', (d.get('data') or {}).get('status') if d.get('ok') else d.get('error'))"
}
cmd_snap_rm() {
  api DELETE "/api/instances/${1:?usage: snap-rm <name> <snap>}/snapshots/${2:?usage: snap-rm <name> <snap>}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('deleted:', d.get('ok'))"
}

# -- packages (via exec; runs as root) -------------------------------------
cmd_pkg() {
  local n="${1:?usage: pkg <name> update|upgrade|install [pkgs]}" op="${2:?update|upgrade|install}"; shift 2 || true
  case "$op" in
    update)  cmd_exec "$n" "apt-get update" ;;
    upgrade) cmd_exec "$n" "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade" ;;
    install) [ -n "$*" ] || die "pkg install needs package names"
             cmd_exec "$n" "apt-get update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y $*" ;;
    *) die "pkg op must be update|upgrade|install" ;;
  esac
}

# -- devices ---------------------------------------------------------------
cmd_device_add() {  # device-add <name> <devname> <type> key=val ...
  local n="${1:?usage: device-add <name> <dev> <type> [key=val ...]}"
  local dev="${2:?dev name}" type="${3:?device type}"; shift 3
  local payload
  payload=$(python3 - "$dev" "$type" "$@" <<'PY'
import json,sys
d={"type":sys.argv[2]}
for kv in sys.argv[3:]:
    k,_,v=kv.partition('='); d[k]=v
print(json.dumps({"name":sys.argv[1],"device":d}))
PY
)
  api POST "/api/instances/$n/devices" "$payload" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('attach:', 'ok' if d.get('ok') else d.get('error'))"
}
cmd_device_rm() {
  api DELETE "/api/instances/${1:?usage: device-rm <name> <dev>}/devices/${2:?dev name}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('detach:', d.get('ok'))"
}

sub="${1:-}"; shift || true
case "$sub" in
  profile-apply) cmd_profile_apply "$@" ;;
  expose-lan)    cmd_expose_lan "$@" ;;
  create)        cmd_create "$@" ;;
  wait)          cmd_wait "$@" ;;
  exec)          cmd_exec "$@" ;;
  ip)            cmd_ip "$@" ;;
  verify)        cmd_verify "$@" ;;
  start)         cmd_start "$@" ;;
  stop)          cmd_stop "$@" ;;
  restart)       cmd_restart "$@" ;;
  snapshots)     cmd_snapshots "$@" ;;
  snapshot)      cmd_snapshot "$@" ;;
  restore)       cmd_restore "$@" ;;
  snap-rm)       cmd_snap_rm "$@" ;;
  pkg)           cmd_pkg "$@" ;;
  device-add)    cmd_device_add "$@" ;;
  device-rm)     cmd_device_rm "$@" ;;
  teardown|delete) cmd_teardown "$@" ;;
  *) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
