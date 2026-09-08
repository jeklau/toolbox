#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Realm 一键转发管理脚本
#
# 支持：
#   - Realm 自动安装 / 修复
#   - Realm 在线升级
#   - IPv4 / IPv6 / 域名
#   - 自定义本地监听 IP 和端口
#   - 自定义远程 IP / 域名
#   - 远程端口留空时默认使用本地监听端口
#   - TCP
#   - UDP
#   - TCP + UDP
#   - 查看规则
#   - 删除指定规则
#   - 清空全部规则
#   - 查看服务状态和错误日志
#   - 配置修改失败自动回滚
#   - Realm 升级失败自动回滚
#
# Realm:
#   https://github.com/zhboner/realm
# ============================================================


# ============================================================
# 颜色
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

INFO="[${GREEN}INFO${PLAIN}]"
ERROR="[${RED}ERROR${PLAIN}]"
TIP="[${YELLOW}TIP${PLAIN}]"


# ============================================================
# Realm 路径
# ============================================================

REALM_BIN="/usr/local/bin/realm"

CONF_DIR="/etc/realm"
CONF_FILE="${CONF_DIR}/config.toml"

SERVICE_FILE="/etc/systemd/system/realm.service"

REALM_REPO="zhboner/realm"

GITHUB_API="https://api.github.com/repos/${REALM_REPO}/releases/latest"
GITHUB_RELEASE="https://github.com/${REALM_REPO}/releases/latest"


# ============================================================
# 协议选择结果
# ============================================================

RULE_PROTOCOL=""
RULE_NO_TCP=""
RULE_USE_UDP=""


# ============================================================
# 日志
# ============================================================

log_info() {
    printf '%b\n' "${INFO} $*"
}


log_error() {
    printf '%b\n' "${ERROR} $*"
}


log_tip() {
    printf '%b\n' "${TIP} $*"
}


# ============================================================
# Root 权限
# ============================================================

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本！"
        exit 1
    fi
}


# ============================================================
# 命令检测
# ============================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}


check_dependencies() {
    local command_name
    local missing=()

    for command_name in \
        curl \
        tar \
        systemctl \
        awk \
        sed \
        grep \
        find \
        install \
        mktemp \
        cp \
        mv \
        rm \
        date \
        head; do

        if ! command_exists "${command_name}"; then
            missing+=("${command_name}")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_error "缺少必要命令：${missing[*]}"

        echo
        log_tip "Debian / Ubuntu："
        echo "apt update && apt install -y curl tar"

        echo
        log_tip "CentOS / Rocky / AlmaLinux："
        echo "dnf install -y curl tar"

        return 1
    fi

    return 0
}


# ============================================================
# Realm 状态检测
# ============================================================

realm_installed() {
    [[ -x "${REALM_BIN}" ]]
}


service_exists() {
    [[ -f "${SERVICE_FILE}" ]]
}


# ============================================================
# CPU 架构
# ============================================================

get_arch() {
    local arch

    arch="$(uname -m)"

    case "${arch}" in
        x86_64 | amd64)
            printf '%s\n' "x86_64-unknown-linux-gnu"
            ;;

        aarch64 | arm64)
            printf '%s\n' "aarch64-unknown-linux-gnu"
            ;;

        *)
            return 1
            ;;
    esac
}


# ============================================================
# 端口验证
#
# 参数：
#   $1 = 端口
#
# 返回：
#   0 = 合法
#   1 = 非法
# ============================================================

validate_port() {
    local port="$1"

    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if ((port < 1 || port > 65535)); then
        return 1
    fi

    return 0
}


# ============================================================
# 地址规范化
# ============================================================

