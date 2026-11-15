#!/bin/sh
# Run only in disposable CI VMs/containers. Kernel calls below are simulated.
set -eu
[ "${BBR_TEST_DISPOSABLE:-}" = 1 ] && [ "$(id -u)" -eq 0 ] || exit 1
script=$(pwd)/bbr-smart.sh
scratch=$(mktemp -d)
if [ -f /etc/sysctl.conf ]; then
    cp /etc/sysctl.conf "$scratch/original"
fi
snapshot_file() {
    dest=$1
    tag=$2
    if [ -e "$dest" ]; then
        cp -a "$dest" "$scratch/snap-$tag"
    else
        : > "$scratch/snap-$tag.missing"
    fi
}

restore_file() {
    dest=$1
    tag=$2
    if [ -e "$scratch/snap-$tag" ]; then
        rm -f "$dest"
        cp -a "$scratch/snap-$tag" "$dest"
    elif [ -f "$scratch/snap-$tag.missing" ]; then
        rm -f "$dest"
    fi
}

restore() {
    if [ -f "$scratch/original" ]; then
        cp "$scratch/original" /etc/sysctl.conf
    else
        rm -f /etc/sysctl.conf
    fi
    restore_file /etc/modules-load.d/bbr.conf modulesload
    restore_file /etc/modules.d/bbr modulesd
    restore_file /etc/init.d/sysctl initsysctl
    restore_file /etc/sysctl.d/11-nf-conntrack.conf nfct
    if [ -f "$scratch/modules-d.missing" ]; then
        rmdir /etc/modules.d 2>/dev/null || true
    fi
    if [ -f "$scratch/backups.before" ]; then
        for bak in /etc/sysctl.conf.bak.*; do
            [ -f "$bak" ] || continue
            if ! grep -Fxq "$bak" "$scratch/backups.before"; then
                rm -f "$bak"
            fi
        done
    fi
}
trap restore EXIT
find /etc -maxdepth 1 -name 'sysctl.conf.bak.*' > "$scratch/backups.before"
snapshot_file /etc/modules-load.d/bbr.conf modulesload
snapshot_file /etc/modules.d/bbr modulesd
snapshot_file /etc/init.d/sysctl initsysctl
snapshot_file /etc/sysctl.d/11-nf-conntrack.conf nfct
if [ ! -d /etc/modules.d ]; then
    : > "$scratch/modules-d.missing"
