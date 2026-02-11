#!/bin/bash
# BBR Blast Smooth v2 - Auto-detect OS/Memory Smart Tuning
# Supports Debian 11/12/13, Ubuntu 20.04/22.04/24.04
# Auto-adjust buffer size based on memory

set -e

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   BBR Blast Smooth v2 Smart Tuning${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        echo -e "${RED}[X] Cannot detect OS${NC}"
        exit 1
    fi
    case "$OS" in
        debian)
            if [[ "$VER" =~ ^(11|12|13)$ ]]; then
                echo -e "${GREEN}[OK] Detected Debian $VER${NC}"
            else
                echo -e "${RED}[X] Only Debian 11/12/13 supported${NC}"
                exit 1
            fi
            ;;
        ubuntu)
            if [[ "$VER" =~ ^(20.04|22.04|24.04)$ ]]; then
                echo -e "${GREEN}[OK] Detected Ubuntu $VER${NC}"
            else
                echo -e "${RED}[X] Only Ubuntu 20.04/22.04/24.04 supported${NC}"
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}[X] Unsupported OS: $OS${NC}"
            exit 1
            ;;
    esac
}

# Detect memory
detect_memory() {
    TOTAL_MEM=$(free -m | awk "/^Mem:/{print \$2}")
    echo -e "${GREEN}[OK] Memory: ${TOTAL_MEM}MB${NC}"
    if [ "$TOTAL_MEM" -lt 512 ]; then
        PROFILE="micro"
        RMEM_MAX=8388608
        WMEM_MAX=8388608
        TCP_RMEM="4096 32768 8388608"
        TCP_WMEM="4096 32768 8388608"
        echo -e "${YELLOW}-> Using Micro profile (8MB buffer)${NC}"
    elif [ "$TOTAL_MEM" -lt 1024 ]; then
        PROFILE="small"
        RMEM_MAX=16777216
        WMEM_MAX=16777216
        TCP_RMEM="4096 65536 16777216"
        TCP_WMEM="4096 65536 16777216"
        echo -e "${YELLOW}-> Using Small profile (16MB buffer)${NC}"
    elif [ "$TOTAL_MEM" -lt 2048 ]; then
        PROFILE="medium"
        RMEM_MAX=33554432
        WMEM_MAX=33554432
        TCP_RMEM="4096 87380 33554432"
        TCP_WMEM="4096 65536 33554432"
        echo -e "${YELLOW}-> Using Medium profile (32MB buffer)${NC}"
    elif [ "$TOTAL_MEM" -lt 4096 ]; then
        PROFILE="large"
        RMEM_MAX=67108864
        WMEM_MAX=67108864
        TCP_RMEM="4096 87380 67108864"
        TCP_WMEM="4096 65536 67108864"
        echo -e "${YELLOW}-> Using Large profile (64MB buffer)${NC}"
    else
        PROFILE="xlarge"
        RMEM_MAX=134217728
        WMEM_MAX=134217728
        TCP_RMEM="4096 87380 134217728"
        TCP_WMEM="4096 65536 134217728"
        echo -e "${YELLOW}-> Using XLarge profile (128MB buffer)${NC}"
    fi
}

# Enable BBR
enable_bbr() {
    echo ""
    echo -e "${BLUE}==> Enabling BBR${NC}"
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    echo -e "${GREEN}[OK] BBR module loaded${NC}"
}

# Backup config
backup_config() {
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
        echo -e "${GREEN}[OK] Config backed up${NC}"
    fi
}

# Apply config
apply_config() {
    echo ""
    echo -e "${BLUE}==> Writing config (Profile: $PROFILE)${NC}"
    sed -i "/# === BBR Blast/,/# === END BBR/d" /etc/sysctl.conf 2>/dev/null || true
    cat >> /etc/sysctl.conf <<SYSCTL

# === BBR Blast Smooth v2 (Profile: $PROFILE) ===
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
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_fastopen=3
# === END BBR ===
SYSCTL
    echo -e "${GREEN}[OK] Config written${NC}"
}

# Reload
reload_config() {
    echo ""
    echo -e "${BLUE}==> Applying${NC}"
    sysctl -p >/dev/null 2>&1
    echo -e "${GREEN}[OK] Applied${NC}"
}

# Verify
verify() {
    echo ""
    echo -e "${BLUE}==> Verifying${NC}"
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$CC" = "bbr" ] && [ "$QDISC" = "fq" ]; then
        echo -e "${GREEN}[OK] Congestion: $CC${NC}"
        echo -e "${GREEN}[OK] Qdisc: $QDISC${NC}"
    else
        echo -e "${RED}[!] May need reboot${NC}"
    fi
}

# Summary
summary() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}[DONE] BBR Blast Smooth v2 Complete!${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "OS: $OS $VER"
    echo "Memory: ${TOTAL_MEM}MB"
    echo "Profile: $PROFILE"
    echo "Buffer: $(($RMEM_MAX/1024/1024))MB"
}

# Main
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
