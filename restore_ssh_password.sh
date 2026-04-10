#!/usr/bin/env bash

# ==============================================================================
# 脚本名称: restore_ssh_password.sh
# 功能描述: 修改 root 密码并启用 SSH 密码登录模式
# 安全警告: 此脚本会降低系统安全性，请确保在受控环境下使用
# 编写环境: POSIX 兼容, 建议在 Bash 4.0+ 运行
# ==============================================================================

# 严格模式：出错即停止，变量未定义报错，管道错误传播
set -euo pipefail
IFS=$'\n\t'

# --- 变量定义 ---
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly BACKUP_SUFFIX=".bak.$(date +%F_%T)"

# --- 函数定义 ---

log_info() {
    printf "\e[32m[INFO]\e[0m %s\n" "$1"
}

log_warn() {
    printf "\e[33m[WARN]\e[0m %s\n" "$1"
}

log_error() {
    printf "\e[31m[ERROR]\e[0m %s\n" "$1" >&2
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "此脚本必须以 root 用户权限运行。"
        exit 1
    fi
}

backup_config() {
    if [[ -f "${SSH_CONFIG}" ]]; then
        cp "${SSH_CONFIG}" "${SSH_CONFIG}${BACKUP_SUFFIX}"
        log_info "已备份 SSH 配置至: ${SSH_CONFIG}${BACKUP_SUFFIX}"
    else
        log_error "未找到 SSH 配置文件: ${SSH_CONFIG}"
        exit 1
    fi
}

update_sshd_config() {
    local key="$1"
    local value="$2"

    # 使用 sed 修改配置：
    # 1. 如果匹配到已被注释或存在的配置，则替换整个行
    # 2. 如果不存在，则在文件末尾追加
    if grep -qE "^#?${key}" "${SSH_CONFIG}"; then
        sed -i "s|^#\?${key}.*|${key} ${value}|" "${SSH_CONFIG}"
    else
        echo "${key} ${value}" >> "${SSH_CONFIG}"
    fi
    log_info "设置 ${key} 为 ${value}"
}

apply_changes() {
    log_info "正在校验 SSH 配置语法..."
    sshd -t
    
    log_info "正在重启 SSH 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart ssh
    elif service ssh restart >/dev/null 2>&1; then
        service ssh restart
    else
        log_error "未找到支持的服务管理器（systemd/init.d），请手动重启 sshd。"
        return 1
    fi
    log_info "配置已成功应用。"
}

# --- 主逻辑 ---

main() {
    check_root

    echo "------------------------------------------------"
    log_warn "该脚本将修改 root 密码并开启密码登录权限。"
    echo "------------------------------------------------"

    # 交互式安全获取密码，避免在 history 中留下明文
    read -rsp "请输入新的 root 密码: " NEW_PASS
    echo
    read -rsp "请再次输入密码以确认: " CONFIRM_PASS
    echo

    if [[ "${NEW_PASS}" != "${CONFIRM_PASS}" ]]; then
        log_error "两次输入的密码不一致，操作终止。"
        exit 1
    fi

    # 1. 修改密码
    log_info "正在修改 root 用户密码..."
    echo "root:${NEW_PASS}" | chpasswd
    
    # 2. 修改配置
    backup_config
    
    log_info "正在调整 sshd_config 参数..."
    # 允许密码验证
    update_sshd_config "PasswordAuthentication" "yes"
    # 允许 root 登录（根据需求可选，通常普通登录需要开启此项）
    update_sshd_config "PermitRootLogin" "yes"
    # 确保公钥登录依然可用（防御性保持，不破坏现有 Key 登录）
    update_sshd_config "PubkeyAuthentication" "yes"

    # 3. 应用配置
    apply_changes

    log_info "完成！现在你可以通过密码登录 root 账户了。"
}

# 触发主逻辑
main "$@"