normalize_host() {
    local host="$1"

    # 去掉用户手动输入的 IPv6 []
    host="${host#\[}"
    host="${host%\]}"

    if [[ -z "${host}" ]]; then
        return 1
    fi

    # 禁止输入 URL
    if [[ "${host}" == *"://"* ]]; then
        return 1
    fi

    # 禁止路径、引号、空白
    if [[ "${host}" =~ [[:space:]\"\'/] ]]; then
        return 1
    fi

    # 基础合法字符检查
    if [[ ! "${host}" =~ ^[A-Za-z0-9._:%-]+$ ]]; then
        return 1
    fi

    # 如果只有一个冒号，一般意味着用户误输入了：
    #
    # example.com:443
    #
    # 本脚本要求地址和端口分开输入。
    #
    # IPv6 正常情况下会包含多个冒号。
    if [[ "${host}" == *:* && "${host}" != *:*:* ]]; then
        return 1
    fi

    printf '%s\n' "${host}"
}


# ============================================================
# IPv4 / IPv6 格式化
#
# IPv4:
#   1.2.3.4
#
# IPv6:
#   240e::1
#
# 转换为：
#   [240e::1]
# ============================================================

format_address() {
    local input="$1"
    local address

    if ! address="$(normalize_host "${input}")"; then
        return 1
    fi

    if [[ "${address}" == *:* ]]; then
        printf '[%s]' "${address}"
    else
        printf '%s' "${address}"
    fi
}


# ============================================================
# 默认 Realm 配置
#
# Realm v2.9.6：
# 即使没有规则，也必须存在 endpoints 字段。
# ============================================================

write_default_config() {
    cat >"${CONF_FILE}" <<'EOF'
endpoints = []

[network]
no_tcp = false
use_udp = false
EOF

    chmod 0644 "${CONF_FILE}"
}


# ============================================================
# 获取转发规则数量
# ============================================================

get_rule_count() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        printf '0\n'
        return
    fi

    grep -c \
        '^[[:space:]]*\[\[endpoints\]\][[:space:]]*$' \
        "${CONF_FILE}" 2>/dev/null || true
}


# ============================================================
# 检查：
#
# endpoints = []
# ============================================================

has_empty_endpoints() {
    if [[ ! -f "${CONF_FILE}" ]]; then
        return 1
    fi

    grep -Eq \
        '^[[:space:]]*endpoints[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*$' \
        "${CONF_FILE}"
}


# ============================================================
# 无规则时确保：
#
# endpoints = []
# ============================================================

ensure_empty_endpoints() {
    local rule_count
    local tmp_file

    if [[ ! -f "${CONF_FILE}" ]]; then
        return 1
    fi

    rule_count="$(get_rule_count)"

    if ((rule_count > 0)); then
        return 0
    fi

    if has_empty_endpoints; then
        return 0
    fi

    tmp_file="$(
        mktemp "${CONF_DIR}/.config.toml.XXXXXX"
    )"

    {
        printf 'endpoints = []\n\n'
        cat "${CONF_FILE}"
    } >"${tmp_file}"

    chmod 0644 "${tmp_file}"

    mv -f "${tmp_file}" "${CONF_FILE}"
}


# ============================================================
# 添加第一条规则之前移除：
#
# endpoints = []
#
# 防止和 [[endpoints]] 重复定义。
# ============================================================

remove_empty_endpoints() {
    local tmp_file

    if [[ ! -f "${CONF_FILE}" ]]; then
        return 1
    fi

    if ! has_empty_endpoints; then
        return 0
    fi

    tmp_file="$(
        mktemp "${CONF_DIR}/.config.toml.XXXXXX"
    )"

    awk '
        !/^[[:space:]]*endpoints[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*$/
    ' "${CONF_FILE}" >"${tmp_file}"

    chmod 0644 "${tmp_file}"

    mv -f "${tmp_file}" "${CONF_FILE}"
}


# ============================================================
# 自动修复 endpoints 字段
# ============================================================

repair_endpoints_field() {
    local rule_count

    rule_count="$(get_rule_count)"

    if ((rule_count > 0)); then
        remove_empty_endpoints
    else
        ensure_empty_endpoints
    fi
}


# ============================================================
# 初始化配置
# ============================================================

init_env() {
    mkdir -p "${CONF_DIR}"

    if [[ ! -f "${CONF_FILE}" ]]; then
        write_default_config
        return
    fi

    repair_endpoints_field
}


# ============================================================
# 配置备份
#
# stdout：
#   返回备份文件路径
# ============================================================

backup_config() {
    local backup_file

    backup_file="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S).$$"

    if ! cp -a "${CONF_FILE}" "${backup_file}"; then
        return 1
    fi

    printf '%s\n' "${backup_file}"
}


# ============================================================
# Systemd
# ============================================================

write_service_file() {
    cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=Realm TCP/UDP Forwarder
Documentation=https://github.com/${REALM_REPO}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=${CONF_DIR}
ExecStart=${REALM_BIN} -c ${CONF_FILE}

Restart=on-failure
RestartSec=3

LimitNOFILE=1048576

Environment=RUST_BACKTRACE=1

[Install]
WantedBy=multi-user.target
EOF
}


# ============================================================
# Realm 最近日志
# ============================================================

show_recent_logs() {
    echo

    printf '%b\n' \
        "${YELLOW}================ Realm 最近日志 ================${PLAIN}"

    journalctl \
        -u realm \
        -n 30 \
        --no-pager \
        -o cat 2>/dev/null || true

    printf '%b\n' \
        "${YELLOW}=================================================${PLAIN}"

    echo
}


# ============================================================
# Realm 重启并检测
# ============================================================

restart_realm_checked() {
    systemctl reset-failed realm 2>/dev/null || true

    if ! systemctl restart realm; then
        log_error "systemd 无法启动 Realm。"

        show_recent_logs

        return 1
    fi

    sleep 1

    if ! systemctl is-active --quiet realm; then
        log_error "Realm 启动后立即退出。"

        show_recent_logs

        return 1
    fi

    sleep 1

    if ! systemctl is-active --quiet realm; then
        log_error "Realm 启动后运行异常。"

        show_recent_logs

        return 1
    fi

    return 0
}


# ============================================================
# 当前 Realm 版本
# ============================================================

get_current_version() {
    local output

    if ! realm_installed; then
        printf '%s\n' "unknown"
        return
    fi

    output="$(
        "${REALM_BIN}" --version 2>/dev/null ||
            true
    )"

    if [[ "${output}" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        printf 'v%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "unknown"
    fi
}


# ============================================================
# 获取 GitHub 最新 Realm 版本
# ============================================================

get_latest_version() {
    local api_response=""
    local latest_version=""
    local effective_url=""

    # --------------------------------------------------------
    # 优先使用 GitHub API
    # --------------------------------------------------------

    if api_response="$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --connect-timeout 10 \
            --max-time 30 \
            -H "Accept: application/vnd.github+json" \
            -H "User-Agent: realm-manager-script" \
            "${GITHUB_API}"
    )"; then

        latest_version="$(
            printf '%s\n' "${api_response}" |
                sed -nE \
                    's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' |
                head -n 1
        )"
    fi

    # --------------------------------------------------------
    # GitHub API 失败时获取 releases/latest 重定向
    # --------------------------------------------------------

    if [[ -z "${latest_version}" ]]; then

        if effective_url="$(
            curl \
                --silent \
                --show-error \
                --location \
                --connect-timeout 10 \
                --max-time 30 \
                --output /dev/null \
                --write-out '%{url_effective}' \
                "${GITHUB_RELEASE}"
        )"; then

            latest_version="${effective_url##*/}"

            if [[ "${latest_version}" == "latest" ]]; then
                latest_version=""
            fi
        fi
    fi

    if [[ -z "${latest_version}" ]]; then
        return 1
    fi

    printf '%s\n' "${latest_version}"
}


