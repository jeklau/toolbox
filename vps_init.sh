#!/bin/bash

# =========================================================
# Linux VPS 一键初始化配置脚本
# 功能：基础软件安装、BBR、Swap、DNS、时区、SSH安全、Fail2ban、Vim优化
# =========================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查是否为 Root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# 系统检测与包管理器定义
if [ -f /etc/redhat-release ]; then
    RELEASE="centos"
    PM="yum"
elif cat /etc/issue | grep -q -E -i "debian"; then
    RELEASE="debian"
    PM="apt-get"
elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    RELEASE="ubuntu"
    PM="apt-get"
elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
    RELEASE="centos"
    PM="yum"
elif cat /proc/version | grep -q -E -i "debian"; then
    RELEASE="debian"
    PM="apt-get"
elif cat /proc/version | grep -q -E -i "ubuntu"; then
    RELEASE="ubuntu"
    PM="apt-get"
elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    RELEASE="centos"
    PM="yum"
else
    echo -e "${RED}未检测到支持的操作系统！${PLAIN}"
    exit 1
fi

echo -e "${GREEN}检测到系统版本: ${RELEASE}${PLAIN}"

# 1. 系统更新与基础软件安装
install_base() {
    echo -e "${YELLOW}1. 正在更新系统并安装基础软件 (sudo, curl, wget, vnstat)...${PLAIN}"
    if [ "$PM" == "yum" ]; then
        yum update -y
        yum install -y sudo curl wget vnstat epel-release
    elif [ "$PM" == "apt-get" ]; then
        apt-get update -y
        apt-get install -y sudo curl wget vnstat
    fi
    
    # 初始化 vnstat 接口
    INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    vnstat -u -i "$INTERFACE" 
    systemctl enable vnstat
    systemctl start vnstat
    echo -e "${GREEN}基础软件安装完成。${PLAIN}"
}

# 2. 设置主机名
set_hostname() {
    echo -e "${YELLOW}2. 设置主机名${PLAIN}"
    read -p "是否修改主机名? [y/n] (默认 n): " modify_host
    if [[ "$modify_host" == "y" || "$modify_host" == "Y" ]]; then
        read -p "请输入新的主机名: " new_hostname
        hostnamectl set-hostname "$new_hostname"
        echo -e "${GREEN}主机名已设置为: $new_hostname${PLAIN}"
    else
        echo -e "跳过主机名设置。"
    fi
}

# 3. 设置时区与时间同步
set_timezone_sync() {
    echo -e "${YELLOW}3. 设置时区与时间同步${PLAIN}"
    read -p "是否设置时区? [y/n] (默认 y): " set_tz
    set_tz=${set_tz:-y}
    
    if [[ "$set_tz" == "y" || "$set_tz" == "Y" ]]; then
        read -p "请输入时区 (默认 Asia/Singapore): " timezone
        timezone=${timezone:-Asia/Singapore}
        timedatectl set-timezone "$timezone"
        echo -e "${GREEN}时区已设置为: $timezone${PLAIN}"
    fi

    echo -e "正在开启时间同步..."
    timedatectl set-ntp true
    if [ "$PM" == "yum" ]; then
        yum install -y chrony
        systemctl enable chronyd && systemctl start chronyd
    else
        apt-get install -y chrony
        systemctl enable chrony && systemctl start chrony
    fi
    echo -e "${GREEN}时间同步已开启。${PLAIN}"
}

# 4. 开启 BBR
enable_bbr() {
    echo -e "${YELLOW}4. 检查并开启 BBR${PLAIN}"
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo -e "${GREEN}BBR 已经开启。${PLAIN}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}BBR 已开启。${PLAIN}"
    fi
}

