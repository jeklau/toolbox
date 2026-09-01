#!/usr/bin/env bash
#
# Description: Realm 端口转发一键管理脚本 (健壮生产级)
# Author: Gemini

set -euo pipefail

# 样式与颜色定义
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly PLAIN='\033[0m'

readonly INFO="[${GREEN}INFO${PLAIN}]"
readonly ERROR="[${RED}ERROR${PLAIN}]"
readonly TIP="[${YELLOW}TIP${PLAIN}]"

# 路径常量定义
readonly REALM_BIN="/usr/local/bin/realm"
readonly CONF_DIR="/etc/realm"
readonly CONF_FILE="${CONF_DIR}/config.toml"
readonly SERVICE_FILE="/etc/systemd/system/realm.service"
readonly GITHUB_REPO="zhboner/realm"

# 权限校验
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${ERROR} 请使用 root 用户或通过 sudo 运行此脚本！" >&2
    exit 1
fi

# 工具依赖检查
check_dependencies() {
    local deps=("curl" "tar" "grep" "sed" "systemctl")
    for cmd in "${deps[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            echo -e "${ERROR} 缺少依赖命令: ${cmd}，请先使用包管理器安装！" >&2
            exit 1
        fi
    done
}

# 架构检测
get_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)  echo "x86_64-unknown-linux-gnu" ;;
        aarch64) echo "aarch64-unknown-linux-gnu" ;;
        armv7*)  echo "armv7-unknown-linux-gnueabihf" ;;
        *)       echo "" ;;
    esac
}