# ============================================================
# 下载 Realm Release
#
# 参数：
#   $1 = Realm 版本
#   $2 = 临时目录
#
# stdout：
#   Realm 二进制路径
# ============================================================

download_realm_release() {
    local version="$1"
    local tmp_dir="$2"

    local suffix
    local archive
    local download_url
    local extracted_realm

    if ! suffix="$(get_arch)"; then
        log_error "不支持 CPU 架构：$(uname -m)" >&2
        return 1
    fi

    archive="${tmp_dir}/realm.tar.gz"

    download_url="https://github.com/${REALM_REPO}/releases/download/${version}/realm-${suffix}.tar.gz"

    printf '%b\n' \
        "${INFO} 下载地址：${download_url}" >&2

    if ! curl \
        --fail \
        --location \
        --show-error \
        --connect-timeout 15 \
        --retry 3 \
        --output "${archive}" \
        "${download_url}"; then

        log_error "Realm 下载失败。" >&2

        return 1
    fi

    # --------------------------------------------------------
    # 压缩包完整性检测
    # --------------------------------------------------------

    if ! tar -tzf "${archive}" >/dev/null 2>&1; then
        log_error "下载文件不是有效 tar.gz 压缩包。" >&2
        return 1
    fi

    if ! tar -xzf \
        "${archive}" \
        -C "${tmp_dir}"; then

        log_error "Realm 解压失败。" >&2

        return 1
    fi

    extracted_realm="$(
        find "${tmp_dir}" \
            -maxdepth 3 \
            -type f \
            -name realm \
            -print \
            -quit
    )"

    if [[ -z "${extracted_realm}" ]]; then
        log_error "压缩包中未找到 Realm 二进制。" >&2
        return 1
    fi

    chmod +x "${extracted_realm}"

    # --------------------------------------------------------
    # 检测新二进制是否能正常执行
    # --------------------------------------------------------

    if ! "${extracted_realm}" \
        --version >/dev/null 2>&1; then

        log_error "下载的 Realm 二进制无法执行。" >&2

        return 1
    fi

    printf '%s\n' "${extracted_realm}"
}


# ============================================================
# 安装 / 修复 Realm
# ============================================================

install_realm() {
    local latest_version
    local tmp_dir
    local realm_file
    local rule_count

    if ! check_dependencies; then
        return
    fi

    # --------------------------------------------------------
    # 已经安装 Realm
    #
    # 执行配置和 systemd 修复
    # --------------------------------------------------------

    if realm_installed; then

        log_tip "Realm 已安装，正在检查配置及服务..."

        init_env
        write_service_file

        systemctl daemon-reload

        if ! systemctl enable realm >/dev/null 2>&1; then
            log_error "无法启用 Realm systemd 服务。"
            return
        fi

        rule_count="$(get_rule_count)"

        if ((rule_count > 0)); then

            if restart_realm_checked; then
                log_info "Realm 服务已修复并启动。"
            else
                log_error "Realm 服务启动失败。"
                return
            fi

        else

            systemctl stop realm 2>/dev/null || true

            log_info "Realm 配置已修复。"
            log_tip "当前没有转发规则，Realm 保持停止状态。"
        fi

        echo
        log_info "当前版本：$(get_current_version)"

        return
    fi

    # --------------------------------------------------------
    # 全新安装
    # --------------------------------------------------------

    if ! get_arch >/dev/null; then
        log_error "不支持 CPU 架构：$(uname -m)"
        return
    fi

    log_info "正在获取 Realm 最新版本..."

    if ! latest_version="$(get_latest_version)"; then
        log_error "无法获取 Realm 最新版本。"
        log_tip "请检查服务器是否可以连接 GitHub。"
        return
    fi

    log_info "最新版本：${latest_version}"

    tmp_dir="$(mktemp -d)"

    if ! realm_file="$(
        download_realm_release \
            "${latest_version}" \
            "${tmp_dir}"
    )"; then

        rm -rf -- "${tmp_dir}"
        return
    fi

    log_info "正在安装 Realm..."

    if ! install \
        -m 0755 \
        "${realm_file}" \
        "${REALM_BIN}"; then

        log_error "Realm 安装失败。"

        rm -rf -- "${tmp_dir}"

        return
    fi

    rm -rf -- "${tmp_dir}"

    init_env
    write_service_file

    systemctl daemon-reload

    if ! systemctl enable realm >/dev/null 2>&1; then
        log_error "无法启用 Realm 服务。"
        return
    fi

    rule_count="$(get_rule_count)"

    if ((rule_count > 0)); then

        if ! restart_realm_checked; then
            log_error "Realm 服务启动失败。"
            return
        fi

        log_info "Realm 已安装并启动。"

    else

        systemctl stop realm 2>/dev/null || true

        log_info "Realm 安装成功。"
        log_tip "当前没有转发规则。"
        log_tip "添加第一条规则后 Realm 自动启动。"
    fi

    echo

    log_info "版本：$(get_current_version)"
    log_info "程序：${REALM_BIN}"
    log_info "配置：${CONF_FILE}"
}


