#!/usr/bin/env bash

# ====================================================
# Nftables 端口转发管理工具 (严格模式增强版)
# ====================================================

# 开启严格模式：防爆防呆
set -euo pipefail

# 1. 环境与权限预检
if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ 错误: 此脚本必须以 root 权限运行。请使用 sudo 执行。" >&2
    exit 1
fi

if ! command -v nft &> /dev/null; then
    echo "❌ 错误: 未检测到 nftables。请先安装: apt install nftables 或 yum install nftables" >&2
    exit 1
fi

# 配置文件路径
CONF_FILE="/etc/nftables.conf"

# ====================================================
# 功能函数定义
# ====================================================

# 开启内核转发
enable_ip_forward() {
    echo "[*] 正在确保系统 IPv4 转发已开启..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf > /dev/null 2>&1
}

# 交互式获取用户输入
get_forward_inputs() {
    echo ""
    read -r -p "▶ 请输入本机内网 IP (SNAT 伪装用, 例如 10.1.1.1): " RELAY_LAN_IP
    [[ -z "${RELAY_LAN_IP}" ]] && { echo "❌ 错误: 本机内网 IP 不能为空"; exit 1; }

    read -r -p "▶ 请输入目标机器 IP (例如 172.16.1.1): " DEST_IP
    [[ -z "${DEST_IP}" ]] && { echo "❌ 错误: 目标 IP 不能为空"; exit 1; }

    read -r -p "▶ 请输入需要转发的入口端口或范围 (例如 12345 或 12345-54321): " IN_PORT
    [[ -z "${IN_PORT}" ]] && { echo "❌ 错误: 入口端口不能为空"; exit 1; }

    read -r -p "▶ 请输入目标机器接收的端口 (如与上面相同，请直接回车跳过): " OUT_PORT

    # 逻辑处理：如果不填目标端口，则 1:1 等端口转发
    if [[ -z "${OUT_PORT}" ]]; then
        DNAT_TARGET="${DEST_IP}"
        SNAT_PORT_MATCH="${IN_PORT}"
    else
        # 防呆设计：如果入口是范围，且填了单一出口端口，强制忽略出口端口以防配置报错
        if [[ "${IN_PORT}" == *"-"* && "${OUT_PORT}" != *"-"* ]]; then
            echo "⚠️  警告: 入口是一个端口范围，不支持映射到单一目标端口。已自动重置为等端口(1:1)转发。"
            DNAT_TARGET="${DEST_IP}"
            SNAT_PORT_MATCH="${IN_PORT}"
        else
            DNAT_TARGET="${DEST_IP}:${OUT_PORT}"
            SNAT_PORT_MATCH="${OUT_PORT}"
        fi
    fi
}

# 生成规则内容 (用于全新或追加)
generate_rules() {
    local is_append=$1
    local rule_content=""

    if [[ "${is_append}" == "false" ]]; then
        rule_content+="flush ruleset\n\n"
    fi

    rule_content+="table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${IN_PORT} dnat to ${DNAT_TARGET}
        udp dport ${IN_PORT} dnat to ${DNAT_TARGET}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr ${DEST_IP} tcp dport ${SNAT_PORT_MATCH} snat to ${RELAY_LAN_IP}
        ip daddr ${DEST_IP} udp dport ${SNAT_PORT_MATCH} snat to ${RELAY_LAN_IP}
    }
}"
    echo -e "$rule_content"
}

# ====================================================
# 主菜单循环
# ====================================================

while true; do
    echo ""
    echo "====================================================="
    echo "            Nftables 端口转发管理菜单            "
    echo "====================================================="
    echo "  1) 全新机器添加转发 (清空现有规则，仅保留本次新增)"
    echo "  2) 在原有规则上增加转发 (追加模式，不影响现有业务)"
    echo "  3) 一键清空所有转发规则"
    echo "  4) 查看当前生效的转发规则"
    echo "  0) 退出脚本"
    echo "====================================================="
    read -r -p "请输入选项 [0-4]: " CHOICE

    case "$CHOICE" in
        1)
            echo "-----------------------------------------------------"
            echo "⚠️  注意: 这将清空机器上所有的 Nftables 规则！"
            read -r -p "确认继续吗？(y/N): " CONFIRM
            if [[ "${CONFIRM,,}" == "y" ]]; then
                enable_ip_forward
                get_forward_inputs
                echo "[*] 正在覆写配置文件 ${CONF_FILE} ..."
                echo "#!/usr/sbin/nft -f" > "${CONF_FILE}"
                generate_rules "false" >> "${CONF_FILE}"
                
                nft -f "${CONF_FILE}"
                systemctl enable --now nftables > /dev/null 2>&1
                echo "✅ 全新转发规则已成功配置并生效！"
            else
                echo "已取消操作。"
            fi
            ;;
        2)
            echo "-----------------------------------------------------"
            enable_ip_forward
            get_forward_inputs
            
            TMP_FILE=$(mktemp)
            generate_rules "true" > "${TMP_FILE}"
            
            echo "[*] 正在追加规则到当前系统..."
            nft -f "${TMP_FILE}"
            
            # 立即保存当前内存中的完整规则到配置文件，防止重启丢失
            echo "[*] 正在持久化保存到 ${CONF_FILE} ..."
            echo "#!/usr/sbin/nft -f" > "${CONF_FILE}"
            nft list ruleset >> "${CONF_FILE}"
            
            rm -f "${TMP_FILE}"
            echo "✅ 转发规则已成功追加并保存！"
            ;;
        3)
            echo "-----------------------------------------------------"
            read -r -p "⚠️  高危操作: 确定要清空所有 Nftables 规则吗？(y/N): " CONFIRM
            if [[ "${CONFIRM,,}" == "y" ]]; then
                nft flush ruleset
                echo "#!/usr/sbin/nft -f" > "${CONF_FILE}"
                echo "flush ruleset" >> "${CONF_FILE}"
                echo "✅ 所有转发规则已清空。"
            else
                echo "已取消操作。"
            fi
            ;;
        4)
            echo "-----------------------------------------------------"
            echo "当前系统生效的 NAT 规则如下："
            echo "-----------------------------------------------------"
            # 临时关闭 strict mode 中的 exit on error，防止表不存在时脚本直接崩溃退出
            set +e
            nft list table ip nat 2>/dev/null || echo "当前没有任何 IPv4 NAT 规则。"
            set -e
            ;;
        0)
            echo "退出程序。Bye!"
            exit 0
            ;;
        *)
            echo "❌ 无效的选项，请输入 0-4 之间的数字。"
            ;;
    esac
done
