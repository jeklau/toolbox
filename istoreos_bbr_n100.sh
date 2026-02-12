cat << 'EOF' > /tmp/bbr_setup.sh
#!/bin/sh

# ============================================================
# iStoreOS BBR & 双千兆网络深度优化脚本 (N100 专用)
# ============================================================

echo "开始执行网络优化..."

# 1. 更新软件源并安装 BBR 内核模块
echo "正在检查并安装 BBR 内核模块..."
opkg update
opkg install kmod-tcp-bbr

# 2. 强制加载模块并设置开机自启
if ! lsmod | grep -q "tcp_bbr"; then
    echo "加载 tcp_bbr 模块..."
    modprobe tcp_bbr
fi
# 确保重启后自动加载模块
[ ! -f /etc/modules.d/tcp-bbr ] && echo "tcp_bbr" > /etc/modules.d/tcp-bbr

# 3. 写入内核优化参数 (针对双线 2000M 环境)
echo "正在配置内核参数..."
cat << 'SYS' > /etc/sysctl.d/99-network-opt.conf
# 开启 BBR 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# --- 针对 2000M 高带宽优化 ---
# 增大 TCP 接收/发送缓冲区 (上限 64MB)，防止高速下载时丢包
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.rmem_max=67108864
net.core.wmem_max=67108864

# 开启 MTU 探测，解决双线 PPPoE 环境下部分网站打不开的问题
net.ipv4.tcp_mtu_probing=1

# 开启 TCP Fast Open (降低握手延迟)
net.ipv4.tcp_fastopen=3

# 优化内存管理
net.ipv4.tcp_mem=786432 1048576 1572864
SYS

# 4. 立即应用参数
sysctl -p /etc/sysctl.d/99-network-opt.conf

echo "------------------------------------------------"
echo "✅ 优化完成！当前状态查询："
echo "当前算法: $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
echo "当前队列: $(sysctl net.core.default_qdisc | awk '{print $3}')"
echo "------------------------------------------------"
EOF

# 赋予权限并执行
chmod +x /tmp/bbr_setup.sh
sh /tmp/bbr_setup.sh