# ============================================================
# 协议选择
# ============================================================

select_protocol() {
    local protocol_choice

    echo
    printf '%b\n' "${BLUE}请选择转发协议：${PLAIN}"
    echo

    echo "  1. TCP"
    echo "  2. UDP"
    echo "  3. TCP + UDP"

    echo

    read -r \
        -p "请选择协议 [1-3，默认 3]: " \
        protocol_choice

    protocol_choice="${protocol_choice:-3}"

    case "${protocol_choice}" in
        1)
            RULE_PROTOCOL="TCP"
            RULE_NO_TCP="false"
            RULE_USE_UDP="false"
            ;;

        2)
            RULE_PROTOCOL="UDP"
            RULE_NO_TCP="true"
            RULE_USE_UDP="true"
            ;;

        3)
            RULE_PROTOCOL="TCP+UDP"
            RULE_NO_TCP="false"
            RULE_USE_UDP="true"
            ;;

        *)
            log_error "无效协议选项。"
            return 1
            ;;
    esac
}


# ============================================================
# 添加转发规则
# ============================================================

add_rule() {
    local listen_addr
    local listen_port

    local remote_addr
    local remote_port

    local formatted_listen
    local formatted_remote

    local confirm
    local backup_file
    local old_rule_count

    if ! realm_installed; then
        log_error "Realm 尚未安装，请先执行菜单 1。"
        return
    fi

    init_env

    # --------------------------------------------------------
    # 自动修复 systemd 服务
    # --------------------------------------------------------

    if ! service_exists; then
        log_tip "Realm systemd 服务不存在，正在创建..."

        write_service_file

        systemctl daemon-reload
        systemctl enable realm >/dev/null 2>&1 || true
    fi

    echo

    printf '%b\n' \
        "${BLUE}===========================================${PLAIN}"

    printf '%b\n' \
        "${BLUE}           添加 Realm 转发规则${PLAIN}"

    printf '%b\n' \
        "${BLUE}===========================================${PLAIN}"

    echo

    # --------------------------------------------------------
    # 本地 IP
    # --------------------------------------------------------

    read -r \
        -p "请输入本地监听 IP [默认 0.0.0.0]: " \
        listen_addr

    listen_addr="${listen_addr:-0.0.0.0}"

    if ! formatted_listen="$(
        format_address "${listen_addr}"
    )"; then

        log_error "本地监听 IP 格式不正确。"

        return
    fi

    # --------------------------------------------------------
    # 本地端口
    # --------------------------------------------------------

    read -r \
        -p "请输入本地监听端口: " \
        listen_port

    if ! validate_port "${listen_port}"; then
        log_error "本地端口必须为 1-65535。"
        return
    fi

    # --------------------------------------------------------
    # 远程地址
    # --------------------------------------------------------

    read -r \
        -p "请输入远程 IP / DDNS / 域名: " \
        remote_addr

    if ! formatted_remote="$(
        format_address "${remote_addr}"
    )"; then

        log_error "远程 IP / 域名格式不正确。"
        log_tip "只输入 IP 或域名，不要包含 http://、https:// 或端口。"

        return
    fi

    # --------------------------------------------------------
    # 远程端口
    #
    # 留空：
    #   自动使用本地监听端口
    #
    # 例如：
    #
    #   本地 5000
    #   远程端口直接回车
    #
    # 最终：
    #
    #   0.0.0.0:5000 -> remote:5000
    # --------------------------------------------------------

    read -r \
        -p "请输入远程端口 [默认 ${listen_port}]: " \
        remote_port

    remote_port="${remote_port:-${listen_port}}"

    if ! validate_port "${remote_port}"; then
        log_error "远程端口必须为 1-65535。"
        return
    fi

    # --------------------------------------------------------
    # 协议
    # --------------------------------------------------------

    if ! select_protocol; then
        return
    fi

    # --------------------------------------------------------
    # 最终确认
    # --------------------------------------------------------

    echo

    printf '%b\n' \
        "${YELLOW}即将添加转发规则：${PLAIN}"

    echo

    printf '  协议：%s\n' \
        "${RULE_PROTOCOL}"

    echo

    printf '  本地：%s:%s\n' \
        "${formatted_listen}" \
        "${listen_port}"

    echo "             ↓"

    printf '  远程：%s:%s\n' \
        "${formatted_remote}" \
        "${remote_port}"

    # 显示是否为同端口转发
    if [[ "${listen_port}" == "${remote_port}" ]]; then
        echo
        log_tip "远程端口未单独指定，使用本地端口 ${listen_port}。"
    fi

    echo

    read -r \
        -p "确认添加？[Y/n]: " \
        confirm

    confirm="${confirm:-y}"

    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        log_tip "已取消。"
        return
    fi

    # --------------------------------------------------------
    # 配置备份
    # --------------------------------------------------------

    if ! backup_file="$(backup_config)"; then
        log_error "无法备份 Realm 配置。"
        return
    fi

    old_rule_count="$(get_rule_count)"

    # --------------------------------------------------------
    # 有实际规则时不能同时存在：
    #
    # endpoints = []
    #
    # 所以添加前移除。
    # --------------------------------------------------------

    if ! remove_empty_endpoints; then
        log_error "无法处理 endpoints 配置。"

        rm -f "${backup_file}"

        return
    fi

    # --------------------------------------------------------
    # 写入 Realm endpoint
    # --------------------------------------------------------

    cat >>"${CONF_FILE}" <<EOF

