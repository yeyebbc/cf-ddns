#!/bin/bash
#===============================================================================
# cf-ddns.sh — Cloudflare IPv6 DDNS 更新脚本
# 运行环境: QNAP NAS
# 用法:     ./cf-ddns.sh [config_path]
#          默认配置文件路径为脚本同目录下的 config.conf
# cron:     */5 * * * * /path/to/cf-ddns.sh
#===============================================================================

set -euo pipefail

# --- 配置加载 ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/config.conf}"
STATE_FILE="${SCRIPT_DIR}/.cf-ddns-state"
LOG_TAG="cf-ddns"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# 加载配置文件
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_err "配置文件不存在: $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# 校验必填配置项
required_vars=("CF_API_TOKEN" "CF_ZONE_ID" "CF_RECORD_NAME")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_err "缺少必填配置项: $var"
        exit 1
    fi
done

# 可选配置项默认值
CF_RECORD_TTL="${CF_RECORD_TTL:-120}"
CF_RECORD_PROXIED="${CF_RECORD_PROXIED:-false}"
CF_INTERFACE="${CF_INTERFACE:-}"  # 指定网卡，留空则自动检测

# --- 获取当前 IPv6 地址 -------------------------------------------------------

# 判断是否为可用的公网 IPv6 地址（排除 link-local、ULA、loopback 等）
is_global_ipv6() {
    local ip
    ip=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    # 基本格式校验
    echo "$ip" | grep -qE '^([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}$' || return 1
    # 排除 link-local (fe80::/10)
    echo "$ip" | grep -qE '^fe[89ab]' && return 1
    # 排除 ULA (fc00::/7, fd00::/8)
    echo "$ip" | grep -qE '^f[c-d]' && return 1
    # 排除 loopback
    [ "$ip" = "::1" ] && return 1
    return 0
}

# 提取一行中的 IPv6 地址（从 ip 或 ifconfig 输出）
extract_ipv6() {
    sed -n 's/.*inet6[[:space:]]*\(addr:[[:space:]]*\)\{0,1\}\([0-9a-fA-F:]\+\).*/\2/p' | head -1
}

# 从本地网卡获取全局 IPv6 地址（QNAP 上最可靠的方式）
get_ipv6_from_local() {
    local ip=""
    local ifaces=""

    # 如果指定了网卡则只检查该网卡
    if [ -n "${CF_INTERFACE:-}" ]; then
        ifaces="$CF_INTERFACE"
    elif [ -d /sys/class/net ]; then
        ifaces=$(ls /sys/class/net/ 2>/dev/null)
    elif command -v ip >/dev/null 2>&1; then
        ifaces=$(ip -o link show 2>/dev/null | sed -n 's/^[0-9]\+: \([^:@]\+\).*/\1/p')
    fi

    for iface in $ifaces; do
        # 跳过 lo 和 docker/veth/virbr 等虚拟网卡
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*) continue ;;
        esac

        # 尝试用 ip 命令获取（先试 scope global，失败则不加过滤）
        if command -v ip >/dev/null 2>&1; then
            ip=$(ip -6 addr show dev "$iface" 2>/dev/null | grep 'scope global' | extract_ipv6)
            [ -z "$ip" ] && ip=$(ip -6 addr show dev "$iface" 2>/dev/null | extract_ipv6)
        fi

        # 如果 ip 命令不可用或无结果，尝试 ifconfig
        if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
            ip=$(ifconfig "$iface" 2>/dev/null | extract_ipv6)
        fi

        if [ -n "$ip" ] && is_global_ipv6 "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 通过外部服务获取出口 IPv6
