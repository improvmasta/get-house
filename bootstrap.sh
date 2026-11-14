#!/bin/bash
# House: from a fresh Proxmox to a working House. Run on the Proxmox host, as root:
#
#     curl -fsSL https://raw.githubusercontent.com/improvmasta/get-house/main/bootstrap.sh | bash
#
# or, from a copy of this file:   bash bootstrap.sh
#
# It asks whether this is a new house or one being rebuilt, checks the host's network while it is still easy to
# change, makes a small Debian container that runs nothing but House, starts House in it from its image, and lets
# House connect to this Proxmox with its own user, token and SSH key. Then it prints the address to open. Guests,
# apps and the router are made in House, where there are plans, progress and undo.
#
# Run again, it picks up where it stopped: every step looks at what is there before it does anything.
#
#   HOUSE_IMAGE     House's image (default ghcr.io/improvmasta/house:latest)
#   HOUSE_SCRIPT    where this script is fetched from, for the lines that say how to run it again
#   HOUSE_MODE      new or rebuild: skips the first question
#   HOUSE_NETWORK   keep or change: skips that question (change also needs HOUSE_NEW_NAME, HOUSE_NEW_ADDRESS, HOUSE_NEW_GATEWAY, HOUSE_NEW_DNS)
#   HOUSE_CTID      the container's ID (default: the next free)
#   HOUSE_ADDRESS   the container's address (default: asked, with the first free one near the host's offered)
#   HOUSE_STORAGE   where the container's disk goes (default: the storage with the most room)
#   HOUSE_PORT      the port House listens on (default 8480)
#   HOUSE_YES       =1: take every offered default without asking
#   HOUSE_DRY_RUN   =1: say what would be done and change nothing
#   HOUSE_ROOT      a folder standing in for / (the tests'): the files this reads and writes are under it
#
# After a network change made over SSH, the old settings come back by themselves in two minutes unless it is
# confirmed from the new address: the same command with `confirm` (the script says the exact line).

set -eu

ROOT="${HOUSE_ROOT:-}"
DRY="${HOUSE_DRY_RUN:-}"
YES="${HOUSE_YES:-}"
PORT="${HOUSE_PORT:-8480}"
IMAGE="${HOUSE_IMAGE-ghcr.io/improvmasta/house:latest}"
SCRIPT_URL="${HOUSE_SCRIPT:-https://raw.githubusercontent.com/improvmasta/get-house/main/bootstrap.sh}"
# How to run this again with a word after it: from the file when it is one, from where it was fetched when it was piped in.
case "$0" in *bootstrap.sh) again() { printf 'bash %s%s' "$0" "${1:+ $1}"; } ;; *) again() { printf 'curl -fsSL %s | bash%s' "$SCRIPT_URL" "${1:+ -s $1}"; } ;; esac
TTY="${HOUSE_TTY:-/dev/tty}"
STATE="$ROOT/var/lib/house-bootstrap"
UNDO="$ROOT/root/house-undo"
IFACES="$ROOT/etc/network/interfaces"
OS="debian-12-standard"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf ' ! %s\n' "$*"; }
die() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }
exec 3>&1   # what a dry run says it would do is always said, even where a command's own output is thrown away
run() { if [ -n "$DRY" ]; then note "would run: $*" >&3; else "$@"; fi; }
# ask "question" "default": the answer, or the default on Enter. With HOUSE_YES, or nobody to ask, the default.
ask() {
  if [ -n "$YES" ] || [ ! -r "$TTY" ]; then printf '%s' "$2"; return 0; fi
  printf '%s%s: ' "$1" "${2:+ [$2]}" > "$TTY"
  IFS= read -r reply < "$TTY" || reply=""
  printf '%s' "${reply:-$2}"
}
is_ip() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_name() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,62}$'; }

# ---------------------------------------------------------------- the host's network, as it is

