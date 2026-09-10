#!/bin/bash
# Destructive integration test: run only in disposable CI containers/VMs.
set -euo pipefail
[[ ${SS_RUST_TEST_ENV:-} == disposable && $EUID -eq 0 ]] || {
    echo 'This test requires root and SS_RUST_TEST_ENV=disposable.' >&2
    exit 1
}
[[ ! -e /etc/shadowsocks-rust && ! -e /usr/local/bin/ssserver ]] || {
    echo 'Refusing to replace an existing installation.' >&2
    exit 1
}
init=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
export SS_TEST_SCRATCH=$scratch
mkdir -p "$scratch/bin"

diagnostics() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        cat "$scratch"/*.log /var/log/ss-rust.log 2>/dev/null || true
        if [[ $init == systemd ]]; then
            /usr/bin/journalctl -u ss-rust --no-pager -n 60 || true
        fi
    fi
    exit "$code"
}
trap diagnostics EXIT

# Keep external IP lookup and release selection deterministic. Release archives
# are still downloaded from GitHub and executed on the native architecture.
cat > "$scratch/bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
    *ip.sb*|*ifconfig.me*|*ipinfo.io/ip*) printf '%s\n' '203.0.113.10' ;;
    *api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest*)
        printf '%s\n' '{"tag_name":"v1.25.0"}' ;;
    *) exec /usr/bin/curl "$@" ;;
esac
EOF
# Never change the CI host clock or TCP tuning. Record these calls so the
# chrony service integration can be asserted independently from clock changes.
for tool in chronyc timedatectl; do
    cat > "$scratch/bin/$tool" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$SS_TEST_SCRATCH/clock.log"
EOF
done
cat > "$scratch/bin/sysctl" <<'EOF'
#!/bin/sh
echo 'Unexpected sysctl call' >> "$SS_TEST_SCRATCH/sysctl.log"
exit 1
EOF

if [[ $init == openrc ]]; then
    # Docker already configures networking. Supply that fact to OpenRC without
    # trying to reconfigure the container's interfaces or starting a full boot.
    apk add --no-cache openrc
    mkdir -p /run/openrc
    touch /run/openrc/softlevel
    printf '%s\n' 'rc_sys="docker"' >> /etc/rc.conf
    cat > /etc/init.d/ci-net <<'EOF'
#!/sbin/openrc-run
depend() { provide net; }
start() { return 0; }
stop() { return 0; }
EOF
    chmod +x /etc/init.d/ci-net
    rc-update add ci-net default
    rc-service ci-net start
    cat > "$scratch/bin/rc-service" <<'EOF'
#!/bin/sh
if [ "$1" = chronyd ]; then
    printf 'rc-service %s\n' "$*" >> "$SS_TEST_SCRATCH/clock.log"
    exit 0
fi
exec /sbin/rc-service "$@"
EOF
else
    # Hosted runners may still report "starting" while unrelated boot jobs run.
    # Verify the real manager is reachable; service operations below are the gate.
    [[ -d /run/systemd/system ]]
    systemctl show --property=Version
    cat > "$scratch/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
    *chronyd*|*chrony*) printf 'systemctl %s\n' "$*" >> "$SS_TEST_SCRATCH/clock.log" ;;
    *) exec /usr/bin/systemctl "$@" ;;
esac
EOF
fi
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"

run_script() {
    # Respect systemd's normal start-rate limit when driving many CLI actions
    # back-to-back; keep the production restart protection enabled.
    if [[ $init == systemd ]]; then sleep 3; fi
    bash "$repo/ss-rust.sh" "$@"
}
active() {
    if [[ $init == openrc ]]; then
        rc-service ss-rust status
    else
        systemctl is-active --quiet ss-rust
    fi
}
wait_ports() { python3 "$repo/tests/ss-rust/verify.py" ports "$@"; }
verify() { python3 "$repo/tests/ss-rust/verify.py" config "$@"; }

# Exercise the full installer with both node types and explicitly decline BBR.
run_script install > "$scratch/install.log" 2>&1 <<'EOF'
3
22111

32111

n
EOF
active
wait_ports 22111 32111
verify 22111 32111
[[ ! -f "$scratch/sysctl.log" ]]
grep -q 'chronyc makestep' "$scratch/clock.log"
if [[ $init == openrc ]]; then
    [[ -L /etc/runlevels/default/ss-rust && -x /etc/init.d/chronyd ]]
    grep -q 'rc-service chronyd start' "$scratch/clock.log"
    [[ $(stat -c '%a' /var/log/ss-rust.log) == 600 ]]
else
    systemctl is-enabled --quiet ss-rust
    grep -q 'systemctl enable --now chronyd' "$scratch/clock.log"
fi
echo 'PASS: install, dual listeners, subscription round-trip, boot enablement, chrony routing, BBR opt-out'

run_script stop
if active; then echo 'Service remained active after stop' >&2; exit 1; fi
run_script start
wait_ports 22111 32111
run_script restart
wait_ports 22111 32111
run_script show > "$scratch/show.log"
grep -q 'active' "$scratch/show.log"
run_script logs > "$scratch/service.log"
[[ -s "$scratch/service.log" ]]
echo 'PASS: CLI stop, start, restart, show, logs'

# A process failure must be recovered by the actual service supervisor.
python3 "$repo/tests/ss-rust/verify.py" crash
sleep 7
active
wait_ports 22111 32111
echo 'PASS: automatic recovery after ssserver termination'

# Exercise the interactive menu, not just internal helper functions.
run_script > "$scratch/change-port.log" <<'EOF'
3
1
22112
EOF
wait_ports 22112 32111
verify 22112 32111
cp /etc/shadowsocks-rust/config.json "$scratch/before-reset.json"
run_script reset > "$scratch/reset.log"
wait_ports 22112 32111
verify 22112 32111
python3 "$repo/tests/ss-rust/verify.py" reset "$scratch/before-reset.json"
echo 'PASS: port change, restart, key reset, regenerated subscriptions'

# Reinstall while running, then verify both single-node options and cleanup.
for node in 1 2; do
    port=$((24000 + node))
    run_script install > "$scratch/reinstall-$node.log" 2>&1 <<EOF
$node
$port

n
EOF
    active
    wait_ports "$port"
    verify "$port"
    changed_port=$((port + 100))
    run_script > "$scratch/single-port-$node.log" <<EOF
3
$node
$changed_port
EOF
    wait_ports "$changed_port"
    verify "$changed_port"
done
run_script uninstall
[[ ! -e /etc/shadowsocks-rust && ! -e /usr/local/bin/ssserver ]]
[[ ! -e /usr/local/bin/sslocal ]]
if [[ $init == openrc ]]; then
    [[ ! -e /etc/init.d/ss-rust && ! -e /etc/runlevels/default/ss-rust ]]
    [[ ! -e /var/log/ss-rust.log ]]
else
    [[ ! -e /etc/systemd/system/ss-rust.service ]]
fi
python3 "$repo/tests/ss-rust/verify.py" stopped
echo "PASS: reinstall, each single-node mode, uninstall ($init / $(uname -m))"
