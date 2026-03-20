#!/usr/bin/env bash
#===============================================================================
# Description: Shadowsocks-rust 一键部署脚本
# Author: Gemini.Google
# Compatibility: Ubuntu / Debian / CentOS / AlmaLinux
#===============================================================================

# 启用严格模式
set -euo pipefail

#===============================================================================
# 全局变量定义
#===============================================================================
readonly SS_CONFIG_DIR="/etc/shadowsocks-rust"
readonly SS_CONFIG_FILE="${SS_CONFIG_DIR}/config.json"
readonly SS_BIN_DIR="/usr/local/bin"
readonly SS_BIN_PATH="${SS_BIN_DIR}/ssserver"
readonly SYSTEMD_SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
readonly DEFAULT_LINK_NAME="SS2022-128"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
log_err()  { echo -e "${RED}[ERROR] $1${NC}"; >&2; }

#===============================================================================
# 模块 1: 环境检查与基础依赖
#===============================================================================
check_env() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "请使用 root 权限运行此脚本 (例如: sudo ./install_ss_rust.sh)。"
        exit 1
    fi

    local deps=("curl" "wget" "tar" "openssl" "base64" "iproute2")
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y && apt-get install -y "${dep}" || true
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "${dep}" || true
            fi
        fi
    done
}

get_latest_version() {
    # 动态获取 GitHub 最新 Release 版本号
    curl -sL -o /dev/null -w '%{url_effective}' https://github.com/shadowsocks/shadowsocks-rust/releases/latest | rev | cut -d'/' -f1 | rev
}

get_public_ip() {
    curl -s4 ifconfig.me || curl -s4 ip.sb || echo "YOUR_SERVER_IP"
}