read_network() {
  DEV="$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')"
  GATEWAY="$(ip -4 route show default 2>/dev/null | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") print $(i+1); exit}')"
  CIDR="$(ip -4 -o addr show dev "${DEV:-none}" 2>/dev/null | awk '{print $4; exit}')"
  ADDRESS="${CIDR%/*}"; BITS="${CIDR#*/}"
  NAME="$(hostname)"
  DNS="$(awk '/^nameserver/ {print $2}' "$ROOT/etc/resolv.conf" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')"
  # How the address is saved: the stanza for that interface in /etc/network/interfaces.
  SAVED_HOW="$(awk -v d="$DEV" '$1=="iface" && $2==d && $3=="inet" {print $4; exit}' "$IFACES" 2>/dev/null)"
  SAVED_ADDR="$(awk -v d="$DEV" '$1=="iface" {on=($2==d)} on && $1=="address" {print $2; exit}' "$IFACES" 2>/dev/null)"
  SAVED_GW="$(awk -v d="$DEV" '$1=="iface" {on=($2==d)} on && $1=="gateway" {print $2; exit}' "$IFACES" 2>/dev/null)"
  HOSTS_ADDR="$(awk -v n="$NAME" '!/^#/ {for (i=2;i<=NF;i++) if ($i==n) {print $1; exit}}' "$ROOT/etc/hosts" 2>/dev/null)"
  GUESTS="$( { pct list 2>/dev/null | tail -n +2; qm list 2>/dev/null | tail -n +2; } | grep -c . || true)"
}

show_network() {
  say ""
  printf '   %-10s %-22s %s\n' "" "Now" "Saved in"
  printf '   %-10s %-22s %s\n' "Name" "$NAME" "/etc/hostname, /etc/hosts"
  printf '   %-10s %-22s %s\n' "Address" "${CIDR:-none}" "/etc/network/interfaces ($DEV, ${SAVED_HOW:-not there})"
  printf '   %-10s %-22s %s\n' "Gateway" "${GATEWAY:-none}" "/etc/network/interfaces"
  printf '   %-10s %-22s %s\n' "DNS" "${DNS:-none}" "/etc/resolv.conf"
  say ""
  note "The name becomes the Proxmox node name, and every guest is filed under it."
  note "The address is what House and every guest are told to reach."
  note "Both are hard to change once there are guests. Now is the time."
}

# What a beginner gets wrong. Sets PROBLEMS to how many were found.
check_network() {
  PROBLEMS=0
  bad() { warn "$*"; PROBLEMS=$((PROBLEMS + 1)); }
  [ -n "$ADDRESS" ] || bad "This host has no address on its way out to the network."
  if [ "$SAVED_HOW" = "dhcp" ]; then
    bad "The address is handed out by the router (DHCP) and can change. Set a fixed one here, or reserve $ADDRESS on the router."
  elif [ "$SAVED_HOW" = "static" ] && [ "${SAVED_ADDR%/*}" != "$ADDRESS" ]; then
    bad "The saved address (${SAVED_ADDR:-none}) isn't the one in use ($ADDRESS). A restart would change it."
  elif [ -z "$SAVED_HOW" ]; then
    bad "/etc/network/interfaces has nothing for $DEV, so the address won't survive a restart."
  fi
  if [ -n "$GATEWAY" ]; then
    ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1 || bad "The gateway $GATEWAY doesn't answer."
  else
    bad "There is no gateway: this host can't reach the internet."
  fi
  getent hosts "${HOUSE_DNS_PROBE:-deb.debian.org}" >/dev/null 2>&1 || bad "DNS doesn't resolve names (asked ${DNS:-nothing})."
  case "$NAME" in pve|proxmox|debian|localhost) bad "The name is still the installer's ($NAME). Pick the name this house's machine will keep.";; esac
  if [ -n "$HOSTS_ADDR" ] && [ "$HOSTS_ADDR" != "$ADDRESS" ]; then
    bad "/etc/hosts says $NAME is $HOSTS_ADDR, not $ADDRESS. Proxmox won't start its services after a restart."
  elif [ -z "$HOSTS_ADDR" ]; then
    bad "/etc/hosts has no line for $NAME. Proxmox needs one."
  fi
  if [ "$SAVED_HOW" = "static" ]; then
    note "One thing only your router can tell you: that $ADDRESS is outside the range it hands out, or reserved for this machine."
  fi
  [ "$PROBLEMS" -gt 0 ] || note "Saved, in use, and it survives a restart."
}

