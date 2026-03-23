#!/bin/bash
# SS-Rust 一键安装脚本
# 支持: ss2022 (2022-blake3-aes-128-gcm) / ss128 (aes-128-gcm) / 双节点
# 自动生成 SS订阅 + Surge + Clash 配置
# GitHub: https://github.com/mango082888-bit/ss-rust

# ============ 颜色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============ 全局变量 ============
SERVER_IP=""
PORT_2022=""
KEY_2022=""
METHOD_2022=""
PORT_RAW=""
KEY_RAW=""
METHOD_RAW=""
NODE_MODE=""

# ============ 基础检测 ============
check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行"
}

get_pkg_manager() {
    if command -v apt &>/dev/null; then
        PKG="apt"
    elif command -v yum &>/dev/null; then
        PKG="yum"
    elif command -v apk &>/dev/null; then
        PKG="apk"
    else
        error "不支持的包管理器"
    fi
}

install_deps() {
    info "安装依赖..."
    case $PKG in
        apt) apt update -qq &>/dev/null; apt install -y -qq curl openssl xz-utils tar chrony python3 &>/dev/null ;;
        yum) yum install -y -q curl openssl xz tar chrony python3 &>/dev/null ;;
        apk) apk add --quiet curl openssl xz tar chrony python3 &>/dev/null ;;
    esac
}

get_arch() {
    case $(uname -m) in
        x86_64)  echo "x86_64-unknown-linux-gnu" ;;
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
        armv7l)  echo "armv7-unknown-linux-gnueabihf" ;;
        *)       error "不支持的架构: $(uname -m)" ;;
    esac
}

get_ip() {
    local ip
    ip=$(curl -s4m5 ip.sb 2>/dev/null || curl -s4m5 ifconfig.me 2>/dev/null || curl -s4m5 ipinfo.io/ip 2>/dev/null)
    [[ -z "$ip" ]] && error "无法获取公网IP"
    echo "$ip"
}

