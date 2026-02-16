#!/usr/bin/env bash
#===============================================================================
#          FILE: nft_forward_manager.sh
#         USAGE: sudo ./nft_forward_manager.sh
#   DESCRIPTION: 交互式管理 nftables 端口转发 (支持 IPv4/IPv6 及一键清理)
#        AUTHOR: Linux Shell Script Architect
#  REQUIREMENTS: bash, nftables, systemd, iproute2
#         NOTES: 遵循 Google Shell Style Guide, 严格模式运行
#===============================================================================

# 启用严格模式：遇到错误退出，未定义变量退出，管道中任何命令失败退出
set -euo pipefail

# 全局变量定义
readonly SYSCTL_CONF="/etc/sysctl.d/99-custom-forward-bbr.conf"
readonly NFT_CONF="/etc/nftables.conf"
# 使用 inet 簇可同时兼容处理 ipv4 和 ipv6 流量
readonly TABLE_NAME="port_forward"

# 颜色宏
readonly COLOR_INFO='\033[0;32m'
readonly COLOR_WARN='\033[0;33m'
readonly COLOR_ERR='\033[0;31m'
readonly COLOR_MENU='\033[0;36m'
readonly COLOR_RESET='\033[0m'

# 日志输出函数
log_info() { echo -e "${COLOR_INFO}[INFO] $1${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARN}[WARN] $1${COLOR_RESET}"; }
log_err()  { echo -e "${COLOR_ERR}[ERROR] $1${COLOR_RESET}"; >&2; }

# 环境前置检查
check_env() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "本脚本需要 root 权限运行，请使用 sudo 执行。"
        exit 1
    fi

    if ! command -v nft >/dev/null 2>&1; then
        log_warn "未检测到 nftables，正在尝试安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y nftables
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nftables
        else
            log_err "无法自动安装 nftables，请手动安装后重试。"
            exit 1
        fi
    fi
}

# 验证输入格式
validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && [[ "${port}" -ge 1 ]] && [[ "${port}" -le 65535 ]]
}

