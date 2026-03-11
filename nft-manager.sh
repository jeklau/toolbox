#!/usr/bin/env bash

# ====================================================
# Nftables 端口转发管理工具 (全功能豪华版 V3)
# ====================================================

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ 错误: 此脚本必须以 root 权限运行。请使用 sudo 执行。" >&2
    exit 1
fi

if ! command -v nft &> /dev/null; then
    echo "❌ 错误: 未检测到 nftables。请先安装: apt install nftables 或 yum install nftables" >&2
    exit 1
fi

CONF_FILE="/etc/nftables.conf"

enable_ip_forward() {
    echo "[*] 正在确保系统 IPv4 转发已开启..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf > /dev/null 2>&1
}

get_forward_inputs() {
    echo ""
    echo "请选择端口转发引擎模式："
    echo "  1) ip nat (静态模式: 使用 SNAT，适合内网转发，比如前置转发到IX)"
    echo "  2) inet port_forward (动态模式: 使用 Masquerade，适合本机动态获取 IP，比如IX转发到落地)"
    read -r -p "▶ 请选择 [1-2]: " FW_MODE
    
    if [[ "${FW_MODE}" != "1" && "${FW_MODE}" != "2" ]]; then
        echo "❌ 错误: 无效的选择，请输入 1 或 2。"
        exit 1
    fi

    if [[ "${FW_MODE}" == "1" ]]; then
        read -r -p "▶ 请输入本机内网 IP (SNAT 伪装用, 例如 10.1.1.1): " RELAY_LAN_IP
        [[ -z "${RELAY_LAN_IP}" ]] && { echo "❌ 错误: 本机内网 IP 不能为空"; exit 1; }
    fi

    read -r -p "▶ 请输入目标机器 IP (例如 1.1.1.1): " DEST_IP
    [[ -z "${DEST_IP}" ]] && { echo "❌ 错误: 目标 IP 不能为空"; exit 1; }

    read -r -p "▶ 请输入需要转发的入口端口或范围 (例如 12345 或 12345-54321): " IN_PORT
    [[ -z "${IN_PORT}" ]] && { echo "❌ 错误: 入口端口不能为空"; exit 1; }

    read -r -p "▶ 请输入目标机器接收的端口 (如与上面相同，请直接回车跳过): " OUT_PORT

    if [[ -z "${OUT_PORT}" ]]; then
        DNAT_TARGET="${DEST_IP}"
        SNAT_PORT_MATCH="${IN_PORT}"
    else
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

generate_rules() {
    local is_append=$1
    local rule_content=""

    if [[ "${is_append}" == "false" ]]; then
        rule_content+="flush ruleset\n\n"
    fi

    if [[ "${FW_MODE}" == "1" ]]; then
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
    elif [[ "${FW_MODE}" == "2" ]]; then
        rule_content+="table inet port_forward {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        meta nfproto ipv4 tcp dport ${IN_PORT} dnat to ${DNAT_TARGET}
        meta nfproto ipv4 udp dport ${IN_PORT} dnat to ${DNAT_TARGET}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr ${DEST_IP} tcp dport ${SNAT_PORT_MATCH} masquerade
        ip daddr ${DEST_IP} udp dport ${SNAT_PORT_MATCH} masquerade
    }
}"
    fi

    echo -e "$rule_content"
}

save_rules() {
    echo "[*] 正在持久化保存到 ${CONF_FILE} ..."
    echo "#!/usr/sbin/nft -f" > "${CONF_FILE}"
    nft list ruleset >> "${CONF_FILE}"
}

while true; do
    echo ""
    echo "====================================================="
    echo "            Nftables 端口转发管理菜单            "
    echo "====================================================="
    echo "  1) 全新机器添加转发 (清空现有规则，仅保留本次新增)"
    echo "  2) 在原有规则上增加转发 (追加模式，不影响现有业务)"
    echo "  3) 一键清空所有转发规则"
    echo "  4) 查看当前生效的完整转发规则"
    echo "  5) 批量删除单条/多条规则 (按 Handle 编号精准删除)"
    echo "  0) 退出脚本"
    echo "====================================================="
    read -r -p "请输入选项 [0-5]: " CHOICE

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
            save_rules
            
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
            echo "当前系统生效的规则集如下："
            echo "-----------------------------------------------------"
            set +e
            RULES=$(nft list ruleset 2>/dev/null)
            if [[ -z "$RULES" ]]; then
                echo "当前系统没有任何生效的规则。"
            else
                echo "$RULES"
            fi
            set -e
            ;;
        5)
            echo "-----------------------------------------------------"
            echo "当前规则列表及 Handle 编号："
            echo "-----------------------------------------------------"
            set +e
            RULES_WITH_HANDLE=$(nft -a list ruleset 2>/dev/null)
            if [[ -z "$RULES_WITH_HANDLE" ]]; then
                echo "当前系统没有任何生效的规则，无需删除。"
                set -e
                continue
            fi
            echo "$RULES_WITH_HANDLE"
            set -e
            echo "-----------------------------------------------------"
            
            # 简化协议族和表名的输入
            echo "请选择你要操作的表域："
            echo "  1) ip 协议族的 nat 表 (对应静态模式)"
            echo "  2) inet 协议族的 port_forward 表 (对应动态模式)"
            read -r -p "请输入 [1-2, 直接回车取消]: " TBL_CHOICE
            
            [[ -z "$TBL_CHOICE" ]] && continue
            
            if [[ "$TBL_CHOICE" == "1" ]]; then
                D_FAM="ip"
                D_TAB="nat"
            elif [[ "$TBL_CHOICE" == "2" ]]; then
                D_FAM="inet"
                D_TAB="port_forward"
            else
                echo "❌ 无效的选择。"
                continue
            fi
            
            # 简化链名的输入
            echo "请选择你要操作的链 (方向)："
            echo "  1) prerouting (入站，即入口端口转发规则)"
            echo "  2) postrouting (出站，即回程 SNAT/伪装规则)"
            read -r -p "请输入 [1-2]: " CHN_CHOICE
            
            if [[ "$CHN_CHOICE" == "1" ]]; then
                D_CHN="prerouting"
            elif [[ "$CHN_CHOICE" == "2" ]]; then
                D_CHN="postrouting"
            else
                echo "❌ 无效的选择。"
                continue
            fi
            
            # 批量输入 Handle 进行循环删除
            read -r -p "请输入要删除的 Handle 编号 (多个编号用空格隔开，如 '5 8 12'): " D_HANS
            [[ -z "$D_HANS" ]] && continue
            
            set +e
            SUCCESS_COUNT=0
            for H in $D_HANS; do
                nft delete rule "$D_FAM" "$D_TAB" "$D_CHN" handle "$H" 2>/dev/null
                if [ $? -eq 0 ]; then
                    echo "✅ 成功删除 Handle $H"
                    ((SUCCESS_COUNT++))
                else
                    echo "❌ 删除 Handle $H 失败 (可能编号不存在或输入有误)"
                fi
            done
            set -e
            
            # 只要成功删除了至少一条规则，就触发持久化保存
            if [ "$SUCCESS_COUNT" -gt 0 ]; then
                save_rules
            fi
            ;;
        0)
            echo "退出程序。Bye!"
            exit 0
            ;;
        *)
            echo "❌ 无效的选项，请输入 0-5 之间的数字。"
            ;;
    esac
done
