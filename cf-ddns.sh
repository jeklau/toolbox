#!/bin/bash

# ================= 配置区 =================
CF_TOKEN="在这里填入你的_API_Token"
ZONE_ID="在这里填入你的_Zone_ID"
RECORD_NAME="nat.yourdomain.com"  # 你要解析的完整域名
# ==========================================

# 强制通过 IPv4 获取当前 VPS 的真实公网 IP
CURRENT_IP=$(curl -s -4 https://api.ip.sb/ip)

if [ -z "$CURRENT_IP" ]; then
    echo "无法获取当前 IPv4 地址，请检查网络。"
    exit 1
fi

# 获取 Cloudflare 上该域名的记录 ID 和当前 IP
RECORD_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$RECORD_NAME" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json")

# 解析 JSON 数据
RECORD_ID=$(echo "$RECORD_INFO" | jq -r '.result[0].id')
CF_IP=$(echo "$RECORD_INFO" | jq -r '.result[0].content')

if [ "$RECORD_ID" == "null" ]; then
    echo "未在 Cloudflare 找到记录，请先去后台手动创建一条名为 $RECORD_NAME 的 A 记录。"
    exit 1
fi

# 判断 IP 是否变化，如果没变则退出
if [ "$CURRENT_IP" == "$CF_IP" ]; then
    echo "IP 未改变 ($CURRENT_IP)，无需更新。"
    exit 0
fi

# IP 发生变化，执行更新
UPDATE_RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json" \
     --data '{"type":"A","name":"'"$RECORD_NAME"'","content":"'"$CURRENT_IP"'","ttl":120,"proxied":false}')

SUCCESS=$(echo "$UPDATE_RESULT" | jq -r '.success')

if [ "$SUCCESS" == "true" ]; then
    echo "DDNS 更新成功！新 IP: $CURRENT_IP"
else
    echo "DDNS 更新失败！"
    echo "$UPDATE_RESULT"
fi