# 5. 自动配置 Swap
config_swap() {
    echo -e "${YELLOW}5. 自动配置 Swap${PLAIN}"
    if [ -f /swapfile ]; then
        echo -e "${GREEN}Swap 文件已存在，跳过。${PLAIN}"
    else
        # 计算 Swap 大小 (内存的 2 倍，最大 2G)
        mem_size=$(free -m | awk '/Mem:/ { print $2 }')
        if [ "$mem_size" -le 2048 ]; then
            swap_size=$((mem_size * 2))
        else
            swap_size=2048
        fi
        
        echo -e "正在创建 ${swap_size}MB 的 Swap..."
        fallocate -l ${swap_size}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${GREEN}Swap 配置完成。${PLAIN}"
    fi
}

# 6. 配置 DNS
config_dns() {
    echo -e "${YELLOW}6. 配置 DNS${PLAIN}"
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
    echo -e "${GREEN}DNS 已配置为 Cloudflare 和 Google DNS。${PLAIN}"
}

# 7. SSH 配置 (端口与密码)
config_ssh() {
    echo -e "${YELLOW}7. SSH 配置${PLAIN}"
    read -p "是否修改 SSH 端口? [y/n] (默认 n): " modify_port
    ssh_port=22
    
    if [[ "$modify_port" == "y" || "$modify_port" == "Y" ]]; then
        read -p "请输入新的 SSH 端口 (1024-65535): " new_port
        if [[ $new_port -ge 1024 && $new_port -le 65535 ]]; then
            sed -i "s/^#\?Port .*/Port $new_port/g" /etc/ssh/sshd_config
            ssh_port=$new_port
            echo -e "${GREEN}SSH 端口已修改为: $new_port (重启 SSH 服务后生效)${PLAIN}"
            
            # 放行防火墙
            if command -v ufw >/dev/null 2>&1; then
                ufw allow $new_port/tcp
            elif command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port=$new_port/tcp
                firewall-cmd --reload
            fi
            echo -e "${RED}警告: 请确保在云服务商的安全组中放行端口 $new_port !${PLAIN}"
        else
            echo -e "${RED}端口输入无效，保持默认 22 端口。${PLAIN}"
        fi
    fi

    read -p "是否修改 root 密码? [y/n] (默认 n): " modify_pass
    if [[ "$modify_pass" == "y" || "$modify_pass" == "Y" ]]; then
        passwd root
    fi
}

# 8. 安装并配置 Fail2ban
install_fail2ban() {
    echo -e "${YELLOW}8. 安装并配置 Fail2ban${PLAIN}"
    if [ "$PM" == "yum" ]; then
        yum install -y fail2ban
    else
        apt-get install -y fail2ban
    fi

    # 创建 jail.local
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 86400
findtime = 600
maxretry = 3

[sshd]
enabled = true
port    = $ssh_port
logpath = %(sshd_log)s
backend = systemd
EOF
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}Fail2ban 已安装并开启保护 (Port: $ssh_port)。${PLAIN}"
}

# 9. 优化 Vim
optimize_vim() {
    echo -e "${YELLOW}9. 优化 Vim 配置${PLAIN}"
    cat > ~/.vimrc <<EOF
set number
set cursorline
set ruler
set showcmd
set encoding=utf-8
syntax on
set tabstop=4
set shiftwidth=4
set expandtab
set softtabstop=4
set autoindent
EOF
    echo -e "${GREEN}Vim 配置优化完成。${PLAIN}"
}

# 10. 清理与重启 SSH
cleanup() {
    echo -e "${YELLOW}10. 系统清理${PLAIN}"
    if [ "$PM" == "yum" ]; then
        yum clean all
    else
        apt-get autoremove -y
        apt-get clean
    fi
    
    echo -e "正在重启 SSH 服务..."
    systemctl restart sshd
    
    echo -e "\n${GREEN}=======================================${PLAIN}"
    echo -e "${GREEN}      VPS 初始化配置完成！             ${PLAIN}"
    echo -e "${GREEN}=======================================${PLAIN}"
    echo -e "SSH 端口: ${YELLOW}$ssh_port${PLAIN}"
    echo -e "请检查以上信息，建议重启服务器以应用所有更改。"
}

# 执行主流程
install_base
set_hostname
set_timezone_sync
enable_bbr
config_swap
config_dns
config_ssh
install_fail2ban
optimize_vim
cleanup
