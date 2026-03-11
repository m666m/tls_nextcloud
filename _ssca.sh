#!/bin/bash

# _ssca.sh - 生成自签名证书的 SAN 属性值
# 用法: source _ssca.sh [地址]
# 导出变量:
#   _ssca_CN        证书 CN (取第一个域名)
#   _ssca_SAN       完整的 subjectAltName 字符串 (格式: DNS:域名1,DNS:域名2,IP:IP1,IP:IP2)
#   _ssca_SAN_DNS   空格分隔的域名列表
#   _ssca_SAN_IP    空格分隔的 IP 列表

# 辅助函数：向列表中添加元素（去重，可指定前后位置）
_add_to_list() {
    local item="$1"
    local pos="$2"      # before 或 after
    local list="$3"
    local new_list=""

    # 如果列表非空，移除已存在的相同项
    if [ -n "$list" ]; then
        new_list=$(echo "$list" | tr ' ' '\n' | grep -v "^$item$" | tr '\n' ' ' | sed 's/ $//')
    fi

    # 按位置插入
    if [ "$pos" = "before" ]; then
        list="$item $new_list"
    else
        list="$new_list $item"
    fi

    # 去除多余空格
    echo "$list" | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

# ---------- 1. 初始化域名列表 ----------
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" == *.* ]]; then
    BASE_DOMAIN="$HOSTNAME"
else
    BASE_DOMAIN="${HOSTNAME}.local"
fi
domain_list="$BASE_DOMAIN localhost"

# ---------- 2. 初始化 IP 列表 ----------
ip_list=""
# 收集本机所有非回环 IPv4 地址
if command -v ip >/dev/null 2>&1; then
    while read -r ip; do
        ip_list="$ip_list $ip"
    done < <(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' 2>/dev/null)
fi
ip_list=$(echo "$ip_list" | sed 's/^ //')  # 去除前导空格
# 添加 127.0.0.1 到最后（自动去重）
ip_list=$(_add_to_list "127.0.0.1" "after" "$ip_list")
# 如果 IP 列表仍为空，则至少包含 127.0.0.1
if [ -z "$ip_list" ]; then
    ip_list="127.0.0.1"
fi

# ---------- 3. 处理用户输入 ----------
if [ -n "$1" ]; then
    address="$1"
    # 判断是否为 IPv4 地址
    if echo "$address" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        # IP 地址：添加到 IP 列表最前面
        ip_list=$(_add_to_list "$address" "before" "$ip_list")
    else
        # 域名处理
        if [ "$address" = "localhost" ]; then
            :  # localhost 已存在，跳过
        elif ! echo "$address" | grep -q '\.'; then
            # 短名，添加 .local 后缀
            address="${address}.local"
        fi
        # 添加到域名列表最前面
        domain_list=$(_add_to_list "$address" "before" "$domain_list")
    fi
fi

# ---------- 4. 生成导出变量 ----------
_ssca_CN=$(echo "$domain_list" | cut -d' ' -f1)

# 构建 SAN 字符串
san_dns=""
for dns in $domain_list; do
    if [ -z "$san_dns" ]; then
        san_dns="DNS:$dns"
    else
        san_dns="$san_dns,DNS:$dns"
    fi
done
san_ip=""
for ip in $ip_list; do
    if [ -z "$san_ip" ]; then
        san_ip="IP:$ip"
    else
        san_ip="$san_ip,IP:$ip"
    fi
done
if [ -n "$san_dns" ] && [ -n "$san_ip" ]; then
    _ssca_SAN="$san_dns,$san_ip"
elif [ -n "$san_dns" ]; then
    _ssca_SAN="$san_dns"
else
    _ssca_SAN="$san_ip"
fi

_ssca_SAN_DNS="$domain_list"
_ssca_SAN_IP="$ip_list"

# 导出环境变量
export _ssca_CN
export _ssca_SAN
export _ssca_SAN_DNS
export _ssca_SAN_IP
