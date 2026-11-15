#!/bin/sh
# BBR Blast Smooth v2.4 - 自动识别系统/内存智能调优版
# 支持 Alpine Linux (BusyBox/OpenRC), Debian 11-13, Ubuntu 20.04-24.04,
# iStoreOS, OpenWrt, ImmortalWrt；无需 Bash
# 适配 OpenWrt 25.12+ 的 apk 包管理器及经典 opkg。
# 无 sch_fq 时回退 fq_codel，并只逐条写入本脚本的 sysctl。

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

printf '%b\n' "${BLUE}========================================${NC}"
printf '%b\n' "${BLUE}   BBR Blast Smooth v2.4 智能调优版${NC}"
printf '%b\n' "${BLUE}========================================${NC}"
echo ""

error() {
    printf '%b\n' "${RED}❌ $1${NC}" >&2
    exit 1
}

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')
        VER=${VERSION_ID:-"unknown"}
        REAL_NAME=${NAME:-$ID}
        
        # 兼容处理基于 OpenWrt 的衍生系统
        case $(printf '%s %s' "$OS" "$REAL_NAME" | tr '[:upper:]' '[:lower:]') in
        *istoreos*|*openwrt*|*immortalwrt*)
            OS="openwrt"
            DISPLAY_OS="$REAL_NAME ($VER)"
            ;;
        *)
            DISPLAY_OS="$ID $VER"
            ;;
        esac
    else
        printf '%b\n' "${RED}❌ 无法识别系统${NC}"
        exit 1
    fi
    
    case "$OS" in
        alpine|debian|ubuntu)
            printf '%b\n' "${GREEN}✓ 检测到 $DISPLAY_OS${NC}"
            ;;
        openwrt)
            printf '%b\n' "${GREEN}✓ 检测到 OpenWrt 系分支: $DISPLAY_OS${NC}"
            ;;
        *)
            printf '%b\n' "${RED}❌ 不支持的系统: $OS${NC}"
            exit 1
            ;;
    esac
}

check_requirements() {
    [ "$(id -u)" -eq 0 ] || error "请使用 root 用户运行"
    for tool in awk grep sed cp mktemp sysctl; do
        command -v "$tool" >/dev/null 2>&1 || error "缺少命令: $tool"
    done
    if [ "$OS" = alpine ]; then
        command -v rc-update >/dev/null 2>&1 &&
            [ -x /etc/init.d/modules ] && [ -x /etc/init.d/sysctl ] ||
            error "Alpine 需要 OpenRC 持久化配置，请先运行 apk add openrc"
    fi
}

# 检测内存并设置参数
detect_memory() {
    # 兼容 BusyBox，改用更底层的 /proc/meminfo
    TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    if [ -z "$TOTAL_MEM" ] || [ "$TOTAL_MEM" -eq 0 ]; then
        printf '%b\n' "${RED}❌ 无法读取系统内存信息${NC}"
        exit 1
    fi
    
    printf '%b\n' "${GREEN}✓ 检测到内存: ${TOTAL_MEM}MB${NC}"

    # 缓冲区 = 内存的 1/8，最小 8MB，最大 256MB
    BUF_MB=$(( TOTAL_MEM / 8 ))
    [ "$BUF_MB" -lt 8 ]   && BUF_MB=8
    [ "$BUF_MB" -gt 256 ] && BUF_MB=256
    BUF_BYTES=$(( BUF_MB * 1024 * 1024 ))

    if [ "$TOTAL_MEM" -lt 512 ]; then
        PROFILE="micro"
        printf '%b\n' "${YELLOW}→ 使用 Micro 配置 (极小内存优化)${NC}"
    elif [ "$TOTAL_MEM" -lt 1024 ]; then
        PROFILE="small"
        printf '%b\n' "${YELLOW}→ 使用 Small 配置 (小内存优化)${NC}"
    elif [ "$TOTAL_MEM" -lt 2048 ]; then
        PROFILE="medium"
        printf '%b\n' "${YELLOW}→ 使用 Medium 配置 (中等内存)${NC}"
    elif [ "$TOTAL_MEM" -lt 4096 ]; then
        PROFILE="large"
        printf '%b\n' "${YELLOW}→ 使用 Large 配置 (大内存)${NC}"
    else
        PROFILE="xlarge"
        printf '%b\n' "${YELLOW}→ 使用 XLarge 配置 (超大内存)${NC}"
    fi

    RMEM_MAX=$BUF_BYTES
    WMEM_MAX=$BUF_BYTES
    TCP_RMEM="4096 87380 $BUF_BYTES"
    TCP_WMEM="4096 65536 $BUF_BYTES"
    printf '%b\n' "${YELLOW}→ 动态计算缓冲区上限: ${BUF_MB}MB${NC}"
}