[[endpoints]]
listen = "${formatted_listen}:${listen_port}"
remote = "${formatted_remote}:${remote_port}"
network = { no_tcp = ${RULE_NO_TCP}, use_udp = ${RULE_USE_UDP} }
EOF

    # --------------------------------------------------------
    # 重启 Realm 验证
    # --------------------------------------------------------

    if restart_realm_checked; then

        rm -f "${backup_file}"

        echo

        log_info "转发规则添加成功！"

        echo

        printf '协议：%s\n' \
            "${RULE_PROTOCOL}"

        printf '%s:%s -> %s:%s\n' \
            "${formatted_listen}" \
            "${listen_port}" \
            "${formatted_remote}" \
            "${remote_port}"

        return
    fi

    # --------------------------------------------------------
    # 添加失败自动回滚
    # --------------------------------------------------------

    log_error "新规则导致 Realm 启动失败。"
    log_tip "正在恢复原配置..."

    mv -f "${backup_file}" "${CONF_FILE}"

    if ((old_rule_count > 0)); then
        restart_realm_checked || true
    else
        systemctl stop realm 2>/dev/null || true
    fi

    log_error "新规则已自动回滚。"
}


# ============================================================
# 查看转发规则
#
# 使用 Bash 原生解析。
#
# 避免：
#   mawk
#   gawk
#   busybox awk
#
# 之间的兼容问题。
# ============================================================