get_ipv6_from_remote() {
    local ip=""
    local retries=("https://api6.ipify.org" "https://v6.ident.me" "https://icanhazip.com")

    for url in "${retries[@]}"; do
        # 先尝试 -6 强制 IPv6；某些 QNAP 的 curl 不支持 -6 则退化为不指定
        ip=$(curl -6 -s --max-time 10 "$url" 2>/dev/null) || true
        if [[ -z "$ip" ]]; then
            ip=$(curl -s --max-time 10 "$url" 2>/dev/null) || true
        fi
        if [[ -n "$ip" ]] && is_global_ipv6 "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

get_ipv6() {
    local ip=""

    # 方式1: 从本地网卡获取（QNAP NAS 最可靠）
    ip=$(get_ipv6_from_local) && [[ -n "$ip" ]] && { echo "$ip"; return 0; }

    # 方式2: 从外部服务获取
    ip=$(get_ipv6_from_remote) && [[ -n "$ip" ]] && { echo "$ip"; return 0; }

    log_err "无法获取 IPv6 地址，请确认 NAS 已获取 IPv6 公网地址"
    return 1
}

# --- Cloudflare API 操作 ------------------------------------------------------

cf_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local curl_args=(
        -s
        --max-time 15
        -X "$method"
        -H "Authorization: Bearer $CF_API_TOKEN"
        -H "Content-Type: application/json"
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    curl "${curl_args[@]}" "https://api.cloudflare.com/client/v4/$endpoint"
}

# 查找指定名称的 AAAA 记录，返回 record_id
# 如果存在非 AAAA 记录（如 CNAME）占用该名称，返回冲突信息
find_aaaa_record() {
    local record_name="$1"
    local resp

    # 查询该名称下的所有记录（不限类型）
    resp=$(cf_api_call "GET" "zones/$CF_ZONE_ID/dns_records?name=$record_name")

    local success
    success=$(echo "$resp" | grep -o '"success":[^,}]*' | head -1 | cut -d: -f2)

    if [ "$success" != "true" ]; then
        log_err "查询 DNS 记录失败"
        return 1
    fi

    # 检查是否有结果
    local result_count
    result_count=$(echo "$resp" | grep -o '"result_info":[^}]*"count":[0-9]*' | grep -o '"count":[0-9]*' | cut -d: -f2)

    if [ "$result_count" = "0" ] || [ -z "$result_count" ]; then
        # 无任何记录，返回空
        echo ""
        return 0
    fi

    # 查找 AAAA 类型记录
    local aaaa_id
    aaaa_id=$(echo "$resp" \
        | sed 's/},{/}\n{/g' \
        | grep '"type":"AAAA"' \
        | grep -o '"id":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4)

    if [ -n "$aaaa_id" ]; then
        echo "$aaaa_id"
        return 0
    fi

    # 存在记录但不是 AAAA 类型 — 冲突
    local conflict_type
    conflict_type=$(echo "$resp" \
        | sed 's/},{/}\n{/g' \
        | grep -o '"type":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4)
    log_err "域名 $record_name 已存在 $conflict_type 记录，无法创建 AAAA 记录"
    log_err "请在 Cloudflare 面板删除该 $conflict_type 记录后再试，或使用其他子域名"
    return 1
}

# 更新 DNS 记录
update_dns_record() {
    local record_id="$1"
    local record_name="$2"
    local ip="$3"
    local resp

    local data
    data=$(cat <<EOF
{
    "type": "AAAA",
    "name": "$record_name",
    "content": "$ip",
    "ttl": $CF_RECORD_TTL,
    "proxied": $CF_RECORD_PROXIED
}
EOF
)

    resp=$(cf_api_call "PATCH" "zones/$CF_ZONE_ID/dns_records/$record_id" "$data")

    local success
    success=$(echo "$resp" | grep -o '"success":[^,}]*' | head -1 | cut -d: -f2)

    if [[ "$success" != "true" ]]; then
        local errors
        errors=$(echo "$resp" | grep -o '"errors":\[.*\]' || echo "unknown")
        log_err "更新 DNS 记录失败: $errors"
        return 1
    fi

    return 0
}

# 解析 Cloudflare API 错误信息，输出友好提示
parse_cf_error() {
    local resp="$1"
    local code
    code=$(echo "$resp" | sed 's/},{/}\n{/g' | grep -o '"code":[0-9]*' | head -1 | cut -d: -f2)

    case "$code" in
        81053|81054)
            log_err "域名已被其他类型记录（如 CNAME）占用，请在 Cloudflare 面板检查" ;;
        10000)
            log_err "API 认证失败，请检查 CF_API_TOKEN 是否正确" ;;
        10001)
            log_err "请求参数错误，请检查 CF_ZONE_ID 是否正确" ;;
        *)  log_err "Cloudflare API 返回错误 (code=$code)" ;;
    esac
}

# 创建新的 AAAA 记录
create_dns_record() {
    local record_name="$1"
    local ip="$2"
    local resp

    local data
    data=$(cat <<EOF
{
    "type": "AAAA",
    "name": "$record_name",
    "content": "$ip",
    "ttl": $CF_RECORD_TTL,
    "proxied": $CF_RECORD_PROXIED
}
EOF
)

    resp=$(cf_api_call "POST" "zones/$CF_ZONE_ID/dns_records" "$data")

    local success
    success=$(echo "$resp" | grep -o '"success":[^,}]*' | head -1 | cut -d: -f2)

    if [ "$success" != "true" ]; then
        parse_cf_error "$resp"
        return 1
    fi

    # 提取新记录的 ID
    local id
    id=$(echo "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "$id"
}

# --- 主流程 -------------------------------------------------------------------

main() {
    # 获取当前 IPv6 地址
    local current_ip
    current_ip=$(get_ipv6) || exit 1
    log "当前 IPv6 地址: $current_ip"

    # 读取上次记录的地址
    local last_ip=""
    if [[ -f "$STATE_FILE" ]]; then
        last_ip=$(cat "$STATE_FILE" 2>/dev/null || true)
    fi

    # 如果地址未变化，无需更新
    if [[ "$current_ip" == "$last_ip" ]]; then
        log "IPv6 地址未变化，无需更新"
        exit 0
    fi

    log "IPv6 地址已变化: ${last_ip:-<无>} -> $current_ip"

    # 查找现有 AAAA 记录
    local record_id
    record_id=$(find_aaaa_record "$CF_RECORD_NAME") || exit 1

    if [[ -n "$record_id" ]]; then
        log "找到现有 DNS 记录: $record_id，执行更新..."
        update_dns_record "$record_id" "$CF_RECORD_NAME" "$current_ip" || exit 1
        log "DNS 记录更新成功"
    else
        log "未找到现有 DNS 记录，执行创建..."
        record_id=$(create_dns_record "$CF_RECORD_NAME" "$current_ip") || exit 1
        log "DNS 记录创建成功，ID: $record_id"
    fi

    # 保存当前地址
    echo "$current_ip" > "$STATE_FILE"
    log "IPv6 地址已保存到状态文件"
}

main