# 端口合法性校验 (1-65535)
validate_port() {
    local port="$1"
    if [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 初始化配置目录与默认配置
init_env() {
    [[ ! -d "${CONF_DIR}" ]] && mkdir -p "${CONF_DIR}"
    if [[ ! -f "${CONF_FILE}" ]]; then
        cat > "${CONF_FILE}" <<EOF
[network]
no_delay = true
keepalive = 30
EOF
    fi
}

# 安装 Realm 核心程序
install_realm() {
    if [[ -x "${REALM_BIN}" ]]; then
        echo -e "${TIP} Realm 已经安装于 ${REALM_BIN}，无需重复安装。"
        return 0
    fi

    local suffix
    suffix="$(get_arch)"
    if [[ -z "${suffix}" ]]; then
        echo -e "${ERROR} 暂不支持当前 CPU 架构 ($(uname -m))！" >&2
        return 1
    fi

    echo -e "${INFO} 正在解析 Realm 最新版本..."
    local latest_version
    latest_version="$(curl -sSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
    
    if [[ -z "${latest_version}" ]]; then
        latest_version="v2.6.0"
        echo -e "${TIP} 获取最新版本失败，使用兜底版本: ${latest_version}"
    fi

    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${latest_version}/realm-${suffix}.tar.gz"
    echo -e "${INFO} 正在下载: ${download_url} ..."

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # 退出或中断时自动清理临时目录
    trap 'rm -rf "${tmp_dir}"' EXIT

    if ! curl -sSL "${download_url}" -o "${tmp_dir}/realm.tar.gz"; then
        echo -e "${ERROR} 下载失败，请检查服务器网络连接。" >&2
        return 1
    fi

    tar -zxf "${tmp_dir}/realm.tar.gz" -C "${tmp_dir}/"
    install -m 755 "${tmp_dir}/realm" "${REALM_BIN}"

    init_env

    # 注册 systemd 服务
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Realm Performance Forwarder
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONF_DIR}
ExecStart=${REALM_BIN} -c ${CONF_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1
    systemctl restart realm
    echo -e "${GREEN}Realm ${latest_version} 安装并配置服务成功！${PLAIN}"
}

# 添加转发规则
add_rule() {
    init_env
    echo -e "${INFO} === 添加端口转发规则 ==="
    
    # 本地监听配置
    read -r -p "请输入本地监听 IP (默认 0.0.0.0): " listen_ip
    listen_ip="${listen_ip:-0.0.0.0}"

    read -r -p "请输入本地监听端口 (1-65535): " listen_port
    if ! validate_port "${listen_port}"; then
        echo -e "${ERROR} 无效的本地端口: ${listen_port}"
        return 1
    fi

    # 远程目标配置
    read -r -p "请输入远程目标 IP / 域名: " remote_ip
    if [[ -z "${remote_ip}" ]]; then
        echo -e "${ERROR} 远程地址不能为空！"
        return 1
    fi

    read -r -p "请输入远程目标端口 (1-65535): " remote_port
    if ! validate_port "${remote_port}"; then
        echo -e "${ERROR} 无效的远程端口: ${remote_port}"
        return 1
    fi

    # 检查本地端口是否在配置中冲突
    if grep -q "listen = \"${listen_ip}:${listen_port}\"" "${CONF_FILE}" 2>/dev/null; then
        echo -e "${ERROR} 规则已存在，本地地址 [${listen_ip}:${listen_port}] 已被配置！"
        return 1
    fi

    # 写入配置
    cat >> "${CONF_FILE}" <<EOF

[[endpoints]]
listen = "${listen_ip}:${listen_port}"
remote = "${remote_ip}:${remote_port}"
EOF

    systemctl restart realm
    echo -e "${GREEN}转发规则添加成功: [${listen_ip}:${listen_port}] -> [${remote_ip}:${remote_port}]${PLAIN}"
}

# 查看现有规则
list_rules() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        echo -e "${ERROR} 配置文件不存在。"
        return 1
    fi

    echo -e "\n${YELLOW}====================== 当前 Realm 转发规则 ======================${PLAIN}"
    awk '
        BEGIN { count=0; printf "%-6s %-25s %-25s\n", "序号", "本地监听 (Listen)", "远程目标 (Remote)" }
        /listen =/ { gsub(/["listen =]/, ""); l=$0 }
        /remote =/ { gsub(/["remote =]/, ""); r=$0; count++; printf "%-6d %-25s %-25s\n", count, l, r }
        END { if (count == 0) print "暂无有效转发规则。" }
    ' "${CONF_FILE}"
    echo -e "${YELLOW}=================================================================${PLAIN}\n"
}

# 清空所有规则
clear_rules() {
    echo -e "${TIP} 此操作将重置并清空所有转发规则！"
    read -r -p "确定清空规则吗？(y/N): " confirm
    if [[ "${confirm}" =~ ^[yY]$ ]]; then
        cat > "${CONF_FILE}" <<EOF
[network]
no_delay = true
keepalive = 30
EOF
        systemctl restart realm
        echo -e "${GREEN}所有转发规则已清空并重置。${PLAIN}"
    else
        echo -e "${INFO} 操作已取消。"
    fi
}

# 彻底卸载
uninstall_realm() {
    echo -e "${TIP} 即将完全卸载 Realm 及其所有配置！"
    read -r -p "确定要继续吗？(y/N): " confirm
    if [[ "${confirm}" =~ ^[yY]$ ]]; then
        systemctl stop realm 2>/dev/null || true
        systemctl disable realm 2>/dev/null || true
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        rm -rf "${CONF_DIR}"
        rm -f "${REALM_BIN}"
        echo -e "${GREEN}Realm 已彻底从系统中清除！${PLAIN}"
    else
        echo -e "${INFO} 卸载已取消。"
    fi
}

# 主程序入口与交互循环
main() {
    check_dependencies

    while true; do
        echo -e "${GREEN}=== Realm 端口转发管理面板 ===${PLAIN}"
        echo -e " 1. 安装 / 检查 Realm 环境"
        echo -e " 2. 添加 转发规则 (支持本地/远程 IP 及端口)"
        echo -e " 3. 查看 现有转发规则"
        echo -e " 4. 清空 所有转发规则"
        echo -e " 5. 重启 Realm 核心服务"
        echo -e " 6. 卸载 Realm"
        echo -e " 0. 退出"
        echo -e "=============================="
        read -r -p "请输入对应选项 [0-6]: " choice

        case "${choice}" in
            1) install_realm ;;
            2) add_rule ;;
            3) list_rules ;;
            4) clear_rules ;;
            5) 
                systemctl restart realm
                echo -e "${GREEN}Realm 服务已成功重启！${PLAIN}"
                ;;
            6) 
                uninstall_realm
                exit 0 
                ;;
            0) 
                echo -e "${INFO} 退出管理脚本。"
                exit 0 
                ;;
            *) 
                echo -e "${ERROR} 输入错误，请输入数字 0-6！" 
                ;;
        esac
        echo ""
    done
}

main "$@"