# 启用 BBR (重点优化 apk/opkg 智能检测)
enable_bbr() {
    echo ""
    printf '%b\n' "${BLUE}==> 启用 BBR 内核模块${NC}"
    
    if [ "$OS" = "openwrt" ]; then
        # OpenWrt 系需要确认 kmod-tcp-bbr 模块
        if ! bbr_available && ! modprobe tcp_bbr 2>/dev/null; then
            printf '%b\n' "${YELLOW}→ 未检测到 tcp_bbr 模块，准备尝试通过包管理器安装...${NC}"
            
            # 智能探测包管理器：优先检测 apk (新版 OpenWrt)，回退检测 opkg
            if command -v apk >/dev/null 2>&1; then
                printf '%b\n' "${GREEN}✓ 检测到 apk 包管理器 (OpenWrt 25.12+)${NC}"
                apk update >/dev/null 2>&1 && apk add kmod-tcp-bbr >/dev/null 2>&1 || true
            elif command -v opkg >/dev/null 2>&1; then
                printf '%b\n' "${GREEN}✓ 检测到 opkg 包管理器 (经典版本)${NC}"
                opkg update >/dev/null 2>&1 && opkg install kmod-tcp-bbr >/dev/null 2>&1 || true
            else
                printf '%b\n' "${RED}❌ 未找到 apk 或 opkg，无法自动安装模块。${NC}"
            fi

            # 再次尝试加载
            modprobe tcp_bbr 2>/dev/null || { printf '%b\n' "${RED}❌ 无法加载 tcp_bbr，请确认您的固件内核是否编译了 BBR 支持。${NC}"; exit 1; }
        fi
        
    else
        # Alpine 使用其当前内核自带的模块；kmod-tcp-bbr 是 OpenWrt 包名。
        modprobe tcp_bbr 2>/dev/null || true
    fi
    bbr_available || error "当前内核不提供 BBR；请检查 tcp_bbr 模块或宿主机内核支持"

    # 先确认拥塞控制可写，避免受限环境先落盘再失败。
    # 不能靠“把当前 default_qdisc 原样写回”判断 fq 是否可用。
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control) || error "内核不提供参数: net.ipv4.tcp_congestion_control"
    sysctl -w "net.ipv4.tcp_congestion_control=$current_cc" >/dev/null || error "无法修改 net.ipv4.tcp_congestion_control；请检查容器或宿主机权限"
    sysctl -n net.core.default_qdisc >/dev/null || error "内核不提供参数: net.core.default_qdisc"

    CHOSEN_QDISC=$(select_qdisc) || error "无法选择可用的排队规则（fq、fq_codel 和当前值都无法写入）"
    case "$CHOSEN_QDISC" in
        fq) ;;
        fq_codel)
            printf '%b\n' "${YELLOW}→ 当前内核无法使用 fq（sch_fq 不可用），改用 fq_codel${NC}"
            if [ "$OS" = openwrt ]; then
                printf '%b\n' "${YELLOW}→ 需要 fq 时可安装 kmod-sched（OpenWrt/ImmortalWrt 源码 package/kernel/linux/modules/netsupport.mk 中该包包含 sch_fq.ko）；软件源没有该包时请先确认${NC}"
            fi
            ;;
        *)
            printf '%b\n' "${YELLOW}→ fq 与 fq_codel 都不可用，保留当前排队规则: ${CHOSEN_QDISC}${NC}"
            ;;
    esac
    printf '%b\n' "${GREEN}✓ BBR 内核模块已就绪 (排队规则: $CHOSEN_QDISC)${NC}"
}

bbr_available() {
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) || return 1
    case " $available " in
        *" bbr "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 试写排队规则后立刻恢复，避免探测本身留下半成品。