validate_ipv4() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validate_ipv6() {
    local ip="$1"
    # 简单的 IPv6 格式基础校验（包含至少两个冒号，且字符合法）
    [[ "${ip}" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]
}

# 检测并配置内核参数 (双栈 IP 转发与 BBR)
setup_kernel_params() {
    log_info "检测内核网络参数 (IPv4/IPv6 Forwarding & BBR)..."
    local reload_sysctl=0

    # IPv4 转发
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
        echo "net.ipv4.ip_forward = 1" >> "${SYSCTL_CONF}"
        reload_sysctl=1
    fi

    # IPv6 转发
    if [[ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" != "1" ]]; then
        echo "net.ipv6.conf.all.forwarding = 1" >> "${SYSCTL_CONF}"
        reload_sysctl=1
    fi

    # BBR 拥塞控制
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" != "bbr" ]]; then
        echo "net.core.default_qdisc = fq" >> "${SYSCTL_CONF}"
        echo "net.ipv4.tcp_congestion_control = bbr" >> "${SYSCTL_CONF}"
        reload_sysctl=1
    fi

    if [[ "${reload_sysctl}" -eq 1 ]]; then
        # 排序并去重配置文件，防止重复追加
        sort -u "${SYSCTL_CONF}" -o "${SYSCTL_CONF}"
        sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
        log_info "内核参数已更新生效。"
    fi
}

# 初始化 nftables 基础表与链 (使用 inet 双栈簇)
init_nftables_table() {
    nft list table inet "${TABLE_NAME}" >/dev/null 2>&1 || nft add table inet "${TABLE_NAME}"
    
    nft list chain inet "${TABLE_NAME}" prerouting >/dev/null 2>&1 || \
        nft add chain inet "${TABLE_NAME}" prerouting "{ type nat hook prerouting priority dstnat; policy accept; }"
    
    nft list chain inet "${TABLE_NAME}" postrouting >/dev/null 2>&1 || \
        nft add chain inet "${TABLE_NAME}" postrouting "{ type nat hook postrouting priority srcnat; policy accept; }"
}

# 添加转发规则核心函数
add_forward_rule() {
    local ip_version="$1"
    local local_port remote_ip remote_port

    # 1. 获取本地端口
    while true; do
        read -r -p "请输入本地监听端口 [1-65535]: " local_port
        if validate_port "${local_port}"; then break; fi
        log_err "无效的端口号，请重新输入。"
    done

    # 2. 获取远程 IP
    while true; do
        read -r -p "请输入远程目标 ${ip_version} 地址: " remote_ip
        if [[ "${ip_version}" == "IPv4" ]] && validate_ipv4 "${remote_ip}"; then break; fi
        if [[ "${ip_version}" == "IPv6" ]] && validate_ipv6 "${remote_ip}"; then break; fi
        log_err "无效的 ${ip_version} 地址格式，请重新输入。"
    done

    # 3. 获取远程端口
    while true; do
        read -r -p "请输入远程目标端口 [回车默认同本地端口 ${local_port}]: " remote_port
        remote_port="${remote_port:-${local_port}}"
        if validate_port "${remote_port}"; then break; fi
        log_err "无效的端口号，请重新输入。"
    done

    # 初始化表结构
    init_nftables_table

    log_info "正在写入 ${ip_version} 转发规则..."
    if [[ "${ip_version}" == "IPv4" ]]; then
        # IPv4 规则注入
        nft add rule inet "${TABLE_NAME}" prerouting meta nfproto ipv4 tcp dport "${local_port}" dnat ip to "${remote_ip}:${remote_port}"
        nft add rule inet "${TABLE_NAME}" prerouting meta nfproto ipv4 udp dport "${local_port}" dnat ip to "${remote_ip}:${remote_port}"
        nft add rule inet "${TABLE_NAME}" postrouting meta nfproto ipv4 ip daddr "${remote_ip}" tcp dport "${remote_port}" masquerade
        nft add rule inet "${TABLE_NAME}" postrouting meta nfproto ipv4 ip daddr "${remote_ip}" udp dport "${remote_port}" masquerade
    else
        # IPv6 规则注入 (注意 IPv6 地址在 dnat to 语法中需加中括号)
        nft add rule inet "${TABLE_NAME}" prerouting meta nfproto ipv6 tcp dport "${local_port}" dnat ip6 to "[${remote_ip}]:${remote_port}"
        nft add rule inet "${TABLE_NAME}" prerouting meta nfproto ipv6 udp dport "${local_port}" dnat ip6 to "[${remote_ip}]:${remote_port}"
        nft add rule inet "${TABLE_NAME}" postrouting meta nfproto ipv6 ip6 daddr "${remote_ip}" tcp dport "${remote_port}" masquerade
        nft add rule inet "${TABLE_NAME}" postrouting meta nfproto ipv6 ip6 daddr "${remote_ip}" udp dport "${remote_port}" masquerade
    fi

    persist_and_enable
    show_ruleset
}

# 清除所有转发规则
clear_all_rules() {
    log_warn "此操作将清除本脚本创建的所有转发规则 (IPv4 & IPv6)！"
    read -r -p "确认清除吗？[y/N]: " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        if nft list table inet "${TABLE_NAME}" >/dev/null 2>&1; then
            nft delete table inet "${TABLE_NAME}"
            log_info "内存中的转发规则已清除。"
            persist_and_enable
        else
            log_info "未检测到现存的转发规则表，无需清除。"
        fi
    else
        log_info "已取消清除操作。"
    fi
}

# 持久化并设置开机启动
persist_and_enable() {
    log_info "正在同步规则至配置文件并设置开机自启..."
    if [[ -f "${NFT_CONF}" ]]; then
        cp "${NFT_CONF}" "${NFT_CONF}.bak_$(date +%F_%T)"
    fi
    nft list ruleset > "${NFT_CONF}"
    systemctl enable nftables >/dev/null 2>&1
    systemctl restart nftables >/dev/null 2>&1
    log_info "规则状态已持久化。"
}

# 展示当前规则集
show_ruleset() {
    echo -e "\n${COLOR_MENU}=== 当前系统 Nftables 规则集状态 ===${COLOR_RESET}"
    nft list ruleset
    echo -e "${COLOR_MENU}====================================${COLOR_RESET}\n"
}

# 交互式菜单主循环
main_menu() {
    check_env
    setup_kernel_params

    while true; do
        echo -e "\n${COLOR_MENU}=== Nftables 端口转发管理脚本 ===${COLOR_RESET}"
        echo "1. 添加 IPv4 端口转发"
        echo "2. 添加 IPv6 端口转发"
        echo "3. 一键清除所有转发规则"
        echo "4. 查看当前转发规则"
        echo "0. 退出脚本"
        echo -e "${COLOR_MENU}=================================${COLOR_RESET}"
        read -r -p "请输入选项 [0-4]: " choice

        case "${choice}" in
            1) add_forward_rule "IPv4" ;;
            2) add_forward_rule "IPv6" ;;
            3) clear_all_rules ;;
            4) show_ruleset ;;
            0) log_info "退出脚本。"; exit 0 ;;
            *) log_err "无效选项，请重新输入。" ;;
        esac
    done
}

# 脚本入口
main_menu "$@"