fi

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
fq_ok=1
codel_ok=1
cc_now=cubic
qdisc_now=fq
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
                net.ipv4.tcp_congestion_control)
                    if [ "$mode" = mismatch ]; then echo cubic; else echo "$cc_now"; fi ;;
                net.core.default_qdisc)
                    if [ "$mode" = mismatch ]; then echo fq; else echo "$qdisc_now"; fi ;;
                *) return 1 ;;
            esac ;;
        -w)
            [ "$mode" != denied ] || return 1
            pair=$2
            failed=0
            case "$pair" in
                net.core.default_qdisc=fq)
                    [ "$fq_ok" = 1 ] || failed=1 ;;
                net.core.default_qdisc=fq_codel)
                    [ "$codel_ok" = 1 ] || failed=1 ;;
            esac
            if [ "$mode" = reload_fail ]; then
                case "$pair" in
                    net.ipv4.tcp_congestion_control=bbr|net.core.rmem_max=*|net.core.wmem_max=*|net.ipv4.tcp_rmem=*|net.ipv4.tcp_wmem=*|net.ipv4.tcp_fin_timeout=*|net.ipv4.tcp_tw_reuse=*|net.ipv4.tcp_window_scaling=*|net.ipv4.tcp_timestamps=*|net.ipv4.tcp_sack=*|net.ipv4.tcp_no_metrics_save=*)
                        failed=1 ;;
                esac
            fi
            if [ "$failed" -eq 1 ]; then
                printf '%s\n' "FAIL argc=$# $pair" >> "$scratch/writes"
                return 1
            fi
            printf '%s\n' "ok argc=$# $pair" >> "$scratch/writes"
            case "$pair" in
                net.ipv4.tcp_congestion_control=*) cc_now=${pair#net.ipv4.tcp_congestion_control=} ;;
                net.core.default_qdisc=*) qdisc_now=${pair#net.core.default_qdisc=} ;;
            esac
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
    [ ! -f "$scratch/writes" ]
    if grep -q '配置完成' "$scratch/$mode.log"; then exit 1; fi
    if [ "$OS" = openwrt ] && [ "$mode" = missing ]; then
        grep -q 'add kmod-tcp-bbr' "$scratch/apk.log"
    else
        [ ! -f "$scratch/apk.log" ]
    fi
done
echo 'PASS: unavailable BBR and denied writes fail before changing persistent configuration'

cp "$scratch/expected" /etc/sysctl.conf
rm -f "$scratch/writes"
mode=reload_fail
fq_ok=1
codel_ok=1
cc_now=cubic
qdisc_now=fq
if (main) > "$scratch/reload_fail.log" 2>&1; then exit 1; fi
if grep -q '配置完成' "$scratch/reload_fail.log"; then exit 1; fi
grep -q 'FAIL argc=2 net.ipv4.tcp_congestion_control=bbr' "$scratch/writes"
grep -q 'FAIL argc=2 net.core.rmem_max=' "$scratch/writes"
grep -q 'FAIL argc=2 net.ipv4.tcp_fin_timeout=8' "$scratch/writes"
grep -q '以下参数未生效' "$scratch/reload_fail.log"
grep -q '重载 sysctl 失败' "$scratch/reload_fail.log"
echo 'PASS: reload keeps applying later keys and summarizes failures'

cp "$scratch/expected" /etc/sysctl.conf
mode=mismatch
fq_ok=1
codel_ok=1
cc_now=cubic
qdisc_now=fq
if (main) > "$scratch/mismatch.log" 2>&1; then exit 1; fi
if grep -q '配置完成' "$scratch/mismatch.log"; then exit 1; fi
grep -q '参数未生效' "$scratch/mismatch.log"
echo 'PASS: reload failure and verification mismatch cannot report success'

# fq is usable: persist sch_fq on the systemd/OpenRC path and keep unrelated lines.
rm -f "$scratch/writes" "$scratch/apk.log" /etc/modules-load.d/bbr.conf /etc/modules.d/bbr
cp "$scratch/expected" /etc/sysctl.conf
mode=builtin
fq_ok=1
codel_ok=1
cc_now=cubic
qdisc_now=fq
main > "$scratch/success.log" 2>&1
grep -q '配置完成' "$scratch/success.log"
grep -q '^排队规则: fq$' "$scratch/success.log"
if grep -q '改用 fq_codel' "$scratch/success.log"; then exit 1; fi
grep -q '^# Preserve this unrelated setting$' /etc/sysctl.conf
grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf
grep -q '^net.ipv4.tcp_rmem=4096 87380 16777216$' /etc/sysctl.conf
[ "$(grep -c '^# === BBR Blast Smooth' /etc/sysctl.conf)" = 1 ]
grep -q 'ok argc=2 net.ipv4.tcp_rmem=4096 87380 16777216' "$scratch/writes"
grep -q 'ok argc=2 net.ipv4.tcp_fin_timeout=8' "$scratch/writes"
if [ "$OS" = openwrt ]; then
    grep -q '^tcp_bbr$' /etc/modules.d/bbr
    grep -q '^sch_fq$' /etc/modules.d/bbr
    [ ! -f /etc/modules-load.d/bbr.conf ]
else
    grep -q '^tcp_bbr$' /etc/modules-load.d/bbr.conf
    grep -q '^sch_fq$' /etc/modules-load.d/bbr.conf
    [ ! -f /etc/modules.d/bbr ]
fi
echo 'PASS: fq success writes every owned key and the matching module list'

# OpenWrt without sch_fq: fall back, skip a missing key, ignore a failing stock reload.
(
    mode=builtin
    fq_ok=0
    codel_ok=1
    cc_now=cubic
    qdisc_now=fq_codel
    detect_os() {
        OS=openwrt
        DISPLAY_OS="ImmortalWrt 25.12.2"
        export OS DISPLAY_OS
    }
    sysctl_key_present() {
        [ "$1" != "net.ipv4.tcp_tw_reuse" ]
    }
    rm -f "$scratch/writes" "$scratch/apk.log" "$scratch/init.log"
    rm -f /etc/modules-load.d/bbr.conf /etc/modules.d/bbr
    cp "$scratch/expected" /etc/sysctl.conf
    mkdir -p /etc/init.d /etc/sysctl.d
    cat > /etc/init.d/sysctl << EOF
#!/bin/sh
echo invoked >> "$scratch/init.log"
exit 1
EOF
    chmod +x /etc/init.d/sysctl
    printf '%s\n' 'net.netfilter.nf_conntrack_helper=1' > /etc/sysctl.d/11-nf-conntrack.conf
    main > "$scratch/fallback.log" 2>&1
    grep -q '改用 fq_codel' "$scratch/fallback.log"
    grep -q 'kmod-sched' "$scratch/fallback.log"
    grep -q '已忽略无关存量配置' "$scratch/fallback.log"
    grep -q '跳过内核不存在的参数: net.ipv4.tcp_tw_reuse' "$scratch/fallback.log"
    grep -q '配置完成' "$scratch/fallback.log"
    grep -q '^排队规则: fq_codel$' "$scratch/fallback.log"
    grep -q '^net.core.default_qdisc=fq_codel$' /etc/sysctl.conf
    if grep -q 'tcp_tw_reuse' /etc/sysctl.conf; then exit 1; fi
    grep -q '^net.ipv4.tcp_timestamps=1$' /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_fin_timeout=8$' /etc/sysctl.conf
    if grep -q 'nf_conntrack_helper' "$scratch/writes"; then exit 1; fi
    if grep -q 'tcp_tw_reuse' "$scratch/writes"; then exit 1; fi
    grep -q 'ok argc=2 net.ipv4.tcp_timestamps=1' "$scratch/writes"
    grep -q '^tcp_bbr$' /etc/modules.d/bbr
    if grep -q 'sch_fq' /etc/modules.d/bbr; then exit 1; fi
    [ ! -f /etc/modules-load.d/bbr.conf ]
    grep -q invoked "$scratch/init.log"
)
echo 'PASS: OpenWrt falls back to fq_codel, skips missing keys, ignores stock sysctl errors'

(
    mode=builtin
    fq_ok=0
    codel_ok=0
    cc_now=cubic
    qdisc_now=pfifo_fast
    detect_os() {
        OS=openwrt
        DISPLAY_OS="ImmortalWrt test"
        export OS DISPLAY_OS
    }
    rm -f "$scratch/writes" /etc/modules.d/bbr /etc/modules-load.d/bbr.conf
    cp "$scratch/expected" /etc/sysctl.conf
    main > "$scratch/keep.log" 2>&1
    grep -q '保留当前排队规则: pfifo_fast' "$scratch/keep.log"
    grep -q '配置完成' "$scratch/keep.log"
    grep -q '^net.core.default_qdisc=pfifo_fast$' /etc/sysctl.conf
    grep -q '^tcp_bbr$' /etc/modules.d/bbr
    if grep -q 'sch_fq' /etc/modules.d/bbr; then exit 1; fi
    [ ! -f /etc/modules-load.d/bbr.conf ]
)
echo 'PASS: unusable fq and fq_codel keep the current qdisc'

(
    mode=builtin
    fq_ok=0
    codel_ok=0
    cc_now=cubic
    qdisc_now=fq
    cp "$scratch/expected" /etc/sysctl.conf
    if (main) > "$scratch/noqdisc.log" 2>&1; then exit 1; fi
    cmp /etc/sysctl.conf "$scratch/expected"
    if grep -q '配置完成' "$scratch/noqdisc.log"; then exit 1; fi
    grep -q '无法选择可用的排队规则' "$scratch/noqdisc.log"
)
echo 'PASS: no writable qdisc fails before changing persistent configuration'

# OpenWrt's apk package remains separate from Alpine's native kernel modules.
OS=openwrt
mode=openwrt
rm -f "$scratch/module" "$scratch/apk.log"
enable_bbr > "$scratch/openwrt.log"
grep -q 'add kmod-tcp-bbr' "$scratch/apk.log"
OS=$original_os
echo 'PASS: OpenWrt apk fallback remains available'
