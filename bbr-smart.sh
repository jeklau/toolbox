#!/bin/bash
# BBR Blast Smooth v2.2 - 自动识别系统/内存智能调优版
# 支持 Debian 11-13, Ubuntu 20.04-24.04, iStoreOS, OpenWrt, ImmortalWrt
# 适配 OpenWrt 25.12+ 的 apk 包管理器及经典 opkg 🚀

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   BBR Blast Smooth v2.2 智能调优版${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=${VERSION_ID:-"unknown"}
        REAL_NAME=${NAME:-$ID}
        
        # 兼容处理基于 OpenWrt 的衍生系统
        if [[ "${ID,,}" == "istoreos" || "${NAME,,}" == *"istoreos"* || "${ID,,}" == "openwrt" || "${ID,,}" == "immortalwrt" || "${NAME,,}" == *"immortalwrt"* ]]; then
            OS="openwrt"
            DISPLAY_OS="$REAL_NAME ($VER)"
        else
            DISPLAY_OS="$ID $VER"
        fi
    else
        echo -e "${RED}❌ 无法识别系统${NC}"
        exit 1
    fi
    
    case "$OS" in
        debian|ubuntu)
            echo -e "${GREEN}✓ 检测到 $DISPLAY_OS${NC}"
            ;;
        openwrt)
            echo -e "${GREEN}✓ 检测到 OpenWrt 系分支: $DISPLAY_OS${NC}"
            ;;
        *)
            echo -e "${RED}❌ 不支持的系统: $OS${NC}"
            exit 1
            ;;
    esac
}

# 检测内存并设置参数
detect_memory() {
    # 兼容 BusyBox，改用更底层的 /proc/meminfo
    TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    if [ -z "$TOTAL_MEM" ] || [ "$TOTAL_MEM" -eq 0 ]; then
        echo -e "${RED}❌ 无法读取系统内存信息${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ 检测到内存: ${TOTAL_MEM}MB${NC}"

    # 缓冲区 = 内存的 1/8，最小 8MB，最大 256MB
    BUF_MB=$(( TOTAL_MEM / 8 ))
    [ "$BUF_MB" -lt 8 ]   && BUF_MB=8
    [ "$BUF_MB" -gt 256 ] && BUF_MB=256
    BUF_BYTES=$(( BUF_MB * 1024 * 1024 ))

    if [ "$TOTAL_MEM" -lt 512 ]; then
        PROFILE="micro"
        echo -e "${YELLOW}→ 使用 Micro 配置 (极小内存优化)${NC}"
    elif [ "$TOTAL_MEM" -lt 1024 ]; then
        PROFILE="small"
        echo -e "${YELLOW}→ 使用 Small 配置 (小内存优化)${NC}"
    elif [ "$TOTAL_MEM" -lt 2048 ]; then
        PROFILE="medium"
        echo -e "${YELLOW}→ 使用 Medium 配置 (中等内存)${NC}"
    elif [ "$TOTAL_MEM" -lt 4096 ]; then
        PROFILE="large"
        echo -e "${YELLOW}→ 使用 Large 配置 (大内存)${NC}"
    else
        PROFILE="xlarge"
        echo -e "${YELLOW}→ 使用 XLarge 配置 (超大内存)${NC}"
    fi

    RMEM_MAX=$BUF_BYTES
    WMEM_MAX=$BUF_BYTES
    TCP_RMEM="4096 87380 $BUF_BYTES"
    TCP_WMEM="4096 65536 $BUF_BYTES"
    echo -e "${YELLOW}→ 动态计算缓冲区上限: ${BUF_MB}MB${NC}"
}