# The new settings written to the saved files, the old ones kept beside them. Applies nothing.
write_network() {   # name address bits gateway dns
  n="$1"; a="$2"; b="$3"; g="$4"; d="$5"
  keep="$UNDO/network-$(date +%Y%m%d-%H%M%S)"
  run mkdir -p "$keep"
  for f in /etc/network/interfaces /etc/hosts /etc/hostname /etc/resolv.conf; do [ -f "$ROOT$f" ] && run cp -p "$ROOT$f" "$keep/$(basename "$f")"; done
  note "The files as they were are in ${keep#"$ROOT"}"
  [ -n "$DRY" ] && { note "would write $n, $a/$b, gateway $g, DNS $d"; return 0; }
  mkdir -p "$STATE"; printf '%s\n' "$keep" > "$STATE/network-undo"
  # /etc/network/interfaces: this interface's stanza becomes static with the new address and gateway; every other line stays.
  awk -v d="$DEV" -v a="$a/$b" -v g="$g" '
    $1=="iface" { on=($2==d && $3=="inet"); if (on) { print "iface " d " inet static"; print "\taddress " a; print "\tgateway " g; next } }
    on && ($1=="address" || $1=="gateway" || $1=="netmask") { next }
    { print }' "$IFACES" > "$IFACES.house-new" && mv "$IFACES.house-new" "$IFACES"
  # /etc/hosts: one line for this machine, at its address.
  { grep -v -E "[[:space:]]($NAME|$n)([[:space:]]|\$)" "$ROOT/etc/hosts" 2>/dev/null | grep -v '^127\.0\.1\.1' || true; printf '%s %s\n' "$a" "$n"; } > "$ROOT/etc/hosts.house-new" && mv "$ROOT/etc/hosts.house-new" "$ROOT/etc/hosts"
  printf '%s\n' "$n" > "$ROOT/etc/hostname"
  { grep -v '^nameserver' "$ROOT/etc/resolv.conf" 2>/dev/null || true; for x in $d; do printf 'nameserver %s\n' "$x"; done; } > "$ROOT/etc/resolv.conf.house-new" && mv "$ROOT/etc/resolv.conf.house-new" "$ROOT/etc/resolv.conf"
}

# The script that puts the saved files back and applies them: what the timer runs, and what `undo` runs.
rollback_script() {
  keep="$(cat "$STATE/network-undo")"
  cat > "$STATE/rollback.sh" <<EOF
#!/bin/sh
cp -p "$keep/interfaces" "$IFACES"
cp -p "$keep/hosts" "$ROOT/etc/hosts"
cp -p "$keep/hostname" "$ROOT/etc/hostname"
cp -p "$keep/resolv.conf" "$ROOT/etc/resolv.conf"
hostname "\$(cat "$ROOT/etc/hostname")"
ifreload -a
rm -f "$STATE/network-pending"
EOF
  chmod 700 "$STATE/rollback.sh"
}

apply_network() {   # name
  rollback_script
  if [ -n "${SSH_CONNECTION:-}" ]; then
    # Over SSH this may cut the session. The old settings come back by themselves unless confirmed from the new address.
    : > "$STATE/network-pending"
    systemd-run --quiet --unit house-network-undo --on-active=120 sh "$STATE/rollback.sh"
    say ""
    warn "Applying now. This session may stop answering."
    warn "Sign in again at the new address within two minutes and run:   $(again confirm)"
    warn "If you don't, the old settings come back by themselves and you can sign in where you did before."
  fi
  hostname "$1"
  ifreload -a
  if [ -z "${SSH_CONNECTION:-}" ]; then note "Applied. To put the old settings back:   $(again undo)"; fi
}

confirm_network() {
  [ -f "$STATE/network-pending" ] || { say "Nothing is waiting to be confirmed."; return 0; }
  systemctl stop house-network-undo.timer 2>/dev/null || true
  rm -f "$STATE/network-pending"
  say "Confirmed. The new settings stay. To carry on:   $(again)"
}

