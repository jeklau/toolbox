#!/bin/bash

# ==============================================================================
# Role: Linux Network & System Optimizer
# Description: Dynamic SWAP Allocation + Hardware-aware BBR Tuning
# Features: Strict mode, Idempotency, Safe SWAP handling, Dynamic sysctl
# ==============================================================================

# 启用严格模式
set -euo pipefail

# 日志输出函数
log_info() { echo -e "\033[32m[INFO] $1\033[0m"; }
log_warn() { echo -e "\033[33m[WARN] $1\033[0m"; }
log_err()  { echo -e "\033[31m[ERROR] $1\033[0m"; >&2; exit 1; }

# 1. 前置检查
if [[ "$(id -u)" -ne 0 ]]; then
    log_err "此脚本必须以 Root 权限运行。"
fi

# 2. 硬件资源侦测
log_info ">> [1/4] 正在检测系统硬件资源..."
MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_GB=$(( MEM_MB / 1024 ))
[[ "$MEM_GB" -eq 0 ]] && MEM_GB=1

CPU_CORES=$(nproc)
log_info "检测到硬件配置: $CPU_CORES 核心 CPU, 约 $MEM_MB MB 物理内存。"

# ==============================================================================
# 3. 动态 SWAP 调整模块
# ==============================================================================
log_info ">> [2/4] 正在评估与配置 SWAP 空间..."

# 计算目标 SWAP 大小 (MB)
if [[ "$MEM_MB" -le 2048 ]]; then
    TARGET_SWAP_MB=2048
elif [[ "$MEM_MB" -le 8192 ]]; then
    TARGET_SWAP_MB=$MEM_MB
else
    TARGET_SWAP_MB=8192
fi

SWAP_FILE="/swapfile"
CURRENT_SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)

# 检查是否已存在足够大小的 Swap
if [[ "$CURRENT_SWAP_KB" -gt 0 ]]; then
    CURRENT_SWAP_MB=$(( CURRENT_SWAP_KB / 1024 ))
    log_info "系统已存在 ${CURRENT_SWAP_MB}MB 的 Swap 空间。"
    # 如果现有 Swap 达到目标值的 80% 以上，则认为足够，不进行破坏性修改
    if [[ "$CURRENT_SWAP_MB" -ge $(( TARGET_SWAP_MB * 8 / 10 )) ]]; then
         log_info "现有 Swap 空间充足，跳过 Swap 创建步骤，防止破坏现有磁盘布局。"
    else
         log_warn "现有 Swap (${CURRENT_SWAP_MB}MB) 小于推荐值 (${TARGET_SWAP_MB}MB)，但为了安全起见，本脚本不主动删除已有 Swap 分区。"
    fi
else
    # 创建 /swapfile
    log_warn "系统无 Swap 空间。即将创建 ${TARGET_SWAP_MB}MB 的 Swap 文件 ($SWAP_FILE)..."
    log_info "使用 dd 写入数据，这可能需要几分钟，请耐心等待..."
    
    # 彻底清理可能残留的文件
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
    
    # 使用 dd 创建（兼容性最好，不使用 fallocate 以防 Btrfs/ZFS 报错）
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$TARGET_SWAP_MB" status=progress
    
    # 设置安全权限（极其重要，否则会有安全漏洞告警）
    chmod 600 "$SWAP_FILE"
    
    # 格式化并启用
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    
    # 写入 fstab 实现开机挂载 (幂等性检查)
    if ! grep -q "^$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        log_info "已将 Swap 写入 /etc/fstab 以实现持久化。"
    fi
    log_info "Swap 创建完成并启用。"
fi

# 调整 Swappiness 参数 (控制内核使用 Swap 的积极性)
# 对于代理服务器，尽量使用物理内存，但在危急时刻使用 Swap
sysctl -w vm.swappiness=10 > /dev/null

# ==============================================================================
# 4. 动态网络栈与 BBR 调优模块
# ==============================================================================
log_info ">> [3/4] 正在计算并应用动态 BBR 网络参数..."

# 根据内存计算缓冲区限制
if [[ "$MEM_GB" -le 2 ]]; then
    BUFFER_MAX=16777216     # ~16MB
    UDP_MEM="8192 16384 32768"
elif [[ "$MEM_GB" -le 8 ]]; then
    BUFFER_MAX=67108864     # ~64MB
    UDP_MEM="32768 65536 131072"
else
    BUFFER_MAX=134217728    # ~128MB
    UDP_MEM="65536 131072 262144"
fi

# 根据 CPU 计算队列长度
if [[ "$CPU_CORES" -le 2 ]]; then
    QUEUE_SIZE=8192
elif [[ "$CPU_CORES" -le 4 ]]; then
    QUEUE_SIZE=32768
else
    QUEUE_SIZE=65536
fi

SYSCTL_FILE="/etc/sysctl.d/99-auto-network-bbr.conf"

cat <<EOF > "$SYSCTL_FILE"
# ==============================================================
# Auto-generated Network & VM Tuning Profile
# Hardware: $CPU_CORES Cores, ${MEM_GB}GB RAM
# Date: $(date "+%Y-%m-%d %H:%M:%S")
# ==============================================================

# --- Virtual Memory (Swap) ---
vm.swappiness = 10

# --- Queue & Backlog ---
net.core.somaxconn = $QUEUE_SIZE
net.core.netdev_max_backlog = $QUEUE_SIZE
net.ipv4.tcp_max_syn_backlog = $QUEUE_SIZE
net.ipv4.tcp_max_orphans = $QUEUE_SIZE

# --- Buffer Sizes ---
net.core.rmem_max = $BUFFER_MAX
net.core.wmem_max = $BUFFER_MAX
net.ipv4.tcp_rmem = 4096 87380 $BUFFER_MAX
net.ipv4.tcp_wmem = 4096 65536 $BUFFER_MAX
net.ipv4.udp_mem = $UDP_MEM

# --- BBR & Congestion Control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- TCP Lifecycle & Security ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_no_metrics_save = 1

# --- Security Routing ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF

# ==============================================================================
# 5. 应用与验证
# ==============================================================================
log_info ">> [4/4] 正在加载并验证配置..."

# 重新加载 sysctl 配置
sysctl --system > /dev/null

# 验证 BBR
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc)

if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
    log_info "网络栈优化成功！当前 TCP 拥塞控制算法: $CURRENT_CC, 队列规则: $CURRENT_QDISC"
else
    log_warn "BBR 未能正确激活，请确认当前内核是否支持 (>=4.9)。当前拥塞控制算法为: $CURRENT_CC"
fi

log_info "全套自动化调优执行完毕！系统已准备好迎接高并发流量。"