#===============================================================================
# 模块 2: 时间同步配置 (新加坡时区 Asia/Singapore)
#===============================================================================
setup_time_sync() {
    log_info "正在配置系统时间自动同步 (Chrony)..."
    
    # 安装 chrony 时间同步工具
    if ! command -v chronyd >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y chrony
        elif command -v yum >/dev/null 2>&1; then
            yum install -y chrony
        fi
    fi

    # 启动服务并配置时区
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable chronyd || systemctl enable chrony || true
        systemctl start chronyd || systemctl start chrony || true
        
        # 强制开启 NTP 同步
        timedatectl set-ntp true || true
        
        # 严格按照需求：设置时区为新加坡 (UTC+8)
        log_info "正在设置服务器时区为: Asia/Singapore (UTC+8)..."
        timedatectl set-timezone Asia/Singapore || true
    fi
    
    # 打印验证当前时间与时区标志 (%Z)
    log_info "时间同步配置完成。当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

#===============================================================================
# 模块 3: 防火墙自动放行
#===============================================================================
setup_firewall() {
    local port="$1"
    log_info "正在尝试自动配置本地防火墙放行端口 ${port} (TCP/UDP)..."

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1
        ufw allow "${port}/udp" >/dev/null 2>&1
        log_info "已通过 UFW 放行端口 ${port}。"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1
        firewall-cmd --add-port="${port}/udp" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "已通过 Firewalld 放行端口 ${port}。"
    elif command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT
        iptables -I INPUT -p udp --dport "${port}" -j ACCEPT
        log_info "已通过 Iptables 插入放行规则。"
    else
        log_warn "未检测到活动的标准防火墙工具。如果无法连接，请手动检查系统防火墙规则。"
    fi
    
    log_warn "云服务器安全组提醒: 请务必登录您的云服务商控制台，在安全组入站规则中放行端口 ${port} 的 TCP 和 UDP 流量！"
}

#===============================================================================
# 模块 4: 安装与配置核心逻辑
#===============================================================================
install_ss() {
    log_info "开始下载并安装 Shadowsocks-rust..."
    local version arch tarball download_url tmp_dir
    version=$(get_latest_version)
    arch=$(uname -m)
    [[ "${arch}" == "armv7l" ]] && arch="arm"
    
    tarball="shadowsocks-${version}.${arch}-unknown-linux-gnu.tar.xz"
    download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/${tarball}"
    
    tmp_dir=$(mktemp -d)
    wget -q --show-progress -O "${tmp_dir}/${tarball}" "${download_url}"
    tar -xf "${tmp_dir}/${tarball}" -C "${tmp_dir}"
    
    install -m 755 "${tmp_dir}/ssserver" "${SS_BIN_PATH}"
    rm -rf "${tmp_dir}"
    log_info "二进制文件安装完成。"

    configure_ss
}

configure_ss() {
    log_info "--- 开始配置参数 ---"
    
    local random_port random_pwd port user_port cipher_choice method password user_pwd
    random_port=$(shuf -i 10000-65535 -n 1)
    read -r -p "请输入服务端端口 (默认回车使用随机端口 ${random_port}): " user_port
    port="${user_port:-${random_port}}"

    echo "请选择加密方式:"
    echo "  1) 2022-blake3-aes-128-gcm (默认, SS2022标准)"
    echo "  2) aes-128-gcm (备用传统加密)"
    read -r -p "请输入序号 [1-2] (默认: 1): " cipher_choice
    if [[ "${cipher_choice}" == "2" ]]; then
        method="aes-128-gcm"
    else
        method="2022-blake3-aes-128-gcm"
    fi

    # 生成严格匹配 SS2022 128位加密的 16 byte Base64 密码
    random_pwd=$(openssl rand -base64 16)
    read -r -p "请输入密码 (默认回车使用随机密码 ${random_pwd}): " user_pwd
    password="${user_pwd:-${random_pwd}}"

    # 写入配置文件
    mkdir -p "${SS_CONFIG_DIR}"
    cat > "${SS_CONFIG_FILE}" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${port},
    "password": "${password}",
    "method": "${method}",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

    # 配置 Systemd 守护进程
    cat > "${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Shadowsocks-rust Server
After=network.target

[Service]
ExecStart=${SS_BIN_PATH} -c ${SS_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadowsocks-rust
    systemctl restart shadowsocks-rust

    # 触发防火墙自动放行逻辑
    setup_firewall "${port}"
    
    # 打印最终配置与订阅链接
    generate_link "${method}" "${password}" "${port}"
}

generate_link() {
    local method="$1" password="$2" port="$3" ip userinfo ss_link
    ip=$(get_public_ip)
    userinfo=$(echo -n "${method}:${password}" | base64 -w 0 | tr -d '\n')
    ss_link="ss://${userinfo}@${ip}:${port}#${DEFAULT_LINK_NAME}"

    echo -e "\n=================================================="
    echo -e "${GREEN}安装与配置成功！${NC}"
    echo -e "--------------------------------------------------"
    echo -e "服务器 IP  : ${YELLOW}${ip}${NC}"
    echo -e "端口 (Port): ${YELLOW}${port}${NC}"
    echo -e "加密方式   : ${YELLOW}${method}${NC}"
    echo -e "密码 (Pwd) : ${YELLOW}${password}${NC}"
    echo -e "--------------------------------------------------"
    echo -e "专属分享链接 (复制导入客户端):"
    echo -e "${RED}${ss_link}${NC}"
    echo -e "==================================================\n"
}

#===============================================================================
# 模块 5: 卸载逻辑
#===============================================================================
uninstall_ss() {
    log_warn "警告: 即将停止服务并删除所有的文件与配置。"
    read -r -p "确认卸载? (y/N): " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        systemctl stop shadowsocks-rust || true
        systemctl disable shadowsocks-rust || true
        rm -f "${SYSTEMD_SERVICE_FILE}"
        systemctl daemon-reload
        
        # [安全警告] 限制范围的 rm 操作
        rm -rf "${SS_CONFIG_DIR}"
        rm -f "${SS_BIN_PATH}"
        
        log_info "Shadowsocks-rust 已彻底卸载。"
    fi
}

#===============================================================================
# 主函数入口
#===============================================================================
show_menu() {
    clear
    echo "=================================================="
    echo " Shadowsocks-rust (SS2022) 一键管理脚本"
    echo "=================================================="
    echo "  1. 安装并配置 (含环境/时间同步/防火墙)"
    echo "  2. 重新配置参数 (修改端口/密码)"
    echo "  3. 卸载服务"
    echo "  4. 退出"
    echo "=================================================="
    read -r -p "请输入序号 [1-4]: " choice

    case "${choice}" in
        1)
            check_env
            setup_time_sync
            install_ss
            ;;
        2)
            if [[ -f "${SS_CONFIG_FILE}" ]]; then
                configure_ss
            else
                log_err "未找到配置文件，请先执行安装！"
            fi
            ;;
        3) uninstall_ss ;;
        4) exit 0 ;;
        *) exit 1 ;;
    esac
}

show_menu