qdisc_usable() {
    probe_qdisc=$1
    case "$probe_qdisc" in
        fq) modprobe sch_fq >/dev/null 2>&1 || true ;;
        fq_codel) modprobe sch_fq_codel >/dev/null 2>&1 || true ;;
    esac
    saved_qdisc=$(sysctl -n net.core.default_qdisc) || return 1
    if sysctl -w "net.core.default_qdisc=$probe_qdisc" >/dev/null 2>&1; then
        if [ "$saved_qdisc" != "$probe_qdisc" ]; then
            sysctl -w "net.core.default_qdisc=$saved_qdisc" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    return 1
}

# 只把最终选定的名字打到标准输出。提示由调用方打印，避免被命令替换吃掉。
select_qdisc() {
    original_qdisc=$(sysctl -n net.core.default_qdisc) || return 1
    if qdisc_usable fq; then
        printf '%s\n' fq
        return 0
    fi
    if qdisc_usable fq_codel; then
        printf '%s\n' fq_codel
        return 0
    fi
    if [ "$original_qdisc" != fq ] && [ "$original_qdisc" != fq_codel ] && qdisc_usable "$original_qdisc"; then
        printf '%s\n' "$original_qdisc"
        return 0
    fi
    return 1
}

persist_modules() {
    if [ "$OS" = openwrt ]; then
        module_dir=/etc/modules.d
        module_file=bbr
    else
        module_dir=/etc/modules-load.d
        module_file=bbr.conf
    fi
    mkdir -p "$module_dir"
    {
        printf '%s\n' tcp_bbr
        if [ "$CHOSEN_QDISC" = fq ]; then
            printf '%s\n' sch_fq
        fi
    } > "$module_dir/$module_file"
    if [ "$OS" = alpine ]; then
        rc-update add modules boot || error "无法注册 OpenRC modules 开机服务"
        rc-update add sysctl boot || error "无法注册 OpenRC sysctl 开机服务"
    fi
}

# 备份原配置
backup_config() {
    if [ -f /etc/sysctl.conf ]; then
        BACKUP_FILE=$(mktemp /etc/sysctl.conf.bak.XXXXXX)
        cp /etc/sysctl.conf "$BACKUP_FILE"
        printf '%b\n' "${GREEN}✓ 已备份原内核参数配置到 $BACKUP_FILE${NC}"
    fi
}

sysctl_key_present() {
    sysctl_path=$(printf '%s' "$1" | tr '.' '/') || return 1
    [ -e "/proc/sys/$sysctl_path" ]
}

bbr_sysctl_lines() {
    printf '%s\n' \
        "net.core.default_qdisc=$CHOSEN_QDISC" \
        "net.ipv4.tcp_congestion_control=bbr" \
        "" \
        "net.core.rmem_max=$RMEM_MAX" \
        "net.core.wmem_max=$WMEM_MAX" \
        "net.ipv4.tcp_rmem=$TCP_RMEM" \
        "net.ipv4.tcp_wmem=$TCP_WMEM" \
        "" \
        "net.ipv4.tcp_fin_timeout=8" \
        "net.ipv4.tcp_tw_reuse=1" \
        "net.ipv4.tcp_window_scaling=1" \
        "net.ipv4.tcp_timestamps=1" \
        "net.ipv4.tcp_sack=1" \
        "net.ipv4.tcp_no_metrics_save=1"
}

# 写入优化参数
apply_config() {
    echo ""
    printf '%b\n' "${BLUE}==> 写入内核优化参数 (Profile: $PROFILE)${NC}"
    [ -n "$CHOSEN_QDISC" ] || error "未选择排队规则"

    # 幂等性：移除旧的 BBR 配置
    sed -i '/# === BBR Blast Smooth/,/# === END BBR/d' /etc/sysctl.conf 2>/dev/null || true

    {
        cat <<SYSCTL

# === BBR Blast Smooth v2.4 (Profile: $PROFILE) ===
# 系统: $DISPLAY_OS | 内存: ${TOTAL_MEM}MB | 缓冲: ${BUF_MB}MB
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

SYSCTL
        bbr_sysctl_lines | {
            skipped=
            while IFS= read -r line; do
                case "$line" in
                    "")
                        printf '\n'
                        continue
                        ;;
                esac
                key=${line%%=*}
                if sysctl_key_present "$key"; then
                    printf '%s\n' "$line"
                else
                    skipped="${skipped:+$skipped }$key"
                fi
            done
            if [ -n "$skipped" ]; then
                printf '%b\n' "${YELLOW}→ 跳过内核不存在的参数: ${skipped}${NC}" >&2
            fi
        }
        printf '%s\n' "# === END BBR ==="
    } >> /etc/sysctl.conf

    printf '%b\n' "${GREEN}✓ 优化参数已写入系统配置${NC}"
}

