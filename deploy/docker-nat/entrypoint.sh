#!/bin/sh
# Usage: preflight | baseline [seconds] | accept-baseline | try [seconds] | service | status | repair-arp | shell
set -eu
APP=/opt/portal-relay-pi4
PY="$APP/.venv/bin/python"
CFG=/etc/portal-relay-pi4/config.json
RT=/run/portal-linux-native
ST=/var/lib/portal-linux-native
PROFILE=${PORTAL_PROFILE:-100}
common="--config $CFG --runtime $RT --state-dir $ST"

# Receive offloads must be off on the relay NIC (this container's macvlan only).
for f in gro lro rx-gro-list; do ethtool -K eth0 "$f" off >/dev/null 2>&1 || true; done
mkdir -p "$RT" "$ST"
chmod 0700 "$RT" "$ST"

# Run in background so TERM/INT are forwarded, then wait for the guardian's ARP/nft repair.
relay() {
    "$PY" -u "$APP/linux_native.py" "$@" $common &
    pid=$!
    trap 'kill -TERM "$pid" 2>/dev/null || true' INT TERM
    rc=0
    while :; do
        if wait "$pid"; then rc=0; else rc=$?; fi
        kill -0 "$pid" 2>/dev/null || break
    done
    trap - INT TERM
    i=0
    while pgrep -f "linux_native.py guardian" >/dev/null 2>&1 && [ "$i" -lt 40 ]; do
        sleep 1
        i=$((i + 1))
    done
    return "$rc"
}

case "${1:-service}" in
    preflight) exec "$PY" "$APP/linux_native.py" preflight $common ;;
    baseline) relay baseline --seconds "${2:-180}" ;;
    accept-baseline)
        exec "$PY" "$APP/linux_native.py" accept-baseline $common \
            --assert-physical-ok "${2:-Verified clean Portal picture and controls on eth0 during baseline and clean restoration.}" ;;
    try) relay active --profile "$PROFILE" --seconds "${2:-300}" ;;
    service)
        rm -f "$RT/disabled"
        relay active --profile "$PROFILE" --continuous ;;
    status) exec "$PY" "$APP/linux_native.py" status --runtime "$RT" --state-dir "$ST" ;;
    repair-arp) exec "$PY" /opt/repair_arp.py ;;
    shell) exec sh ;;
    *) echo "unknown command: $1" >&2; exit 2 ;;
esac