network_step() {
  step "This host's network"
  read_network
  show_network
  say ""
  check_network
  [ -f "$STATE/network-pending" ] && die "A network change is waiting to be confirmed. Run:   $(again confirm)"
  choice="${HOUSE_NETWORK:-}"
  if [ -z "$choice" ]; then
    say ""
    if [ "$MODE" = "rebuild" ]; then
      note "A rebuild needs this machine to have the old one's name. Its name, address and gateway are on the recovery sheet."
    fi
    say "   1  Keep and Verify   leave it as it is"
    say "   2  Change Now        set the name, address, gateway and DNS"
    choice="$(ask "   Which" "$([ "$PROBLEMS" -gt 0 ] && echo 2 || echo 1)")"
  fi
  case "$choice" in
    1|keep)
      [ "$PROBLEMS" -eq 0 ] || warn "Kept, with what is listed above still true."
      ;;
    2|change)
      n="${HOUSE_NEW_NAME:-$(ask "   Name" "$NAME")}"
      a="${HOUSE_NEW_ADDRESS:-$(ask "   Address" "$ADDRESS")}"
      g="${HOUSE_NEW_GATEWAY:-$(ask "   Gateway" "$GATEWAY")}"
      d="${HOUSE_NEW_DNS:-$(ask "   DNS" "${DNS:-$GATEWAY}")}"
      is_name "$n" || die "A name is lowercase letters, numbers and hyphens, starting with a letter."
      is_ip "$a" || die "$a isn't an address."
      is_ip "$g" || die "$g isn't an address."
      if [ "$n" != "$NAME" ] && [ "${GUESTS:-0}" -gt 0 ]; then
        die "This host already has guests filed under $NAME. Renaming it now would lose track of them. Keep the name, or move the guests first."
      fi
      if [ "$n" = "$NAME" ] && [ "$a" = "$ADDRESS" ] && [ "$g" = "$GATEWAY" ] && [ "$d" = "$DNS" ] && [ "$SAVED_HOW" = "static" ] && [ "$HOSTS_ADDR" = "$ADDRESS" ]; then
        note "Nothing to change."
      else
        say ""
        say "   Name      $NAME  ->  $n"
        say "   Address   ${CIDR:-none}  ->  $a/${BITS:-24}"
        say "   Gateway   ${GATEWAY:-none}  ->  $g"
        say "   DNS       ${DNS:-none}  ->  $d"
        [ "$n" = "$NAME" ] || warn "A new name takes a restart of this machine to reach every Proxmox service. Restart it after this finishes."
        [ "$(ask "   Change it (yes or no)" "yes")" = "yes" ] || die "Nothing was changed."
        write_network "$n" "$a" "${BITS:-24}" "$g" "$d"
        [ -n "$DRY" ] || apply_network "$n"
        [ -n "$DRY" ] || [ -z "${SSH_CONNECTION:-}" ] || exit 0   # the rest waits for `confirm` from the new address
        [ -n "$DRY" ] || read_network
      fi
      ;;
    *) die "Answer 1 or 2." ;;
  esac
}

# ---------------------------------------------------------------- House's own container

find_house() {   # the ID of a container this script made before, if there is one
  [ -f "$STATE/ctid" ] && pct status "$(cat "$STATE/ctid")" >/dev/null 2>&1 && cat "$STATE/ctid" || true
}

free_address() {   # the first address after the host's that nothing answers at
  base="${ADDRESS%.*}"; last="${ADDRESS##*.}"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    try="$base.$((last + i))"
    [ $((last + i)) -lt 255 ] || break
    ping -c 1 -W 1 "$try" >/dev/null 2>&1 || { printf '%s' "$try"; return 0; }
  done
}