list_rules() {
    local rule_count
    local count=0

    local line=""
    local listen=""
    local remote=""
    local protocol=""

    local in_endpoint=0

    if [[ ! -f "${CONF_FILE}" ]]; then
        log_error "Realm 配置文件不存在。"
        return
    fi

    rule_count="$(get_rule_count)"

    echo

    printf '%b\n' \
        "${YELLOW}==================== Realm 转发规则 ====================${PLAIN}"

    if ((rule_count == 0)); then
        echo

        log_tip "当前没有 Realm 转发规则。"

        echo

        return
    fi

    printf "%-6s %-12s %-32s %-3s %-32s\n" \
        "编号" \
        "协议" \
        "本地监听" \
        "" \
        "远程目标"

    echo "------------------------------------------------------------------------------------------"

    # --------------------------------------------------------
    # 输出一条 endpoint
    # --------------------------------------------------------

    print_endpoint_row() {
        if ((in_endpoint == 0)); then
            return
        fi

        ((count += 1))

        printf "%-6s %-12s %-32s %-3s %-32s\n" \
            "${count}" \
            "${protocol}" \
            "${listen}" \
            "→" \
            "${remote}"
    }

    # --------------------------------------------------------
    # Bash 原生读取 TOML
    # --------------------------------------------------------

    while IFS= read -r line || [[ -n "${line}" ]]; do

        # ----------------------------------------------------
        # [[endpoints]]
        # ----------------------------------------------------

        if [[ "${line}" =~ ^[[:space:]]*\[\[endpoints\]\][[:space:]]*$ ]]; then

            if ((in_endpoint == 1)); then
                print_endpoint_row
            fi

            in_endpoint=1

            listen=""
            remote=""
            protocol="继承全局"

            continue
        fi

        if ((in_endpoint == 0)); then
            continue
        fi

        # ----------------------------------------------------
        # listen
        # ----------------------------------------------------

        if [[ "${line}" =~ ^[[:space:]]*listen[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then

            listen="${BASH_REMATCH[1]}"

            continue
        fi

        # ----------------------------------------------------
        # remote
        # ----------------------------------------------------

        if [[ "${line}" =~ ^[[:space:]]*remote[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then

            remote="${BASH_REMATCH[1]}"

            continue
        fi

        # ----------------------------------------------------
        # network
        # ----------------------------------------------------

        if [[ "${line}" =~ ^[[:space:]]*network[[:space:]]*= ]]; then

            if [[ "${line}" =~ no_tcp[[:space:]]*=[[:space:]]*true ]] &&
               [[ "${line}" =~ use_udp[[:space:]]*=[[:space:]]*true ]]; then

                protocol="UDP"

            elif [[ "${line}" =~ no_tcp[[:space:]]*=[[:space:]]*false ]] &&
                 [[ "${line}" =~ use_udp[[:space:]]*=[[:space:]]*true ]]; then

                protocol="TCP+UDP"

            elif [[ "${line}" =~ no_tcp[[:space:]]*=[[:space:]]*false ]] &&
                 [[ "${line}" =~ use_udp[[:space:]]*=[[:space:]]*false ]]; then

                protocol="TCP"

            else
                protocol="自定义"
            fi

            continue
        fi

    done <"${CONF_FILE}"

    # 最后一条 endpoint
    if ((in_endpoint == 1)); then
        print_endpoint_row
    fi

    echo "------------------------------------------------------------------------------------------"

    log_info "当前共 ${count} 条转发规则。"

    echo
}


# ============================================================
# 删除指定规则
# ============================================================

delete_rule() {
    local rule_number
    local total
    local remaining

    local tmp_file
    local backup_file
    local confirm

    if [[ ! -f "${CONF_FILE}" ]]; then
        log_error "Realm 配置文件不存在。"
        return
    fi

    total="$(get_rule_count)"

    if ((total == 0)); then
        log_tip "当前没有可删除的规则。"
        return
    fi

    list_rules

    read -r \
        -p "请输入需要删除的规则编号: " \
        rule_number

    if [[ ! "${rule_number}" =~ ^[0-9]+$ ]]; then
        log_error "请输入正确的数字编号。"
        return
    fi

    if ((rule_number < 1 || rule_number > total)); then
        log_error "规则编号不存在。"
        return
    fi

    read -r \
        -p "确认删除规则 ${rule_number}？[y/N]: " \
        confirm

    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        log_tip "已取消。"
        return
    fi

    tmp_file="$(
        mktemp "${CONF_DIR}/.config.toml.XXXXXX"
    )"

    # --------------------------------------------------------
    # 删除指定 endpoint
    #
    # 使用简单 POSIX Awk，
    # 保证 mawk/gawk 兼容。
    # --------------------------------------------------------

    if ! awk -v target="${rule_number}" '
        BEGIN {
            endpoint = 0
            skip = 0
        }

        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            endpoint++

            if (endpoint == target) {
                skip = 1
                next
            }

            skip = 0
            print
            next
        }

        skip == 1 && /^[[:space:]]*\[/ {
            skip = 0
            print
            next
        }

        skip == 0 {
            print
        }
    ' "${CONF_FILE}" >"${tmp_file}"; then

        log_error "处理 Realm 配置失败。"

        rm -f "${tmp_file}"

        return
    fi

    chmod 0644 "${tmp_file}"

    if ! backup_file="$(backup_config)"; then
        log_error "无法备份 Realm 配置。"

        rm -f "${tmp_file}"

        return
    fi

    mv -f "${tmp_file}" "${CONF_FILE}"

    # --------------------------------------------------------
    # 如果删除的是最后一条规则，
    # 恢复：
    #
    # endpoints = []
    # --------------------------------------------------------

    repair_endpoints_field

    remaining="$(get_rule_count)"

    # --------------------------------------------------------
    # 已无任何规则
    # --------------------------------------------------------

    if ((remaining == 0)); then

        systemctl stop realm 2>/dev/null || true

        rm -f "${backup_file}"

        echo

        log_info "规则 ${rule_number} 删除成功！"

        log_tip "当前已经没有转发规则，Realm 服务已停止。"

        return
    fi

    # --------------------------------------------------------
    # 还有其它规则
    # --------------------------------------------------------

    if restart_realm_checked; then

        rm -f "${backup_file}"

        log_info "规则 ${rule_number} 删除成功！"

        return
    fi

    # --------------------------------------------------------
    # 删除失败，恢复原配置
    # --------------------------------------------------------

    log_error "删除规则后 Realm 启动失败。"
    log_tip "正在恢复原配置..."

    mv -f "${backup_file}" "${CONF_FILE}"

    restart_realm_checked || true

    log_error "删除操作已自动回滚。"
}


# ============================================================
# 清空所有规则
# ============================================================

clear_rules() {
    local total
    local confirm

    local tmp_file
    local backup_file

    if [[ ! -f "${CONF_FILE}" ]]; then
        log_error "Realm 配置文件不存在。"
        return
    fi

    total="$(get_rule_count)"

    if ((total == 0)); then

        repair_endpoints_field

        systemctl stop realm 2>/dev/null || true

        log_tip "当前已经没有 Realm 转发规则。"

        return
    fi

    echo

    printf '%b\n' \
        "${RED}警告：此操作将删除全部 Realm 转发规则！${PLAIN}"

    echo

    read -r \
        -p "请输入 YES 确认清空全部规则: " \
        confirm

    if [[ "${confirm}" != "YES" ]]; then
        log_tip "已取消。"
        return
    fi

    tmp_file="$(
        mktemp "${CONF_DIR}/.config.toml.XXXXXX"
    )"

    # --------------------------------------------------------
    # 删除全部 [[endpoints]]
    # --------------------------------------------------------

    if ! awk '
        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            skip = 1
            next
        }

        skip == 1 && /^[[:space:]]*\[/ {
            skip = 0
            print
            next
        }

        skip == 0 {
            print
        }
    ' "${CONF_FILE}" >"${tmp_file}"; then

        log_error "处理 Realm 配置失败。"

        rm -f "${tmp_file}"

        return
    fi

    chmod 0644 "${tmp_file}"

    if ! backup_file="$(backup_config)"; then
        log_error "无法备份 Realm 配置。"

        rm -f "${tmp_file}"

        return
    fi

    mv -f "${tmp_file}" "${CONF_FILE}"

    repair_endpoints_field

    systemctl stop realm 2>/dev/null || true

    rm -f "${backup_file}"

    echo

    log_info "所有 Realm 转发规则已清空。"

    log_tip "Realm 服务已停止。"
}


# ============================================================
# 查看 Realm 状态
# ============================================================

show_status() {
    local rule_count

    echo

    if ! realm_installed; then
        log_error "Realm 尚未安装。"
        return
    fi

    log_info "Realm 版本：$(get_current_version)"

    if [[ -f "${CONF_FILE}" ]]; then
        rule_count="$(get_rule_count)"
    else
        rule_count="0"
    fi

    log_info "转发规则：${rule_count} 条"

    echo

    if ! service_exists; then
        log_error "Realm systemd 服务不存在。"
        return
    fi

    # --------------------------------------------------------
    # 正常运行
    # --------------------------------------------------------

    if systemctl is-active --quiet realm; then

        printf '%b\n' \
            "${GREEN}● Realm 服务运行正常${PLAIN}"

        echo

        systemctl status \
            realm \
            --no-pager \
            -l || true

        return
    fi

    # --------------------------------------------------------
    # 没规则时停止属于正常
    # --------------------------------------------------------

    if ((rule_count == 0)); then

        printf '%b\n' \
            "${YELLOW}● Realm 当前未运行${PLAIN}"

        echo

        log_tip "当前没有转发规则，因此 Realm 停止属于正常状态。"

        return
    fi

    # --------------------------------------------------------
    # 有规则但没运行
    # --------------------------------------------------------

    printf '%b\n' \
        "${RED}● Realm 服务运行异常${PLAIN}"

    echo

    systemctl status \
        realm \
        --no-pager \
        -l || true

    show_recent_logs
}


# ============================================================
# 重启 Realm
# ============================================================

restart_realm() {
    local rule_count

    if ! realm_installed; then
        log_error "Realm 尚未安装。"
        return
    fi

    if ! service_exists; then
        log_error "Realm systemd 服务不存在。"
        return
    fi

    init_env

    rule_count="$(get_rule_count)"

    if ((rule_count == 0)); then

        systemctl stop realm 2>/dev/null || true

        log_tip "当前没有转发规则，无需启动 Realm。"

        return
    fi

    if restart_realm_checked; then
        log_info "Realm 服务已成功重启。"
    else
        log_error "Realm 服务重启失败。"
    fi
}


# ============================================================
# 在线升级 Realm
# ============================================================

update_realm() {
    local current_version
    local latest_version

    local tmp_dir
    local new_realm

    local backup_file
    local new_binary

    local confirm
    local rule_count

    if ! realm_installed; then
        log_error "Realm 尚未安装。"
        return
    fi

    if ! check_dependencies; then
        return
    fi

    init_env

    echo

    printf '%b\n' \
        "${BLUE}===========================================${PLAIN}"

    printf '%b\n' \
        "${BLUE}             Realm 在线升级${PLAIN}"

    printf '%b\n' \
        "${BLUE}===========================================${PLAIN}"

    echo

    current_version="$(get_current_version)"

    log_info "当前版本：${current_version}"

    log_info "正在查询 GitHub 最新版本..."

    if ! latest_version="$(get_latest_version)"; then
        log_error "获取 Realm 最新版本失败。"
        return
    fi

    log_info "最新版本：${latest_version}"

    # --------------------------------------------------------
    # 已是最新版
    # --------------------------------------------------------

    if [[ "${current_version}" == "${latest_version}" ]]; then

        # 顺便刷新 systemd 配置
        write_service_file

        systemctl daemon-reload

        log_info "当前 Realm 已经是最新版本。"

        return
    fi

    echo

    printf '%b\n' \
        "${YELLOW}检测到不同版本：${PLAIN}"

    echo

    printf '  %s\n' "${current_version}"

    echo "       ↓"

    printf '  %s\n' "${latest_version}"

    echo

    read -r \
        -p "确认升级 Realm？[Y/n]: " \
        confirm

    confirm="${confirm:-y}"

    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        log_tip "已取消升级。"
        return
    fi

    # --------------------------------------------------------
    # 下载新版本
    # --------------------------------------------------------

    tmp_dir="$(mktemp -d)"

    log_info "正在下载 Realm ${latest_version}..."

    if ! new_realm="$(
        download_realm_release \
            "${latest_version}" \
            "${tmp_dir}"
    )"; then

        rm -rf -- "${tmp_dir}"

        return
    fi

    log_info "新版本二进制检测通过。"

    # --------------------------------------------------------
    # 备份旧版本
    # --------------------------------------------------------

    backup_file="${REALM_BIN}.rollback"
    new_binary="${REALM_BIN}.new"

    rm -f "${backup_file}"
    rm -f "${new_binary}"

    if ! cp -a \
        "${REALM_BIN}" \
        "${backup_file}"; then

        log_error "无法备份当前 Realm。"

        rm -rf -- "${tmp_dir}"

        return
    fi

    log_info "旧版本 Realm 已备份。"

    # --------------------------------------------------------
    # 安装新版本到临时文件
    # --------------------------------------------------------

    if ! install \
        -m 0755 \
        "${new_realm}" \
        "${new_binary}"; then

        log_error "新 Realm 二进制写入失败。"

        rm -f "${backup_file}"

        rm -rf -- "${tmp_dir}"

        return
    fi

    # --------------------------------------------------------
    # 同目录原子替换
    # --------------------------------------------------------

    if ! mv -f \
        "${new_binary}" \
        "${REALM_BIN}"; then

        log_error "Realm 二进制替换失败。"

        cp -a \
            "${backup_file}" \
            "${REALM_BIN}"

        rm -f "${backup_file}"

        rm -rf -- "${tmp_dir}"

        return
    fi

    rm -rf -- "${tmp_dir}"

    # --------------------------------------------------------
    # 更新 systemd
    # --------------------------------------------------------

    write_service_file

    systemctl daemon-reload

    systemctl enable realm >/dev/null 2>&1 || true

    rule_count="$(get_rule_count)"

    # --------------------------------------------------------
    # 没有规则则不启动服务
    # --------------------------------------------------------

    if ((rule_count == 0)); then

        systemctl stop realm 2>/dev/null || true

        rm -f "${backup_file}"

        echo

        log_info "Realm 升级成功！"

        log_info "当前版本：$(get_current_version)"

        log_tip "当前没有转发规则，Realm 服务保持停止。"

        return
    fi

    # --------------------------------------------------------
    # 验证新版本
    # --------------------------------------------------------

    log_info "正在启动并验证新版本 Realm..."

    if restart_realm_checked; then

        rm -f "${backup_file}"

        echo

        log_info "Realm 升级成功！"

        log_info "当前版本：$(get_current_version)"

        return
    fi

    # --------------------------------------------------------
    # 新版本失败，自动回滚
    # --------------------------------------------------------

    echo

    log_error "新版本 Realm 启动失败。"

    log_tip "正在自动回滚旧版本..."

    if ! cp -a \
        "${backup_file}" \
        "${REALM_BIN}"; then

        log_error "Realm 二进制自动回滚失败！"

        log_error "旧版本位于：${backup_file}"

        return
    fi

    if restart_realm_checked; then

        echo

        log_info "Realm 已成功回滚旧版本。"

        log_info "当前版本：$(get_current_version)"

        rm -f "${backup_file}"

        return
    fi

    log_error "回滚旧版后 Realm 仍然无法启动。"

    log_error "旧版本备份保留在：${backup_file}"

    show_recent_logs
}


# ============================================================
# 卸载 Realm
# ============================================================

uninstall_realm() {
    local confirm

    echo

    printf '%b\n' \
        "${RED}=================================================${PLAIN}"

    printf '%b\n' \
        "${RED}                  危险操作${PLAIN}"

    printf '%b\n' \
        "${RED}=================================================${PLAIN}"

    echo

    echo "此操作将删除："

    echo

    echo "  ${REALM_BIN}"
    echo "  ${CONF_DIR}"
    echo "  ${SERVICE_FILE}"

    echo

    printf '%b\n' \
        "${RED}所有 Realm 配置和转发规则都会被删除！${PLAIN}"

    echo

    read -r \
        -p "请输入 YES 确认彻底卸载 Realm: " \
        confirm

    if [[ "${confirm}" != "YES" ]]; then
        log_tip "已取消卸载。"
        return
    fi

    systemctl stop realm 2>/dev/null || true

    systemctl disable realm 2>/dev/null || true

    rm -f -- "${SERVICE_FILE}"

    rm -f -- "${REALM_BIN}"

    rm -f -- "${REALM_BIN}.new"

    rm -f -- "${REALM_BIN}.rollback"

    # ========================================================
    # 高危操作保护
    #
    # 必须严格确认目录为 /etc/realm
    # 才允许执行 rm -rf。
    # ========================================================

    if [[ "${CONF_DIR}" == "/etc/realm" ]]; then

        rm -rf -- "${CONF_DIR}"

    else

        log_error "CONF_DIR 安全检查失败。"

        log_error "拒绝删除：${CONF_DIR}"

        return
    fi

    systemctl daemon-reload

    systemctl reset-failed realm 2>/dev/null || true

    echo

    log_info "Realm 已彻底卸载。"
}


# ============================================================
# 主菜单
# ============================================================

show_menu() {
    local version
    local status
    local rule_count="0"

    clear 2>/dev/null || true

    if realm_installed; then
        version="$(get_current_version)"
    else
        version="未安装"
    fi

    if [[ -f "${CONF_FILE}" ]]; then
        rule_count="$(get_rule_count)"
    fi

    if service_exists &&
       systemctl is-active --quiet realm 2>/dev/null; then

        status="${GREEN}运行中${PLAIN}"

    else

        status="${YELLOW}未运行${PLAIN}"
    fi

    printf '%b\n' "${GREEN}"

    echo "=================================================="
    echo "             Realm 一键转发管理"
    echo "=================================================="

    printf '%b' "${PLAIN}"

    echo

    printf ' Realm 版本：%b\n' \
        "${GREEN}${version}${PLAIN}"

    printf ' 服务状态：%b\n' \
        "${status}"

    printf ' 转发规则：%s 条\n' \
        "${rule_count}"

    echo

    echo "  1. 安装 / 修复 Realm"

    echo

    echo "  2. 添加转发规则"
    echo "  3. 查看转发规则"
    echo "  4. 删除指定规则"
    echo "  5. 清空全部规则"

    echo

    echo "  6. 查看 Realm 状态"
    echo "  7. 重启 Realm"

    echo

    echo "  8. 在线升级 Realm"

    echo

    echo "  9. 卸载 Realm"

    echo

    echo "  0. 退出"

    echo

    echo "=================================================="
}


# ============================================================
# Main
# ============================================================

main() {
    local choice

    check_root

    while true; do

        show_menu

        read -r \
            -p "请选择操作 [0-9]: " \
            choice

        case "${choice}" in

            1)
                install_realm
                ;;

            2)
                add_rule
                ;;

            3)
                list_rules
                ;;

            4)
                delete_rule
                ;;

            5)
                clear_rules
                ;;

            6)
                show_status
                ;;

            7)
                restart_realm
                ;;

            8)
                update_realm
                ;;

            9)
                uninstall_realm
                ;;

            0)
                log_info "已退出。"
                exit 0
                ;;

            *)
                log_error "无效选项，请输入 0-9。"
                ;;
        esac

        echo

        read -r \
            -p "按 Enter 键继续..." \
            _ || true
    done
}


main "$@"
