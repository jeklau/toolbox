#!/bin/sh
# Run only in disposable CI VMs/containers. Kernel calls below are simulated.
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

# Source the real functions without invoking the final main command.
[ "$(tail -n 1 "$script")" = main ]
sed '$d' "$script" > "$scratch/functions.sh"
# shellcheck source=/dev/null
. "$scratch/functions.sh"
detect_os
original_os=$OS
check_requirements
printf '%s\n' '# Preserve this unrelated setting' > /etc/sysctl.conf
cp /etc/sysctl.conf "$scratch/expected"

# Exercise thresholds and buffer clamps through the real memory function.
awk() { printf '%s\n' "$sim_mem"; }
for test_case in 32:micro:8 511:micro:63 512:small:64 1023:small:127 1024:medium:128 2048:large:256 4096:xlarge:256 65536:xlarge:256; do
    sim_mem=${test_case%%:*}
    remainder=${test_case#*:}
    expected_profile=${remainder%:*}
    expected_buffer=${remainder#*:}
    detect_memory > /dev/null
    [ "$PROFILE" = "$expected_profile" ]
    [ "$BUF_MB" = "$expected_buffer" ]
done
sim_mem=0
if (detect_memory) > "$scratch/zero.log" 2>&1; then exit 1; fi
sim_mem=128
echo 'PASS: 8 memory profiles/clamps and zero-memory rejection'

mode=builtin
sysctl() {
    case "$1" in
        -n)
            case "$2" in
                net.ipv4.tcp_available_congestion_control)
                    if [ "$mode" = missing ] || { [ "$mode" = openwrt ] && [ ! -f "$scratch/module" ]; }; then
                        echo 'reno cubic'
                    else
                        echo 'reno cubic bbr'
                    fi ;;
                net.ipv4.tcp_congestion_control) echo cubic ;;
                net.core.default_qdisc) echo fq ;;
                *) return 1 ;;
            esac ;;
        -w)
            [ "$mode" != denied ] || return 1
            printf '%s\n' "$*" >> "$scratch/writes"
            ;;
        -p) [ "$mode" != reload_fail ] ;;
        *) return 1 ;;
    esac
}
modprobe() { [ "$mode" = openwrt ] && [ -f "$scratch/module" ]; }
apk() {
    printf '%s\n' "$*" >> "$scratch/apk.log"
    case "$*" in *kmod-tcp-bbr*) touch "$scratch/module" ;; esac
}
enable_bbr > "$scratch/builtin.log"
grep -q '已就绪' "$scratch/builtin.log"
[ ! -f "$scratch/apk.log" ]
echo 'PASS: built-in BBR works even when modprobe fails'

# Preserve normal distro detection; override only the dependencies of main.
for mode in missing denied; do
    rm -f "$scratch/writes" "$scratch/apk.log"
    if (main) > "$scratch/$mode.log" 2>&1; then exit 1; fi
    cmp /etc/sysctl.conf "$scratch/expected"
    [ ! -f "$scratch/apk.log" ]
    [ ! -f "$scratch/writes" ]
    if grep -q '配置完成' "$scratch/$mode.log"; then exit 1; fi
done
echo 'PASS: unavailable BBR and denied writes fail before changing persistent configuration'

for mode in reload_fail mismatch; do
    cp "$scratch/expected" /etc/sysctl.conf
    if (main) > "$scratch/$mode.log" 2>&1; then exit 1; fi
    if grep -q '配置完成' "$scratch/$mode.log"; then exit 1; fi
done
echo 'PASS: reload failure and verification mismatch cannot report success'

# OpenWrt's apk package remains separate from Alpine's native kernel modules.
OS=openwrt
mode=openwrt
rm -f "$scratch/module" "$scratch/apk.log"
enable_bbr > "$scratch/openwrt.log"
grep -q 'add kmod-tcp-bbr' "$scratch/apk.log"
OS=$original_os
echo 'PASS: OpenWrt apk fallback remains available'