container_step() {
  step "House's own container"
  CTID="$(find_house)"
  if [ -n "$CTID" ]; then
    HOUSE_ADDR="$(cat "$STATE/address")"
    note "Already made: container $CTID at $HOUSE_ADDR"
    pct status "$CTID" | grep -q running || run pct start "$CTID"
    return 0
  fi
  storage="${HOUSE_STORAGE:-$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $6, $1}' | sort -rn | awk 'NR==1 {print $2}')}"
  [ -n "$storage" ] || die "No storage on this host takes containers' disks."
  tstore="$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')"
  [ -n "$tstore" ] || die "No storage on this host takes container templates."
  CTID="${HOUSE_CTID:-$(pvesh get /cluster/nextid)}"
  HOUSE_ADDR="${HOUSE_ADDRESS:-$(ask "   House's address" "$(free_address)")}"
  is_ip "$HOUSE_ADDR" || die "House needs an address of its own."
  ping -c 1 -W 1 "$HOUSE_ADDR" >/dev/null 2>&1 && die "$HOUSE_ADDR is already in use."
  note "Container $CTID, named house, at $HOUSE_ADDR, 1 core, 1 GB, 8 GB on $storage"
  tmpl="$(pveam list "$tstore" 2>/dev/null | awk -v o="$OS" '$1 ~ o {print $1}' | sort | tail -1)"
  if [ -z "$tmpl" ]; then
    run pveam update >/dev/null 2>&1 || true
    file="$(pveam available --section system 2>/dev/null | awk -v o="$OS" '$2 ~ "^" o {print $2}' | sort -V | tail -1)"
    [ -n "$file" ] || die "Proxmox doesn't offer a Debian 12 template. Check this host reaches the internet."
    [ -n "$DRY" ] || note "Downloading $file"
    run pveam download "$tstore" "$file" >/dev/null
    tmpl="$tstore:vztmpl/$file"
  fi
  run pct create "$CTID" "$tmpl" --hostname house --cores 1 --memory 1024 --swap 512 --rootfs "$storage:8" \
    --net0 "name=eth0,bridge=$DEV,ip=$HOUSE_ADDR/${BITS:-24},gw=$GATEWAY" --nameserver "${DNS%% *}" \
    --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 --startup order=1 --description "House. Made by its bootstrap." >/dev/null
  if [ -z "$DRY" ]; then mkdir -p "$STATE"; printf '%s\n' "$CTID" > "$STATE/ctid"; printf '%s\n' "$HOUSE_ADDR" > "$STATE/address"; fi
  run pct start "$CTID"
}

in_house() { pct exec "$CTID" -- sh -c "$1"; }