# ============ 时间同步 ============
sync_time() {
    info "同步系统时间..."
    if command -v timedatectl &>/dev/null; then
        timedatectl set-ntp true 2>/dev/null || true
    fi
    if command -v chronyd &>/dev/null; then
        systemctl enable --now chronyd 2>/dev/null || true
        chronyc makestep 2>/dev/null || true
    fi
    info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ============ 安装 ss-rust ============
install_ssrust() {
    info "安装 shadowsocks-rust..."
    local arch_name
    arch_name=$(get_arch)

    local latest
    latest=$(curl -sLm10 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | grep tag_name | head -1 | sed 's/.*"v/v/;s/".*//')
    [[ -z "$latest" ]] && latest="v1.24.0"
    info "版本: $latest"

    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${arch_name}.tar.xz"

    cd /tmp
    rm -f ss-rust-dl.tar.xz ssserver sslocal ssurl ssmanager ssservice
    curl -sLm120 "$url" -o ss-rust-dl.tar.xz

    local fsize
    fsize=$(stat -c%s ss-rust-dl.tar.xz 2>/dev/null || stat -f%z ss-rust-dl.tar.xz 2>/dev/null)
    [[ "$fsize" -lt 100000 ]] && error "下载失败 (${fsize} bytes)"

    if command -v file &>/dev/null; then
        file ss-rust-dl.tar.xz | grep -q "XZ" || error "下载的文件不是有效的 XZ 压缩包"
    fi

    tar xf ss-rust-dl.tar.xz || error "解压失败"
    [[ ! -f ssserver ]] && error "找不到 ssserver"

    cp -f ssserver /usr/local/bin/
    cp -f sslocal /usr/local/bin/ 2>/dev/null || true
    chmod +x /usr/local/bin/ssserver /usr/local/bin/sslocal 2>/dev/null

    rm -f ss-rust-dl.tar.xz ssserver sslocal ssurl ssmanager ssservice

    /usr/local/bin/ssserver --version && info "shadowsocks-rust 安装完成" || error "安装验证失败"
}

# ============ 节点选择 + 端口密码 + 写配置 ============
select_and_configure() {
    SERVER_IP=$(get_ip)
    mkdir -p /etc/shadowsocks-rust

    # 清空
    PORT_2022="" ; KEY_2022="" ; METHOD_2022=""
    PORT_RAW="" ; KEY_RAW="" ; METHOD_RAW=""

    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  🔐 选择节点类型${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} SS2022-128  (2022-blake3-aes-128-gcm) — 新协议，推荐"
    echo -e "  ${GREEN}2.${NC} SS-AES-128  (aes-128-gcm) — 传统协议，兼容性好"
    echo -e "  ${GREEN}3.${NC} 双节点全装  (SS2022 + SS128)"
    echo ""
    read -rp "请选择 [1-3] (默认3): " node_choice
    node_choice=${node_choice:-3}

    if [[ "$node_choice" == "1" || "$node_choice" == "3" ]]; then
        local dp=$((RANDOM % 10000 + 20000))
        local dk=$(openssl rand -base64 16)
        echo ""
        echo -e "  ${GREEN}SS2022-128 配置:${NC}"
        read -rp "    端口 [回车=${dp}]: " PORT_2022
        PORT_2022=${PORT_2022:-$dp}
        read -rp "    密码 [回车=${dk}]: " KEY_2022
        KEY_2022=${KEY_2022:-$dk}
        METHOD_2022="2022-blake3-aes-128-gcm"
    fi

    if [[ "$node_choice" == "2" || "$node_choice" == "3" ]]; then
        local dp2=$((RANDOM % 10000 + 30000))
        local dk2=$(openssl rand -base64 16)
        echo ""
        echo -e "  ${GREEN}SS-AES-128 配置:${NC}"
        read -rp "    端口 [回车=${dp2}]: " PORT_RAW
        PORT_RAW=${PORT_RAW:-$dp2}
        read -rp "    密码 [回车=${dk2}]: " KEY_RAW
        KEY_RAW=${KEY_RAW:-$dk2}
        METHOD_RAW="aes-128-gcm"
    fi

    # 写 JSON 配置
    python3 -c "
import json
servers = []
if '${PORT_2022}':
    servers.append({
        'server': '0.0.0.0',
        'server_port': int('${PORT_2022}'),
        'method': '${METHOD_2022}',
        'password': '${KEY_2022}',
        'timeout': 300,
        'fast_open': True
    })
if '${PORT_RAW}':
    servers.append({
        'server': '0.0.0.0',
        'server_port': int('${PORT_RAW}'),
        'method': '${METHOD_RAW}',
        'password': '${KEY_RAW}',
        'timeout': 300,
        'fast_open': True
    })
with open('/etc/shadowsocks-rust/config.json', 'w') as f:
    json.dump({'servers': servers}, f, indent=4)
print('OK')
" || error "生成配置失败"

    info "配置文件: /etc/shadowsocks-rust/config.json"
}

# ============ systemd 服务 ============
setup_service() {
    cat > /etc/systemd/system/ss-rust.service << 'EOF'
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ss-rust
    sleep 2

    if systemctl is-active --quiet ss-rust; then
        info "ss-rust 服务启动成功"
    else
        journalctl -u ss-rust -n 5 --no-pager
        error "ss-rust 服务启动失败"
    fi
}

# ============ 读取现有配置 ============
load_config() {
    [[ ! -f /etc/shadowsocks-rust/config.json ]] && return 1
    SERVER_IP=$(get_ip)
    PORT_2022="" ; KEY_2022="" ; METHOD_2022=""
    PORT_RAW="" ; KEY_RAW="" ; METHOD_RAW=""

    eval $(python3 -c "
import json
with open('/etc/shadowsocks-rust/config.json') as f:
    c = json.load(f)
for s in c['servers']:
    m = s['method']
    if '2022' in m:
        print(f'PORT_2022={s[\"server_port\"]}')
        print(f'KEY_2022={s[\"password\"]}')
        print(f'METHOD_2022={m}')
    else:
        print(f'PORT_RAW={s[\"server_port\"]}')
        print(f'KEY_RAW={s[\"password\"]}')
        print(f'METHOD_RAW={m}')
" 2>/dev/null)
    return 0
}

# ============ 生成订阅 ============
gen_subscribe() {
    load_config || return
    local sub_dir="/etc/shadowsocks-rust/subscribe"
    mkdir -p "$sub_dir"

    local uris="" surge="" clash="" info_txt=""

    if [[ -n "$PORT_2022" ]]; then
        local uri="ss://$(echo -n "${METHOD_2022}:${KEY_2022}" | base64 -w0)@${SERVER_IP}:${PORT_2022}#SS2022-128"
        URI_2022="$uri"
        uris="${uris}${uri}\n"
        surge="${surge}SS2022-128 = ss, ${SERVER_IP}, ${PORT_2022}, encrypt-method=${METHOD_2022}, password=${KEY_2022}\n"
        clash="${clash}  - name: SS2022-128\n    type: ss\n    server: ${SERVER_IP}\n    port: ${PORT_2022}\n    cipher: ${METHOD_2022}\n    password: \"${KEY_2022}\"\n\n"
        info_txt="${info_txt}【SS2022-AES-128】新协议\n  地址: ${SERVER_IP}\n  端口: ${PORT_2022}\n  加密: ${METHOD_2022}\n  密码: ${KEY_2022}\n\n"
    fi

    if [[ -n "$PORT_RAW" ]]; then
        local uri="ss://$(echo -n "${METHOD_RAW}:${KEY_RAW}" | base64 -w0)@${SERVER_IP}:${PORT_RAW}#SS-AES-128"
        URI_RAW="$uri"
        uris="${uris}${uri}\n"
        surge="${surge}SS-AES-128 = ss, ${SERVER_IP}, ${PORT_RAW}, encrypt-method=${METHOD_RAW}, password=${KEY_RAW}\n"
        clash="${clash}  - name: SS-AES-128\n    type: ss\n    server: ${SERVER_IP}\n    port: ${PORT_RAW}\n    cipher: ${METHOD_RAW}\n    password: \"${KEY_RAW}\"\n\n"
        info_txt="${info_txt}【SS-AES-128】传统协议\n  地址: ${SERVER_IP}\n  端口: ${PORT_RAW}\n  加密: ${METHOD_RAW}\n  密码: ${KEY_RAW}\n\n"
    fi

    echo -e "$uris" | base64 -w0 > "$sub_dir/subscribe.txt"

    echo -e "# Surge SS | $(date '+%Y-%m-%d %H:%M:%S') | ${SERVER_IP}\n[Proxy]\n${surge}" > "$sub_dir/surge.conf"
    echo -e "# Clash SS | $(date '+%Y-%m-%d %H:%M:%S')\nproxies:\n${clash}" > "$sub_dir/clash.yaml"
    echo -e "═══ SS-Rust 节点 | $(date '+%Y-%m-%d %H:%M:%S') | ${SERVER_IP} ═══\n\n${info_txt}\n【SS 链接】\n${uris}" > "$sub_dir/info.txt"
}

# ============ 显示结果 ============
show_result() {
    load_config || return
    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  🚀 Shadowsocks-Rust 安装完成${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""

    if [[ -n "$PORT_2022" ]]; then
        echo -e "${GREEN}【SS2022-AES-128】新协议${NC}"
        echo -e "  地址: ${SERVER_IP}"
        echo -e "  端口: ${YELLOW}${PORT_2022}${NC}"
        echo -e "  加密: ${METHOD_2022}"
        echo -e "  密码: ${YELLOW}${KEY_2022}${NC}"
        echo ""
    fi

    if [[ -n "$PORT_RAW" ]]; then
        echo -e "${GREEN}【SS-AES-128】传统协议${NC}"
        echo -e "  地址: ${SERVER_IP}"
        echo -e "  端口: ${YELLOW}${PORT_RAW}${NC}"
        echo -e "  加密: ${METHOD_RAW}"
        echo -e "  密码: ${YELLOW}${KEY_RAW}${NC}"
        echo ""
    fi

    echo -e "${CYAN}────────────────────────────────────────${NC}"
    echo -e "${GREEN}【Surge 格式】${NC}"
    [[ -n "$PORT_2022" ]] && echo "  SS2022-128 = ss, ${SERVER_IP}, ${PORT_2022}, encrypt-method=${METHOD_2022}, password=${KEY_2022}"
    [[ -n "$PORT_RAW" ]] && echo "  SS-AES-128 = ss, ${SERVER_IP}, ${PORT_RAW}, encrypt-method=${METHOD_RAW}, password=${KEY_RAW}"
    echo ""

    echo -e "${CYAN}────────────────────────────────────────${NC}"
    echo -e "${GREEN}【SS 链接】${NC}"
    [[ -n "${URI_2022:-}" ]] && echo "  ${URI_2022}"
    [[ -n "${URI_RAW:-}" ]] && echo "  ${URI_RAW}"
    echo ""

    echo -e "${CYAN}────────────────────────────────────────${NC}"
    echo -e "${GREEN}【文件】${NC}"
    echo "  配置: /etc/shadowsocks-rust/config.json"
    echo "  订阅: /etc/shadowsocks-rust/subscribe/"
    echo ""
    echo -e "${CYAN}【管理】${NC} 再次运行脚本进入管理菜单"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
}

# ============ 查看配置 ============
show_config() {
    load_config || error "未安装"
    echo ""
    echo -e "${CYAN}  📋 当前配置 | 状态: $(systemctl is-active ss-rust 2>/dev/null)${NC}"
    echo ""
    cat /etc/shadowsocks-rust/config.json
    echo ""
    [[ -f /etc/shadowsocks-rust/subscribe/info.txt ]] && cat /etc/shadowsocks-rust/subscribe/info.txt
}

# ============ 修改端口 ============
change_port() {
    load_config || error "未安装"
    echo ""
    [[ -n "$PORT_2022" ]] && echo -e "  1) SS2022-128 | 端口 ${PORT_2022}"
    [[ -n "$PORT_RAW" ]] && echo -e "  2) SS-AES-128 | 端口 ${PORT_RAW}"
    echo ""
    read -rp "节点编号: " pn
    read -rp "新端口: " new_port

    python3 -c "
import json
with open('/etc/shadowsocks-rust/config.json') as f:
    c = json.load(f)
idx = int('${pn}') - 1
if 0 <= idx < len(c['servers']):
    c['servers'][idx]['server_port'] = int('${new_port}')
    with open('/etc/shadowsocks-rust/config.json','w') as f:
        json.dump(c, f, indent=4)
"
    systemctl restart ss-rust
    gen_subscribe
    info "端口已改为 ${new_port}"
}

# ============ 重置密钥 ============
reset_keys() {
    load_config || error "未安装"
    python3 -c "
import json,base64,os
with open('/etc/shadowsocks-rust/config.json') as f:
    c = json.load(f)
for s in c['servers']:
    s['password'] = base64.b64encode(os.urandom(16)).decode()
with open('/etc/shadowsocks-rust/config.json','w') as f:
    json.dump(c, f, indent=4)
"
    systemctl restart ss-rust
    gen_subscribe
    info "密钥已重置"
    show_result
}

# ============ BBR 优化 ============
setup_bbr() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ⚡ BBR Blast Smooth v2${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""

    # 检测是否已启用
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$cc" == "bbr" && "$qd" == "fq" ]] && grep -q "TCP Tuning" /etc/sysctl.conf 2>/dev/null; then
        info "BBR + TCP 完整调优已启用，无需重复配置"
        return 0
    fi
    if [[ "$cc" == "bbr" && "$qd" == "fq" ]]; then
        info "检测到 BBR 已启用，升级为完整 TCP 调优..."
    fi

    # 检测系统
    if [[ ! -f /etc/os-release ]]; then
        warn "无法检测系统，跳过 BBR"; return 1
    fi
    . /etc/os-release
    local os_name="$ID $VERSION_ID"
    info "系统: $os_name"

    # 检测内存，选择 profile
    local mem=$(free -m | awk '/^Mem:/{print $2}')
    local profile rmem wmem tcp_rmem tcp_wmem
    if [[ "$mem" -lt 512 ]]; then
        profile="micro"; rmem=8388608; wmem=8388608
        tcp_rmem="4096 32768 8388608"; tcp_wmem="4096 32768 8388608"
    elif [[ "$mem" -lt 1024 ]]; then
        profile="small"; rmem=16777216; wmem=16777216
        tcp_rmem="4096 65536 16777216"; tcp_wmem="4096 65536 16777216"
    elif [[ "$mem" -lt 2048 ]]; then
        profile="medium"; rmem=33554432; wmem=33554432
        tcp_rmem="4096 87380 33554432"; tcp_wmem="4096 65536 33554432"
    elif [[ "$mem" -lt 4096 ]]; then
        profile="large"; rmem=67108864; wmem=67108864
        tcp_rmem="4096 87380 67108864"; tcp_wmem="4096 65536 67108864"
    else
        profile="xlarge"; rmem=134217728; wmem=134217728
        tcp_rmem="4096 87380 134217728"; tcp_wmem="4096 65536 134217728"
    fi
    info "内存: ${mem}MB | Profile: $profile | Buffer: $((rmem/1024/1024))MB"

    # 备份
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)
    fi

    # 写入配置
    sed -i '/# === BBR Blast/,/# === END BBR/d' /etc/sysctl.conf 2>/dev/null || true
    cat >> /etc/sysctl.conf <<SYSCTL

# === BBR Blast Smooth v2 + TCP Tuning (Profile: $profile) ===
# BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Buffer
net.core.rmem_max=$rmem
net.core.wmem_max=$wmem
net.core.rmem_default=$((rmem/4))
net.core.wmem_default=$((wmem/4))
net.ipv4.tcp_rmem=$tcp_rmem
net.ipv4.tcp_wmem=$tcp_wmem
net.core.optmem_max=65536
net.core.netdev_max_backlog=16384
net.core.netdev_budget=600
net.core.netdev_budget_usecs=20000

# Connection
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_max_orphans=65535
net.ipv4.ip_local_port_range=1024 65535

# Keepalive
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

# Timeout & Reuse
net.ipv4.tcp_fin_timeout=8
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=8
net.ipv4.tcp_orphan_retries=2

# Performance
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_adv_win_scale=2

# Security
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rfc1337=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0

# IPv6 (disable if not needed)
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# File descriptors
fs.file-max=2097152
fs.nr_open=2097152
# === END BBR ===
SYSCTL

    sysctl -p >/dev/null 2>&1

    # 验证
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$cc" == "bbr" && "$qd" == "fq" ]]; then
        info "BBR 启用成功 ✓ (congestion=$cc, qdisc=$qd)"
    else
        warn "BBR 可能需要重启生效"
    fi
}

# ============ 卸载 ============
uninstall() {
    warn "卸载 shadowsocks-rust..."
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f /etc/systemd/system/ss-rust.service
    rm -f /usr/local/bin/ssserver /usr/local/bin/sslocal /usr/local/bin/ssurl
    rm -rf /etc/shadowsocks-rust
    systemctl daemon-reload
    info "卸载完成"
}

# ============ 安装流程 ============
do_install() {
    get_pkg_manager
    install_deps
    sync_time
    install_ssrust
    select_and_configure
    setup_service
    gen_subscribe
    show_result
    echo ""
    read -rp "是否开启 BBR 加速? [Y/n]: " bbr_choice
    bbr_choice=${bbr_choice:-Y}
    [[ "$bbr_choice" =~ ^[Yy]$ ]] && setup_bbr
}

# ============ 管理菜单 ============
show_menu() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}  🚀 SS-Rust 管理面板${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 重新安装 (选择节点类型)"
    echo -e "  ${GREEN}2.${NC} 查看配置 + 节点信息"
    echo -e "  ${GREEN}3.${NC} 修改端口"
    echo -e "  ${GREEN}4.${NC} 重置密钥"
    echo -e "  ${GREEN}5.${NC} 启动服务"
    echo -e "  ${GREEN}6.${NC} 停止服务"
    echo -e "  ${GREEN}7.${NC} 重启服务"
    echo -e "  ${GREEN}8.${NC} 查看日志"
    echo -e "  ${GREEN}10.${NC} ⚡ BBR 加速优化"
    echo -e "  ${RED}9.${NC} 卸载"
    echo -e "  ${YELLOW}0.${NC} 退出"
    echo ""
    read -rp "请选择 [0-10]: " choice

    case "$choice" in
        1) do_install ;;
        2) show_config ;;
        3) change_port ;;
        4) reset_keys ;;
        5) systemctl start ss-rust && info "已启动" ;;
        6) systemctl stop ss-rust && info "已停止" ;;
        7) systemctl restart ss-rust && info "已重启" ;;
        8) journalctl -u ss-rust --no-pager -n 30 ;;
        9) uninstall ;;
        10) setup_bbr ;;
        0) exit 0 ;;
        *) warn "无效选择" ;;
    esac
}

# ============ 主入口 ============
main() {
    check_root
    case "${1:-}" in
        install)            do_install ;;
        uninstall|remove)   uninstall ;;
        show|config|info)   show_config ;;
        restart)            systemctl restart ss-rust && info "已重启" ;;
        start)              systemctl start ss-rust && info "已启动" ;;
        stop)               systemctl stop ss-rust && info "已停止" ;;
        log|logs)           journalctl -u ss-rust --no-pager -n 30 ;;
        reset)              reset_keys ;;
        bbr)                setup_bbr ;;
        *)
            if [[ -f /etc/shadowsocks-rust/config.json ]]; then
                show_menu
            else
                do_install
            fi
            ;;
    esac
}

main "$@"
