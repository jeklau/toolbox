#!/bin/bash
set -u

# ---------- 权限与命令可用性检查 ----------
SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
  echo "错误：当前不是 root，且系统未安装 sudo。"
  echo "解决：要么切换 root 运行；要么安装 sudo（Debian/Ubuntu: apt update && apt install -y sudo）。"
  exit 1
fi

# 选择 ping 命令（优先 ping6；没有则用 ping -6）
PING_CMD=""
PING_MODE=""
if command -v ping6 >/dev/null 2>&1; then
  PING_CMD="ping6"
  PING_MODE="ping6"
elif command -v ping >/dev/null 2>&1; then
  PING_CMD="ping"
  PING_MODE="ping-6"
else
  echo "错误：未找到 ping6 或 ping 命令。请安装 iputils-ping。"
  exit 1
fi

ping_ipv6() {
    local src_ip="$1"
    local target_ipv6="$2"
    local temp_file="$3"

    local ping_output

    if [ "$PING_MODE" = "ping6" ]; then
      ping_output=$($PING_CMD -I "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      # 回退：部分实现 -I 不能接源地址
      if echo "$ping_output" | grep -qiE 'invalid argument|unknown|bind|Cannot assign requested address|bad address|cannot assign|Usage:'; then
          ping_output=$($PING_CMD -I "$interface_name" -S "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      fi
    else
      # ping -6
      ping_output=$($PING_CMD -6 -I "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      if echo "$ping_output" | grep -qiE 'invalid argument|unknown|bind|Cannot assign requested address|bad address|cannot assign|Usage:'; then
          ping_output=$($PING_CMD -6 -I "$interface_name" -S "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      fi
    fi

    local loss
    loss=$(echo "$ping_output" | grep 'packets transmitted' | awk '{print $6}')

    # 无有效统计则跳过
    if [ -z "${loss:-}" ]; then
        return
    fi

    # 100% 丢包跳过
    if [ "$loss" = "100%" ] || [ "$loss" = "100.0%" ]; then
        return
    fi

    # 取 avg RTT
    local avg
    avg=$(echo "$ping_output" | awk -F'=' '/rtt|round-trip/ {print $2}' | awk -F'/' '{print $2}' | head -n 1)

    [ -z "${avg:-}" ] && return
    echo "$src_ip $avg" >> "$temp_file"
}

cleanup() {
    if [ "${#ip_array[@]}" -gt 0 ]; then
        for src_ip in "${ip_array[@]}"; do
            $SUDO ip -6 addr del "$src_ip"/64 dev "$interface_name" 2>/dev/null || true
        done
    fi
    [ -n "${temp_file:-}" ] && [ -f "$temp_file" ] && rm -f "$temp_file"
    [ -n "${temp_progress_file:-}" ] && [ -f "$temp_progress_file" ] && rm -f "$temp_progress_file"
    [ -n "${err_file:-}" ] && [ -f "$err_file" ] && rm -f "$err_file"
}

print_progress_bar() {
    local -i current=$1
    local -i total=$2
    local filled=$((current*60/total))
    local bars
    bars=$(printf "%-${filled}s" "|" | tr ' ' '|')
    local spaces
    spaces=$(printf "%-$((60-filled))s" " ")
    local percent=$((current*100/total))
    echo -ne "[${bars}${spaces}] ${percent}% ($current/$total)\r"
}

start_time=$(date +%s)
trap cleanup EXIT

# ---------- 获取默认 IPv6 网卡与前缀 ----------
interface_name=$(ip -6 route | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [ -z "${interface_name:-}" ]; then
    echo "未找到默认 IPv6 路由对应的网卡（ip -6 route default）。"
    exit 1
fi

current_ipv6=$(ip -6 addr show "$interface_name" | grep 'inet6' | grep -v 'fe80' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
if [ -z "${current_ipv6:-}" ]; then
    echo "未在网卡 $interface_name 上找到全局 IPv6（非 fe80::/10）。"
    exit 1
fi

current_prefix=$(echo "$current_ipv6" | cut -d':' -f1-4)

echo ""
echo "网卡当前配置的IPv6： $current_ipv6"
echo "分配该虚拟机的IPv6： $current_prefix::/64"
echo ""

stty erase '^H' && read -p "请输入你要检测的对端IPv6: " target_ipv6
if ! [[ "$target_ipv6" =~ ^([0-9a-fA-F:]+)$ && "${#target_ipv6}" -ge 15 && "${#target_ipv6}" -le 39 ]]; then
    echo "你输入的这个地址看着不太对。"
    exit 1
fi

stty erase '^H' && read -p "请输入你要测试多少个IPv6（建议512M机型小于500个）: " ipv6_num
if ! [[ "$ipv6_num" =~ ^[0-9]+$ ]]; then
    echo "数量必须是数字。"
    exit 1
fi
if [ "$ipv6_num" -eq 0 ]; then
    echo "数量不能为 0。"
    exit 1
fi

declare -a ip_array
declare -A used_ip_addrs
used_ip_addrs["$current_ipv6"]=1

echo ""
echo "在 $current_prefix::/64 中生成$ipv6_num个IPv6进行检测 请等待任务完成"

current_count=0
err_file=$(mktemp)

# 最大重试次数，避免无限卡死（可按需调大）
max_tries=$((ipv6_num * 300))
tries=0
first_err_printed=0

for (( i=0; i<ipv6_num; i++ )); do
    while : ; do
        ((tries++))
        if [ "$tries" -gt "$max_tries" ]; then
            echo ""
            echo "错误：生成IPv6阶段连续失败，已超过最大重试次数（$max_tries）。"
            echo "最近一次错误信息如下："
            tail -n 1 "$err_file" 2>/dev/null || true
            echo ""
            echo "常见原因："
            echo "1) 你的环境不允许在网卡上随意添加大量 IPv6（云厂商/安全策略限制）。"
            echo "2) 该地址段并不是你真正可用的 /64（仅有单个地址或非 /64）。"
            echo "3) 容器环境缺少 NET_ADMIN 能力。"
            exit 1
        fi

        random_part=$(printf '%x:%x:%x:%x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))
        test_ipv6="$current_prefix:$random_part"

        if [ -z "${used_ip_addrs[$test_ipv6]+x}" ]; then
            # 关键：这里不再吞掉错误，而是记录下来，便于定位
            if $SUDO ip -6 addr add "$test_ipv6"/64 dev "$interface_name" 2>>"$err_file"; then
                used_ip_addrs["$test_ipv6"]=1
                ip_array+=("$test_ipv6")
                ((current_count++))
                print_progress_bar "$current_count" "$ipv6_num"
                break
            else
                # 第一次失败给一个明显提示（避免用户认为卡死）
                if [ "$first_err_printed" -eq 0 ]; then
                    first_err_printed=1
                    echo ""
                    echo "提示：添加IPv6失败，正在重试生成（已记录错误原因）。若持续失败将自动退出并打印原因。"
                    echo -ne "\r"
                fi
                continue
            fi
        fi
    done
done

echo ""
sleep 2

temp_file=$(mktemp)

# 动态并发（至少 1，最多 200）
total_jobs=${#ip_array[@]}
quarter_jobs=$(( (total_jobs + 3) / 4 ))
parallel_jobs=$quarter_jobs
if [ "$parallel_jobs" -lt 1 ]; then parallel_jobs=1; fi
if [ "$parallel_jobs" -gt 200 ]; then parallel_jobs=200; fi

completed_jobs=0
temp_progress_file=$(mktemp)

echo
echo "对$total_jobs个IPv6进行Ping测试中 请等待任务完成"
print_progress_bar "$completed_jobs" "$total_jobs"

{
    for src_ip in "${ip_array[@]}"; do
        (
            ping_ipv6 "$src_ip" "$target_ipv6" "$temp_file"
            # 只删一次，静默错误
            $SUDO ip -6 addr del "$src_ip"/64 dev "$interface_name" 2>/dev/null || true
            echo >> "$temp_progress_file"
        ) &

        if (( $(jobs | wc -l) >= parallel_jobs )); then
            wait -n
            completed_jobs=$(wc -l < "$temp_progress_file")
            print_progress_bar "$completed_jobs" "$total_jobs"
        fi
    done
    wait
}

completed_jobs=$(wc -l < "$temp_progress_file")
print_progress_bar "$completed_jobs" "$total_jobs"
echo ""

echo "====================================================="
echo "IPv6                                     Average"
sort -k2 -n "$temp_file" | head -n 10 | while read -r line; do
    ipv6=$(echo "$line" | awk '{print $1}')
    rtt=$(echo "$line" | awk '{print $2}')
    printf "%-40s %s ms\n" "$ipv6" "$rtt"
done
echo "====================================================="

end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
echo "脚本总耗时: $elapsed_time 秒。"