house_step() {
  step "House"
  [ -n "$IMAGE" ] || die "HOUSE_IMAGE is empty. Set it to House's image and run this again. Everything so far is kept."
  if [ -n "$DRY" ]; then note "would install Docker in container $CTID and start $IMAGE there, listening on $HOUSE_ADDR:$PORT"; return 0; fi
  # The container's network, before anything is downloaded into it.
  n=0; until in_house "getent hosts download.docker.com >/dev/null 2>&1"; do n=$((n + 1)); [ "$n" -lt 30 ] || die "House's container can't reach the internet. Check its address ($HOUSE_ADDR) and the gateway ($GATEWAY)."; sleep 2; done
  if ! in_house "command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1"; then
    note "Installing Docker"
    in_house "export DEBIAN_FRONTEND=noninteractive; apt-get update -q >/dev/null && apt-get install -y -q --no-install-recommends ca-certificates curl >/dev/null \
      && install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
      && echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$(. /etc/os-release; echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list \
      && apt-get update -q >/dev/null && apt-get install -y -q --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null" \
      || die "Docker couldn't be installed in House's container."
  fi
  # What House is told about how it began: read once, at its first start (bootstrapped.py).
  finger="$(openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  in_house "mkdir -p /opt/house/config /opt/house/store /opt/house/share && chown -R 1000:1000 /opt/house/config /opt/house/store /opt/house/share"
  if ! in_house "test -f /opt/house/config/bootstrap.json"; then
    in_house "cat > /opt/house/config/bootstrap.json && chown 1000:1000 /opt/house/config/bootstrap.json" <<EOF
{"mode": "$MODE", "proxmox": "https://$ADDRESS:8006", "fingerprint": "$finger", "role": "Administrator",
 "host": {"name": "$NAME", "address": "$ADDRESS/${BITS:-24}", "gateway": "$GATEWAY", "dns": "$DNS"}, "house": "$HOUSE_ADDR", "at": $(date +%s)}
EOF
  fi
  # House as a container that can do nothing but be House: not root, read-only, no capabilities, a memory ceiling.
  in_house "cat > /opt/house/docker-compose.yml" <<EOF
services:
  house:
    image: $IMAGE
    container_name: house
    network_mode: host
    environment:
      HOUSE_BIND: "$HOUSE_ADDR"
      HOUSE_PORT: "$PORT"
    volumes:
      - /opt/house/config:/home/house/.config/house
      - /opt/house/store:/home/house/house-store
      - /opt/house/share:/home/house/.local/share/house
    read_only: true
    tmpfs:
      - /tmp:size=64m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    mem_limit: 384m
    pids_limit: 1024
    logging:
      driver: json-file
      options:
        max-size: 5m
        max-file: '2'
    restart: unless-stopped
EOF
  note "Starting $IMAGE"
  in_house "cd /opt/house && docker compose pull -q && docker compose up -d" >/dev/null 2>&1 || die "House's image couldn't be started. Is $IMAGE one this machine may pull?"
  n=0; until in_house "curl -fsS -o /dev/null http://$HOUSE_ADDR:$PORT/"; do n=$((n + 1)); [ "$n" -lt 45 ] || die "House didn't answer at $HOUSE_ADDR:$PORT. Its log:   pct exec $CTID -- docker logs house"; sleep 2; done
  note "House answers at http://$HOUSE_ADDR:$PORT"
}

connect_step() {
  step "House connects to this Proxmox"
  if [ -n "$DRY" ]; then note "would let House's own SSH key in as root here, and wait for House to make its user and token"; return 0; fi
  if in_house "test -f /opt/house/config/bootstrap.done"; then note "Already connected"; return 0; fi
  n=0; until key="$(in_house "cat /opt/house/config/id_ed25519.pub 2>/dev/null")" && [ -n "$key" ]; do n=$((n + 1)); [ "$n" -lt 30 ] || die "House didn't make its key. Connect Proxmox from House instead (Settings, Connections)."; sleep 2; done
  mkdir -p "$ROOT/root/.ssh"; chmod 700 "$ROOT/root/.ssh"
  grep -qxF "$key" "$ROOT/root/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$key" >> "$ROOT/root/.ssh/authorized_keys"
  note "House's key is let in as root (its own line in /root/.ssh/authorized_keys; nothing of yours is changed)"
  n=0; until in_house "test -f /opt/house/config/bootstrap.done"; do
    n=$((n + 1))
    if [ "$n" -ge 60 ]; then warn "House hasn't finished connecting. Open it and connect Proxmox there (Settings, Connections): its key is already let in."; return 0; fi
    sleep 2
  done
  in_house "cat /opt/house/config/bootstrap.done" | sed 's/^/   /'
}

finish() {
  step "Done"
  if [ -n "$DRY" ]; then note "would print House's address and its setup code"; return 0; fi
  code="$(in_house "cat /opt/house/config/setup-code 2>/dev/null" || true)"
  say ""
  say "   Open   http://$HOUSE_ADDR:$PORT"
  [ -z "$code" ] || say "   Setup code   $code"
  say ""
  if [ "$MODE" = "rebuild" ]; then
    note "Next, in House: open the repository (a file, Drive, a bucket or Git) with the House key."
  else
    note "House shows its key once. Save it somewhere that isn't this machine."
  fi
}

# ---------------------------------------------------------------- the run

[ "$(id -u)" = 0 ] || die "Run this as root on the Proxmox host."
command -v pveversion >/dev/null 2>&1 || die "This isn't a Proxmox host. Run it on the machine Proxmox is installed on."

case "${1:-}" in
  confirm) confirm_network; exit 0 ;;
  undo) [ -f "$STATE/rollback.sh" ] || die "There is no network change to put back."; sh "$STATE/rollback.sh"; say "The old network settings are back."; exit 0 ;;
  "") ;;
  *) die "Unknown: $1. Run it with nothing, or with confirm or undo." ;;
esac

say "House, on $(pveversion | head -1 | cut -d/ -f1-2)"
MODE="${HOUSE_MODE:-}"
[ -n "$MODE" ] || [ ! -f "$STATE/mode" ] || MODE="$(cat "$STATE/mode")"
if [ -z "$MODE" ]; then
  say ""
  say "   1  New house        nothing to bring back"
  say "   2  Rebuilding one   you have a House repository and its key"
  case "$(ask "   Which" "1")" in 1|new) MODE=new ;; 2|rebuild) MODE=rebuild ;; *) die "Answer 1 or 2." ;; esac
fi
case "$MODE" in new|rebuild) ;; *) die "HOUSE_MODE is new or rebuild." ;; esac
if [ -z "$DRY" ]; then mkdir -p "$STATE"; printf '%s\n' "$MODE" > "$STATE/mode"; fi

network_step
container_step
house_step
connect_step
finish
