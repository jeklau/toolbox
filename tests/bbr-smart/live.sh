#!/bin/sh
# These writes affect the CI kernel. Never run this on a shared/production host.
set -eu
[ "${BBR_TEST_DISPOSABLE:-}" = 1 ] && [ "$(id -u)" -eq 0 ] || exit 1
script=$(pwd)/bbr-smart.sh
scratch=$(mktemp -d)
if [ -f /etc/sysctl.conf ]; then
    cp /etc/sysctl.conf "$scratch/original"
fi
restore() {
    if [ -f "$scratch/original" ]; then
        cp "$scratch/original" /etc/sysctl.conf
    else
        rm -f /etc/sysctl.conf
    fi
}
trap restore EXIT

printf '%s\n' '# unrelated setting retained by BBR Smart' \
    'net.ipv4.tcp_keepalive_time=7200' \
    '# === BBR Blast Smooth v2.2 (Profile: old) ===' \
    'net.ipv4.tcp_fin_timeout=60' '# === END BBR ===' > /etc/sysctl.conf
cp /etc/sysctl.conf "$scratch/before"
before_count=$(find /etc -maxdepth 1 -name 'sysctl.conf.bak.*' | wc -l)
sh "$script"
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ]
[ "$(sysctl -n net.core.default_qdisc)" = fq ]
[ "$(sysctl -n net.ipv4.tcp_fin_timeout)" = 8 ]
grep -q '^net.ipv4.tcp_keepalive_time=7200$' /etc/sysctl.conf
[ "$(grep -c '^# === BBR Blast Smooth' /etc/sysctl.conf)" = 1 ]
if grep -q 'Profile: old' /etc/sysctl.conf; then exit 1; fi
echo "PASS: actual BBR/fq kernel values, tuning parameters and v2.2 migration ($(uname -m))"

# Re-running must keep one managed block and retain the original backup.
sh "$script"
after_count=$(find /etc -maxdepth 1 -name 'sysctl.conf.bak.*' | wc -l)
[ "$after_count" -eq "$((before_count + 2))" ]
[ "$(grep -c '^# === BBR Blast Smooth' /etc/sysctl.conf)" = 1 ]
found_backup=0
for backup in /etc/sysctl.conf.bak.*; do
    if cmp -s "$backup" "$scratch/before"; then found_backup=1; fi
done
[ "$found_backup" -eq 1 ]
grep -q '^tcp_bbr$' /etc/modules-load.d/bbr.conf
grep -q '^sch_fq$' /etc/modules-load.d/bbr.conf
echo 'PASS: repeat execution, unrelated configuration preserved, unique backups, module persistence'

if [ -f /etc/alpine-release ]; then
    [ -L /etc/runlevels/boot/modules ]
    [ -L /etc/runlevels/boot/sysctl ]
    # Check the installed OpenRC loader consumes our files, using real sysctl.
    mkdir -p /run/openrc
    touch /run/openrc/softlevel
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null
    rc-service sysctl restart
    [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ]
    echo 'PASS: OpenRC boot registration and actual sysctl service reload'
fi