# 只应用本脚本区块。某一项失败不中断后续项；存量 sysctl.d 的错误不算本脚本失败。
apply_own_sysctl() {
    in_block=0
    applied=0
    failures=
    while IFS= read -r line || [ -n "${line-}" ]; do
        case "$line" in
            '# === BBR Blast Smooth'*)
                in_block=1
                continue
                ;;
            '# === END BBR'*)
                in_block=0
                continue
                ;;
        esac
        [ "$in_block" -eq 1 ] || continue
        case "$line" in
            ''|'#'*) continue ;;
            *=*) ;;
            *) continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        if ! sysctl_key_present "$key"; then
            printf '%b\n' "${YELLOW}→ 跳过内核不存在的参数: ${key}${NC}"
            continue
        fi
        if sysctl -w "$key=$value" >/dev/null 2>&1; then
            applied=$((applied + 1))
        else
            failures="${failures:+$failures }$key"
            printf '%b\n' "${YELLOW}→ 写入失败，继续后续参数: ${key}${NC}"
        fi
    done < /etc/sysctl.conf

    if [ -n "$failures" ]; then
        printf '%b\n' "${RED}❌ 以下参数未生效: ${failures}${NC}" >&2
        return 1
    fi
    [ "$applied" -gt 0 ]
}

# 应用配置
reload_config() {
    echo ""
    printf '%b\n' "${BLUE}==> 重载系统配置${NC}"

    # OpenWrt 的 init 会顺带加载 /etc/sysctl.d。那里的过期键不能决定本脚本成败。
    if [ "$OS" = openwrt ] && [ -x /etc/init.d/sysctl ]; then
        if ! /etc/init.d/sysctl restart >/dev/null 2>&1; then
            printf '%b\n' "${YELLOW}→ 系统 sysctl 服务返回错误，已忽略无关存量配置，继续逐项写入本脚本参数${NC}"
        fi
    fi

    if ! apply_own_sysctl; then
        error "重载 sysctl 失败，请检查内核支持及配置备份"
    fi
    printf '%b\n' "${GREEN}✓ 系统参数已生效${NC}"
}

# 验证结果
verify() {
    echo ""
    printf '%b\n' "${BLUE}==> 验证状态${NC}"
    
    CC=$(sysctl -n net.ipv4.tcp_congestion_control) || error "无法读取拥塞控制状态"
    QDISC=$(sysctl -n net.core.default_qdisc) || error "无法读取排队规则状态"
    
    if [ "$CC" = "bbr" ] && [ -n "$CHOSEN_QDISC" ] && [ "$QDISC" = "$CHOSEN_QDISC" ]; then
        printf '%b\n' "${GREEN}✓ 当前拥塞控制: $CC${NC}"
        printf '%b\n' "${GREEN}✓ 当前排队规则: $QDISC${NC}"
    else
        error "参数未生效 (congestion=$CC, qdisc=$QDISC)，请检查内核支持及配置备份"
    fi
}

# 显示摘要
summary() {
    echo ""
    printf '%b\n' "${BLUE}========================================${NC}"
    printf '%b\n' "${GREEN}✅ BBR 智能调优配置完成！${NC}"
    printf '%b\n' "${BLUE}========================================${NC}"
    printf '%b\n' "系统环境: $DISPLAY_OS"
    printf '%b\n' "物理内存: ${TOTAL_MEM} MB"
    printf '%b\n' "动态缓冲: $((RMEM_MAX/1024/1024)) MB"
    printf '%b\n' "排队规则: $CHOSEN_QDISC"
    echo ""
}

# 主流程
main() {
    detect_os
    check_requirements
    detect_memory
    enable_bbr
    backup_config
    apply_config
    reload_config
    verify
    persist_modules
    summary
}

main