# 启用 BBR (重点优化 apk/opkg 智能检测)
enable_bbr() {
    echo ""
    echo -e "${BLUE}==> 启用 BBR 内核模块${NC}"
    
    if [[ "$OS" == "openwrt" ]]; then
        # OpenWrt 系需要确认 kmod-tcp-bbr 模块
        if ! modprobe tcp_bbr 2>/dev/null; then
            echo -e "${YELLOW}→ 未检测到 tcp_bbr 模块，准备尝试通过包管理器安装...${NC}"
            
            # 智能探测包管理器：优先检测 apk (新版 OpenWrt)，回退检测 opkg
            if command -v apk >/dev/null 2>&1; then
                echo -e "${GREEN}✓ 检测到 apk 包管理器 (OpenWrt 25.12+)${NC}"
                apk update >/dev/null 2>&1 && apk add kmod-tcp-bbr >/dev/null 2>&1 || true
            elif command -v opkg >/dev/null 2>&1; then
                echo -e "${GREEN}✓ 检测到 opkg 包管理器 (经典版本)${NC}"
                opkg update >/dev/null 2>&1 && opkg install kmod-tcp-bbr >/dev/null 2>&1 || true
            else
                echo -e "${RED}❌ 未找到 apk 或 opkg，无法自动安装模块。${NC}"
            fi

            # 再次尝试加载
            modprobe tcp_bbr 2>/dev/null || { echo -e "${RED}❌ 无法加载 tcp_bbr，请确认您的固件内核是否编译了 BBR 支持。${NC}"; exit 1; }
        fi
        
        # OpenWrt 模块开机自启
        if [ -d /etc/modules.d ]; then
            echo "tcp_bbr" > /etc/modules.d/bbr
        fi
    else
        # Debian/Ubuntu 逻辑
        modprobe tcp_bbr 2>/dev/null || true
        if [ -d /etc/modules-load.d ]; then
            echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        fi
    fi
    echo -e "${GREEN}✓ BBR 内核模块已就绪${NC}"
}

# 备份原配置
backup_config() {
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
        echo -e "${GREEN}✓ 已备份原内核参数配置到 /etc/sysctl.conf.bak.*${NC}"
    fi
}

# 写入优化参数
apply_config() {
    echo ""
    echo -e "${BLUE}==> 写入内核优化参数 (Profile: $PROFILE)${NC}"
    
    # 幂等性：移除旧的 BBR 配置
    sed -i '/# === BBR Blast Smooth/,/# === END BBR/d' /etc/sysctl.conf 2>/dev/null || true
    
    cat >> /etc/sysctl.conf <<SYSCTL

# === BBR Blast Smooth v2.2 (Profile: $PROFILE) ===
# 系统: $DISPLAY_OS | 内存: ${TOTAL_MEM}MB | 缓冲: ${BUF_MB}MB
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.rmem_max=$RMEM_MAX
net.core.wmem_max=$WMEM_MAX
net.ipv4.tcp_rmem=$TCP_RMEM
net.ipv4.tcp_wmem=$TCP_WMEM

net.ipv4.tcp_fin_timeout=8
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_no_metrics_save=1
# === END BBR ===
SYSCTL

    echo -e "${GREEN}✓ 优化参数已写入系统配置${NC}"
}

# 应用配置
reload_config() {
    echo ""
    echo -e "${BLUE}==> 重载系统配置${NC}"
    
    if [[ "$OS" == "openwrt" ]] && [ -x /etc/init.d/sysctl ]; then
        /etc/init.d/sysctl restart >/dev/null 2>&1
    else
        sysctl -p >/dev/null 2>&1
    fi
    echo -e "${GREEN}✓ 系统参数已生效${NC}"
}

# 验证结果
verify() {
    echo ""
    echo -e "${BLUE}==> 验证状态${NC}"
    
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    if [ "$CC" = "bbr" ] && [ "$QDISC" = "fq" ]; then
        echo -e "${GREEN}✓ 当前拥塞控制: $CC${NC}"
        echo -e "${GREEN}✓ 当前排队规则: $QDISC${NC}"
    else
        echo -e "${RED}⚠ 配置可能未完全生效，由于内核版本或防火墙环境差异，建议重启系统${NC}"
    fi
}

# 显示摘要
summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}✅ BBR 智能调优配置完成！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "系统环境: $DISPLAY_OS"
    echo -e "物理内存: ${TOTAL_MEM} MB"
    echo -e "动态缓冲: $(($RMEM_MAX/1024/1024)) MB"
    echo ""
}

# 主流程
main() {
    detect_os
    detect_memory
    enable_bbr
    backup_config
    apply_config
    reload_config
    verify
    summary
}

main
