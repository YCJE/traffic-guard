#!/usr/bin/env bash
#
# traffic-guard.sh — VPS 流量守护
#
# 按计费口径（上下行取最大值 / 仅上行 / 仅下行 / 双向总和）监控周期流量，
# 达到预警阈值发送通知，达到触发阈值自动关机，防止超出服务商流量额度被扣费。
#
# 用法: traffic-guard.sh {install|status|check [--dry-run]|test-notify|uninstall|help}
#
# 适用环境: Linux VPS，root 权限；systemd 优先，无 systemd 自动退回 cron。
# 统计后端: vnstat 2.x（推荐，重启不丢计数）或 /proc/net/dev + 持久状态文件。

set -o pipefail

VERSION="1.0.0"
SCRIPT_NAME="traffic-guard.sh"
INSTALL_PATH="/usr/local/bin/traffic-guard.sh"
CONFIG_FILE="${TRAFFIC_GUARD_CONFIG:-/etc/traffic-guard.conf}"
STATE_DIR="/var/lib/traffic-guard"
STATE_FILE="$STATE_DIR/proc-state"
META_FILE="$STATE_DIR/meta"
WARN_STAMP_FILE="$STATE_DIR/last-warn-date"
SERVICE_NAME="traffic-guard"

# ---------------------------------------------------------------- 基础工具

log() {
    echo "[$(date '+%F %T')] $*"
    command -v logger >/dev/null 2>&1 && logger -t "$SERVICE_NAME" "$*" 2>/dev/null
    return 0
}

die() {
    echo "错误: $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "此操作需要 root 权限，请用 sudo 运行"
}

# 1 GB 按 10^9 字节计算（与服务商计费口径保持一致，宁可略保守）
gb_to_bytes() {
    echo $(( $1 * 1000000000 ))
}

bytes_to_gb() {
    awk -v b="$1" 'BEGIN { printf "%.2f", b / 1000000000 }'
}

# ---------------------------------------------------------------- 周期计算

# 计算当前计费周期的起始日期（YYYY-MM-DD，本地时区）。
# $1 = 当前 epoch 秒（传固定值便于测试）；重置日 29/30/31 自动钳制到月末。
cycle_start_from() {
    local now="$1"
    local d m y rd ny nm last_day
    d=$(date -d "@$now" +%-d)
    m=$(date -d "@$now" +%-m)
    y=$(date -d "@$now" +%Y)
    rd=${RESET_DAY:-1}
    if [ "$d" -lt "$rd" ]; then
        if [ "$m" -eq 1 ]; then
            y=$((y - 1)); m=12
        else
            m=$((m - 1))
        fi
    fi
    if [ "$m" -eq 12 ]; then ny=$((y + 1)); nm=1; else ny=$y; nm=$((m + 1)); fi
    last_day=$(date -d "@$(( $(date -d "$(printf '%04d-%02d-01' "$ny" "$nm")" +%s) - 86400 ))" +%-d)
    [ "$rd" -gt "$last_day" ] && rd=$last_day
    printf '%04d-%02d-%02d' "$y" "$m" "$rd"
}

cycle_start() {
    cycle_start_from "$(date +%s)"
}

# ---------------------------------------------------------------- 计费口径

# apply_mode <rx_bytes> <tx_bytes> —— 按计费口径输出应计字节数
apply_mode() {
    local rx="$1" tx="$2"
    case "$MODE" in
        up)   echo "$tx" ;;
        down) echo "$rx" ;;
        both) echo $((rx + tx)) ;;
        *)    [ "$rx" -gt "$tx" ] && echo "$rx" || echo "$tx" ;;  # max
    esac
}

mode_label() {
    case "$MODE" in
        max)  echo "上下行取最大值" ;;
        up)   echo "仅上行" ;;
        down) echo "仅下行" ;;
        both) echo "双向总和" ;;
        *)    echo "$MODE" ;;
    esac
}

# ---------------------------------------------------------------- 网卡探测

detect_iface() {
    local iface=""
    if command -v ip >/dev/null 2>&1; then
        iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    fi
    if [ -z "$iface" ]; then
        iface=$(awk -F: '/:/ { name=$1; gsub(/^[ \t]+|[ \t]+$/, "", name);
                           if (name != "" && name != "lo") { print name; exit } }' /proc/net/dev 2>/dev/null)
    fi
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

iface_exists() {
    [ -e "/sys/class/net/$1" ]
}

# ---------------------------------------------------------------- 后端解析

vnstat_major() {
    vnstat --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 | cut -d. -f1
}

# 返回 vnstat 或 proc
resolve_backend() {
    case "$BACKEND" in
        proc) echo proc; return ;;
        vnstat)
            if command -v vnstat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
                local major; major=$(vnstat_major)
                if [ -n "$major" ] && [ "$major" -ge 2 ]; then echo vnstat; return; fi
            fi
            log "警告: 已配置 vnstat 后端但 vnstat 2.x / jq 不可用，降级为 proc 后端"
            echo proc; return ;;
    esac
    # auto
    if command -v vnstat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local major; major=$(vnstat_major)
        if [ -n "$major" ] && [ "$major" -ge 2 ]; then echo vnstat; return; fi
    fi
    echo proc
}

# ---------------------------------------------------------------- vnstat 后端

# vnstat_field <网卡> <起始日期> <rx|tx> —— 输出周期内累计字节数，失败返回 1
vnstat_field() {
    local iface="$1" start="$2" field="$3" j out
    j=$(vnstat -i "$iface" --json d -b "$start" 2>/dev/null) \
        || j=$(vnstat -i "$iface" --json d 2>/dev/null) \
        || return 1
    out=$(printf '%s' "$j" | jq -r --arg start "$start" --arg f "$field" '
        def dstr: (.date.year|tostring) + "-"
                + ((.date.month|tostring)|if length < 2 then "0" + . else . end) + "-"
                + ((.date.day|tostring)|if length < 2 then "0" + . else . end);
        def days: if .interfaces then [ .interfaces[] | (.traffic.day // .day // [])[] ]
                  else ((.traffic.day // .day) // [])[] end;
        [ days | select(.date != null) | select(dstr >= $start) | .[$f] ] | (add // 0)
    ' 2>/dev/null) || return 1
    case "$out" in ''|*[!0-9]*) return 1 ;; esac
    echo "$out"
}

# vnstat_usage <起始日期> —— 输出 "rx tx"，失败返回 1
vnstat_usage() {
    local start="$1" rx=0 tx=0 r t any=0 ifc
    local ifaces=()
    if [ "$INTERFACE" = "ALL" ]; then
        mapfile -t ifaces < <(ls /sys/class/net 2>/dev/null | grep -v '^lo$')
        [ "${#ifaces[@]}" -gt 0 ] || return 1
    else
        ifaces=("$INTERFACE")
    fi
    for ifc in "${ifaces[@]}"; do
        r=$(vnstat_field "$ifc" "$start" rx) || continue
        t=$(vnstat_field "$ifc" "$start" tx) || continue
        rx=$((rx + r)); tx=$((tx + t)); any=1
    done
    [ "$any" -eq 1 ] || return 1
    echo "$rx $tx"
}

# ---------------------------------------------------------------- proc 后端

# proc_raw <网卡名|ALL> —— 输出 "rx tx"（当前内核计数器原值）
proc_raw() {
    local sel="$1"
    awk -v sel="$sel" '
        /:/ {
            name = $1; sub(/:$/, "", name)
            if (name == "" || name == "lo") next
            if (sel != "ALL" && name != sel) next
            rx += $2; tx += $10
        }
        END { printf "%d %d\n", rx + 0, tx + 0 }
    ' /proc/net/dev 2>/dev/null
}

# proc_usage <起始日期> —— 读取/proc/net/dev 并借助持久状态文件跨重启累计，
# 输出 "rx tx"。状态文件记录 boot_id / 周期 / 累计值 / 上次原值。
proc_usage() {
    local start="$1"
    local raw boot btime ifset start_epoch
    raw=$(proc_raw "$INTERFACE") || return 1
    read -r raw_rx raw_tx <<<"$raw"
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    btime=$(awk '/^btime/ { print $2 }' /proc/stat 2>/dev/null)
    ifset=$(printf 'IF=%s' "$INTERFACE" | cksum | awk '{print $1}')
    start_epoch=$(date -d "$start" +%s)

    local s_boot="" s_cycle="" s_ifset="" s_cum_rx=0 s_cum_tx=0 s_last_rx="" s_last_tx=""
    if [ -r "$STATE_FILE" ]; then
        local k v
        while IFS='=' read -r k v; do
            case "$k" in
                boot)    s_boot="$v" ;;
                cycle)   s_cycle="$v" ;;
                ifset)   s_ifset="$v" ;;
                cum_rx)  s_cum_rx="$v" ;;
                cum_tx)  s_cum_tx="$v" ;;
                last_rx) s_last_rx="$v" ;;
                last_tx) s_last_tx="$v" ;;
            esac
        done < "$STATE_FILE"
    fi

    local delta_rx=0 delta_tx=0
    if [ -z "$s_boot" ]; then
        delta_rx=0; delta_tx=0    # 首次运行：从现在开始累计（安装时可填初始已用量补齐）
    elif [ -n "$s_ifset" ] && [ "$s_ifset" != "$ifset" ]; then
        log "警告: 监控接口发生变化，proc 后端流量计数重新从零累计"
        s_cum_rx=0; s_cum_tx=0
    else
        local cycle_changed=0 rebooted=0 raw_reset=0
        [ "$s_cycle" != "$start" ] && cycle_changed=1
        [ "$s_boot" != "$boot" ] && rebooted=1
        { [ -n "$s_last_rx" ] && [ "$raw_rx" -lt "$s_last_rx" ]; } && raw_reset=1
        if [ "$cycle_changed" -eq 1 ]; then
            s_cum_rx=0; s_cum_tx=0
            if [ "$rebooted" -eq 1 ] && [ -n "$btime" ] && [ "$btime" -ge "$start_epoch" ]; then
                delta_rx=$raw_rx; delta_tx=$raw_tx   # 重启发生在本周期内，开机以来的流量全部计入
            else
                delta_rx=0; delta_tx=0
            fi
        elif [ "$rebooted" -eq 1 ] || [ "$raw_reset" -eq 1 ]; then
            delta_rx=$raw_rx; delta_tx=$raw_tx       # 计数器归零（重启/重置），按当前原值累计
        elif [ -n "$s_last_rx" ]; then
            delta_rx=$((raw_rx - s_last_rx))
            delta_tx=$((raw_tx - s_last_tx))
        fi
    fi

    local cum_rx=$((s_cum_rx + delta_rx)) cum_tx=$((s_cum_tx + delta_tx))

    mkdir -p "$STATE_DIR"
    {
        printf 'boot=%s\n'    "$boot"
        printf 'cycle=%s\n'   "$start"
        printf 'ifset=%s\n'   "$ifset"
        printf 'cum_rx=%d\n'  "$cum_rx"
        printf 'cum_tx=%d\n'  "$cum_tx"
        printf 'last_rx=%d\n' "$raw_rx"
        printf 'last_tx=%d\n' "$raw_tx"
    } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"

    echo "$cum_rx $cum_tx"
}

# ---------------------------------------------------------------- 用量汇总

# 初始已用量（安装向导填写，仅对写入时的周期生效，跨周期自动失效）
initial_bytes_for() {
    local init=$(( ${INITIAL_GB:-0} * 1000000000 ))
    [ "$init" -gt 0 ] || { echo 0; return; }
    local ic
    ic=$(sed -n 's/^initial_cycle=//p' "$META_FILE" 2>/dev/null)
    if [ "$ic" != "$1" ]; then
        mkdir -p "$STATE_DIR"
        printf 'initial_cycle=%s\n' "$1" > "$META_FILE.tmp" && mv "$META_FILE.tmp" "$META_FILE"
    fi
    echo "$init"
}

# collect_usage <后端> <起始日期> —— 设置全局 RX / TX / USED，失败返回 1
collect_usage() {
    local backend="$1" start="$2" out rx tx used
    if [ "$backend" = "vnstat" ]; then
        out=$(vnstat_usage "$start") || return 1
    else
        out=$(proc_usage "$start") || return 1
    fi
    read -r rx tx <<<"$out"
    case "$rx$tx" in ''|*[!0-9]*) return 1 ;; esac
    used=$(( $(apply_mode "$rx" "$tx") + $(initial_bytes_for "$start") ))
    RX=$rx; TX=$tx; USED=$used
    return 0
}

# ---------------------------------------------------------------- 通知

send_notify() {
    local title="$1" body="$2" ok=""
    case "$NOTIFY_TYPE" in
        telegram)
            [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || { log "Telegram 未配置完整，跳过通知"; return 1; }
            ok=$(curl -sm 8 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                 --data-urlencode "chat_id=${TG_CHAT_ID}" \
                 --data-urlencode "text=${title}
${body}" 2>/dev/null) ;;
        serverchan)
            [ -n "$SERVERCHAN_KEY" ] || { log "Server酱未配置，跳过通知"; return 1; }
            ok=$(curl -sm 8 "https://sctapi.ftqq.com/${SERVERCHAN_KEY}.send" \
                 --data-urlencode "title=${title}" \
                 --data-urlencode "desp=${body}" 2>/dev/null) ;;
        bark)
            [ -n "$BARK_KEY" ] || { log "Bark 未配置，跳过通知"; return 1; }
            local bark_url="${BARK_URL:-https://api.day.app}"
            local et eb
            et=${title//\\/\\\\}; et=${et//\"/\\\"}
            eb=${body//\\/\\\\};  eb=${eb//\"/\\\"}; eb=${eb//$'\n'/ }
            ok=$(curl -sm 8 -H 'Content-Type: application/json; charset=utf-8' \
                 -d "{\"device_key\":\"${BARK_KEY}\",\"title\":\"${et}\",\"body\":\"${eb}\",\"group\":\"traffic-guard\"}" \
                 "${bark_url}/push" 2>/dev/null) ;;
        custom)
            [ -n "$NOTIFY_CMD" ] || { log "自定义通知命令未配置，跳过"; return 1; }
            bash -c "$NOTIFY_CMD" traffic-guard "$title: $body"
            return 0 ;;
        *)
            return 0 ;;
    esac
    case "$NOTIFY_TYPE" in
        telegram|serverchan|bark)
            if printf '%s' "$ok" | grep -qi '"ok"[ ]*:[ ]*true\|"code"[ ]*:[ ]*"?0"?[^0-9]\|"code"[ ]*:[ ]*"?200'; then
                log "通知已发送 ($NOTIFY_TYPE)"
                return 0
            fi
            log "通知发送可能失败 ($NOTIFY_TYPE): $ok"
            return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 配置

load_config() {
    [ -r "$CONFIG_FILE" ] || {
        echo "未找到配置文件 $CONFIG_FILE，请先运行: $SCRIPT_NAME install" >&2
        return 1
    }
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"

    INTERFACE=${INTERFACE:-auto}
    MODE=${MODE:-max}
    LIMIT_GB=${LIMIT_GB:-200}
    BUFFER_GB=${BUFFER_GB:-10}
    WARN_GB=${WARN_GB:-0}
    RESET_DAY=${RESET_DAY:-1}
    INITIAL_GB=${INITIAL_GB:-0}
    CHECK_INTERVAL=${CHECK_INTERVAL:-60}
    NOTIFY_TYPE=${NOTIFY_TYPE:-none}
    BACKEND=${BACKEND:-auto}
    [ "$CHECK_INTERVAL" -lt 10 ] && CHECK_INTERVAL=10

    if [ "$INTERFACE" = "auto" ] || [ -z "$INTERFACE" ]; then
        INTERFACE=$(detect_iface)
    fi

    case "$MODE" in max|up|down|both) ;; *) die "配置错误: MODE=$MODE（应为 max/up/down/both）" ;; esac
    case "$LIMIT_GB$BUFFER_GB$WARN_GB$RESET_DAY$INITIAL_GB" in ''|*[!0-9]*)
        die "配置错误: LIMIT_GB / BUFFER_GB / WARN_GB / RESET_DAY / INITIAL_GB 必须是非负整数" ;; esac
    [ "$RESET_DAY" -ge 1 ] && [ "$RESET_DAY" -le 31 ] || die "配置错误: RESET_DAY 应为 1-31"
    [ "$BUFFER_GB" -lt "$LIMIT_GB" ] || die "配置错误: BUFFER_GB 必须小于 LIMIT_GB"
    return 0
}

# ---------------------------------------------------------------- 子命令

do_status() {
    load_config || exit 1
    local backend start
    backend=$(resolve_backend)
    start=$(cycle_start)
    collect_usage "$backend" "$start" || {
        echo "无法获取流量数据（后端: $backend）。"
        [ "$backend" = "vnstat" ] && echo "请确认 vnstat/jq 已安装、vnstat 服务正在运行，且网卡已加入 vnstat 数据库。"
        exit 1
    }
    local limit_bytes shut_bytes pct remain_limit remain_shut
    limit_bytes=$(gb_to_bytes "$LIMIT_GB")
    shut_bytes=$(gb_to_bytes $((LIMIT_GB - BUFFER_GB)))
    pct=$(awk -v u="$USED" -v l="$limit_bytes" 'BEGIN { printf "%.1f", u * 100 / l }')
    remain_limit=$(awk -v l="$limit_bytes" -v u="$USED" 'BEGIN { printf "%.2f", (l > u ? l - u : 0) / 1e9 }')
    remain_shut=$(awk -v s="$shut_bytes" -v u="$USED" 'BEGIN { printf "%.2f", (s > u ? s - u : 0) / 1e9 }')
    cat <<EOF
================ traffic-guard 状态 ================
统计后端    : $backend
监控接口    : $INTERFACE
计费口径    : $(mode_label)
本周期起始  : $start（每月 ${RESET_DAY} 日重置）
上行 rx     : $(bytes_to_gb "$RX") GB
下行 tx     : $(bytes_to_gb "$TX") GB
初始已用    : ${INITIAL_GB} GB
计费用量    : $(bytes_to_gb "$USED") GB / ${LIMIT_GB} GB（${pct}%）
预警阈值    : $([ "$WARN_GB" -gt 0 ] && echo "${WARN_GB} GB" || echo "未启用")
关机阈值    : $(bytes_to_gb "$shut_bytes") GB（上限 - 缓冲 ${BUFFER_GB} GB）
剩余可用    : 到上限 $remain_limit GB / 到关机阈值 $remain_shut GB
通知方式    : $NOTIFY_TYPE
====================================================
提示: 请与服务商面板用量对账；若面板数值明显更高，调大 BUFFER_GB。
EOF
}

do_check() {
    local dryrun=0
    [ "${1:-}" = "--dry-run" ] && dryrun=1
    load_config || exit 1

    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$STATE_DIR"
        exec 9>"$STATE_DIR/.lock"
        flock -n 9 || { log "上一次检查尚未结束，跳过本次"; exit 0; }
    fi

    local backend start
    backend=$(resolve_backend)
    start=$(cycle_start)
    collect_usage "$backend" "$start" || {
        log "错误: 无法获取流量数据（后端 $backend），本次跳过检查"
        exit 1
    }

    local limit_bytes shut_bytes warn_bytes
    limit_bytes=$(gb_to_bytes "$LIMIT_GB")
    shut_bytes=$(gb_to_bytes $((LIMIT_GB - BUFFER_GB)))
    warn_bytes=0
    [ "$WARN_GB" -gt 0 ] && warn_bytes=$(gb_to_bytes "$WARN_GB")

    log "检查: 周期 $start 已用 $(bytes_to_gb "$USED")GB / ${LIMIT_GB}GB" \
        "(rx=$(bytes_to_gb "$RX") tx=$(bytes_to_gb "$TX") 口径:$(mode_label) 后端:$backend)"

    if [ "$USED" -ge "$shut_bytes" ]; then
        log "已用流量达到触发阈值 $(bytes_to_gb "$shut_bytes")GB，执行保护动作: 关机"
        if [ "$dryrun" -eq 1 ]; then
            log "[dry-run] 演练模式：跳过通知与关机。实际运行将立即关机！"
            return 0
        fi
        send_notify "traffic-guard 警告" "本周期流量已达 $(bytes_to_gb "$USED")GB（上限 ${LIMIT_GB}GB），VPS 即将自动关机！"
        sleep 3
        log "正在关机..."
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            systemctl poweroff
        else
            command -v poweroff >/dev/null 2>&1 && poweroff || shutdown -h now
        fi
        return 0
    fi

    if [ "$warn_bytes" -gt 0 ] && [ "$USED" -ge "$warn_bytes" ]; then
        local today last
        today=$(date +%F)
        last=$(cat "$WARN_STAMP_FILE" 2>/dev/null)
        if [ "$last" != "$today" ]; then
            if [ "$dryrun" -eq 1 ]; then
                log "[dry-run] 已达到预警阈值，将发送预警通知（每日最多一次）"
            else
                send_notify "traffic-guard 预警" \
                    "本周期流量已达 $(bytes_to_gb "$USED")GB / 上限 ${LIMIT_GB}GB，接近关机阈值 $(bytes_to_gb "$shut_bytes")GB，请注意！"
                printf '%s\n' "$today" > "$WARN_STAMP_FILE" 2>/dev/null || true
                log "已发送预警通知（每日最多一次）"
            fi
        fi
    fi
}

do_test_notify() {
    load_config || exit 1
    if [ "$NOTIFY_TYPE" = "none" ]; then
        echo "当前通知方式为 none（未启用）。重新运行 install 可配置通知渠道。"
        return 0
    fi
    echo "正在通过 $NOTIFY_TYPE 发送测试通知..."
    if send_notify "traffic-guard 测试" "如果你看到这条消息，说明通知渠道配置成功 ✅"; then
        echo "测试通知已发送，请查收。"
    else
        echo "测试通知发送失败，请检查配置中的 token/key。" >&2
        return 1
    fi
}

do_uninstall() {
    need_root
    if [ -d /run/systemd/system ]; then
        systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/etc/systemd/system/${SERVICE_NAME}.timer"
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -f "/etc/cron.d/${SERVICE_NAME}" "$INSTALL_PATH"
    echo "已卸载定时任务与脚本副本。"
    echo "配置与历史数据已保留（$CONFIG_FILE、$STATE_DIR），如需彻底清理请手动删除。"
}

# ---------------------------------------------------------------- 安装向导

ask() { # ask <提示> <默认值> —— 输出用户输入（回车用默认值）
    local v
    read -rp "$1 [$2]: " v
    echo "${v:-$2}"
}

ask_int() { # ask_int <提示> <默认值> —— 循环直到输入非负整数
    local v
    while :; do
        v=$(ask "$1" "$2")
        case "$v" in ''|*[!0-9]*) echo "  请输入非负整数" >&2 ;; *) break ;; esac
    done
    echo "$v"
}

pkg_install() { # pkg_install <包名>... —— 尽力而为的包安装
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q epel-release 2>/dev/null
        dnf install -y -q "$@"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q epel-release 2>/dev/null
        yum install -y -q "$@"
    elif command -v apk >/dev/null 2>&1; then
        apk add -q "$@"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install "$@"
    else
        return 1
    fi
}

ensure_vnstat() {
    if ! command -v vnstat >/dev/null 2>&1; then
        echo "未检测到 vnstat，尝试自动安装（vnstat + jq）..."
        pkg_install vnstat jq || true
    elif ! command -v jq >/dev/null 2>&1; then
        echo "未检测到 jq，尝试自动安装..."
        pkg_install jq || true
    fi
    if command -v vnstat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local major; major=$(vnstat_major)
        if [ -n "$major" ] && [ "$major" -ge 2 ]; then
            [ -d /run/systemd/system ] && systemctl enable --now vnstat >/dev/null 2>&1 || true
            return 0
        fi
        echo "检测到 vnstat 版本过旧（$major.x），将使用 proc 后端。"
    fi
    return 1
}

vnstat_add_iface() {
    command -v vnstat >/dev/null 2>&1 || return 0
    local ifc
    for ifc in "$@"; do
        vnstat --add -i "$ifc" >/dev/null 2>&1 || true
    done
}

install_scheduler() {
    if [ -d /run/systemd/system ]; then
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=traffic-guard flow check
After=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH check
EOF
        cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Run traffic-guard check periodically

[Timer]
OnBootSec=45s
OnUnitActiveSec=${CHECK_INTERVAL}s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl disable --now "${SERVICE_NAME}.timer" >/dev/null 2>&1 || true
        systemctl enable --now "${SERVICE_NAME}.timer" >/dev/null
        echo "✔ 已安装 systemd timer（每 ${CHECK_INTERVAL} 秒检查一次，开机自启）"
    else
        cat > "/etc/cron.d/${SERVICE_NAME}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $INSTALL_PATH check >/dev/null 2>&1
EOF
        chmod 644 "/etc/cron.d/${SERVICE_NAME}"
        echo "✔ 已安装 cron 定时任务（每分钟检查一次）"
        [ "$CHECK_INTERVAL" -ne 60 ] && echo "注意: cron 最小粒度为 1 分钟，CHECK_INTERVAL=$CHECK_INTERVAL 将按 60 秒生效"
    fi
}

do_install() {
    need_root

    echo "=============================================="
    echo "  traffic-guard v$VERSION 安装向导"
    echo "  （各项均有默认值，直接回车采用默认值）"
    echo "=============================================="
    echo

    # 1. 监控网卡
    local detected
    detected=$(detect_iface)
    echo "检测到默认路由网卡: $detected"
    local iface
    while :; do
        iface=$(ask "监控哪个网卡（输入 ALL 统计所有非 lo 网卡）" "$detected")
        if [ "$iface" = "ALL" ] || iface_exists "$iface"; then break; fi
        echo "  网卡 $iface 不存在，请重新输入"
    done

    # 2. 计费上限
    local limit
    limit=$(ask_int "流量上限多少 GB" 200)

    # 3. 计费口径
    echo "计费口径:"
    echo "  1) 上下行取最大值（多数 VPS 的计费方式）"
    echo "  2) 仅上行"
    echo "  3) 仅下行"
    echo "  4) 双向总和"
    local mode_choice mode
    mode_choice=$(ask "请选择 [1-4]" "1")
    case "$mode_choice" in
        2) mode=up ;; 3) mode=down ;; 4) mode=both ;; *) mode=max ;;
    esac

    # 4. 安全缓冲
    local buffer
    while :; do
        buffer=$(ask_int "安全缓冲多少 GB（触发阈值 = 上限 - 缓冲）" 10)
        if [ "$buffer" -lt "$limit" ]; then break; fi
        echo "  缓冲必须小于上限 $limit"
    done

    # 5. 预警阈值
    local warn_def=$(( limit - buffer - 30 > 0 ? limit - buffer - 30 : 0 ))
    local warn
    while :; do
        warn=$(ask_int "预警阈值多少 GB（达到后推送提醒，0 = 不预警）" "$warn_def")
        if [ "$warn" -lt $(( limit - buffer )) ]; then break; fi
        echo "  预警阈值应小于触发阈值 $(( limit - buffer ))"
    done

    # 6. 重置日
    local reset_day
    while :; do
        reset_day=$(ask_int "每月几号重置流量统计（1-31，29/30/31 小月自动按月末处理）" 1)
        if [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ]; then break; fi
        echo "  请输入 1-31"
    done

    # 7. 初始已用
    echo "提示: 本脚本从安装时刻开始统计。若本周期已经用掉一部分流量，"
    echo "      请到服务商面板查看当前已用量并填入，否则会少统计。"
    local initial
    initial=$(ask_int "本周期已用流量多少 GB（不清楚填 0）" 0)

    # 8. 检查间隔
    local interval
    interval=$(ask_int "检查间隔多少秒（systemd 生效，cron 固定 60 秒）" 60)
    [ "$interval" -lt 10 ] && interval=10

    # 9. 通知方式
    echo "通知方式:"
    echo "  0) 不通知，达到阈值直接关机"
    echo "  1) Telegram Bot"
    echo "  2) Server酱（微信推送）"
    echo "  3) Bark（iOS 推送）"
    echo "  4) 自定义命令（消息文本作为 \$1 传入）"
    local notify_choice notify_type tg_token="" tg_chat="" sc_key="" bark_key="" bark_url="" custom_cmd=""
    notify_choice=$(ask "请选择 [0-4]" "0")
    case "$notify_choice" in
        1)
            notify_type=telegram
            tg_token=$(ask "Telegram Bot Token" "")
            tg_chat=$(ask "Telegram Chat ID" "") ;;
        2)
            notify_type=serverchan
            sc_key=$(ask "Server酱 SendKey" "") ;;
        3)
            notify_type=bark
            bark_key=$(ask "Bark Device Key" "")
            bark_url=$(ask "Bark 服务器地址（官方则回车）" "https://api.day.app") ;;
        4)
            notify_type=custom
            custom_cmd=$(ask "自定义命令（例如: curl -sm5 https://hook.example --data-urlencode \"msg=\$1\"）" "") ;;
        *) notify_type=none ;;
    esac

    # 10. 统计后端
    local backend_note="proc（无需额外依赖）"
    if ensure_vnstat; then
        backend_note="vnstat（推荐，重启不丢计数）"
        if [ "$iface" = "ALL" ]; then
            vnstat_add_iface $(ls /sys/class/net 2>/dev/null | grep -v '^lo$')
        else
            vnstat_add_iface "$iface"
        fi
    else
        echo "vnstat 不可用，将使用 proc 后端（通过状态文件跨重启累计）。"
    fi
    BACKEND=auto
    local resolved_backend
    resolved_backend=$(resolve_backend)

    # 汇总确认
    echo
    echo "---------------- 配置确认 ----------------"
    echo "  监控网卡 : $iface"
    echo "  计费上限 : ${limit} GB"
    echo "  计费口径 : $(MODE=$mode mode_label)"
    echo "  安全缓冲 : ${buffer} GB（达到 $(( limit - buffer )) GB 关机）"
    echo "  预警阈值 : $([ "$warn" -gt 0 ] && echo "${warn} GB" || echo "不预警")"
    echo "  重置日期 : 每月 ${reset_day} 日"
    echo "  初始已用 : ${initial} GB"
    echo "  检查间隔 : ${interval} 秒"
    echo "  通知方式 : $notify_type"
    echo "  统计后端 : $resolved_backend（$backend_note）"
    echo "------------------------------------------"
    local confirm
    confirm=$(ask "确认写入配置并安装? (y/n)" "y")
    case "$confirm" in n|N|no|NO) echo "已取消安装"; return 1 ;; esac

    # 写配置
    mkdir -p "$STATE_DIR"
    ( umask 077; cat > "$CONFIG_FILE" <<EOF
# /etc/traffic-guard.conf — 由 traffic-guard.sh install 生成
INTERFACE="$iface"
LIMIT_GB=$limit
MODE="$mode"
BUFFER_GB=$buffer
WARN_GB=$warn
RESET_DAY=$reset_day
INITIAL_GB=$initial
CHECK_INTERVAL=$interval
NOTIFY_TYPE="$notify_type"
TG_BOT_TOKEN="$tg_token"
TG_CHAT_ID="$tg_chat"
SERVERCHAN_KEY="$sc_key"
BARK_KEY="$bark_key"
BARK_URL="$bark_url"
NOTIFY_CMD='$custom_cmd'
BACKEND="$resolved_backend"
EOF
    )
    chmod 600 "$CONFIG_FILE"

    # 安装脚本本体与定时任务
    local self
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$self" != "$INSTALL_PATH" ]; then
        cp -f "$self" "$INSTALL_PATH" && chmod 755 "$INSTALL_PATH"
    fi
    install_scheduler

    # 通知自检
    if [ "$notify_type" != "none" ]; then
        echo
        echo "发送测试通知..."
        NOTIFY_TYPE="$notify_type" TG_BOT_TOKEN="$tg_token" TG_CHAT_ID="$tg_chat" \
        SERVERCHAN_KEY="$sc_key" BARK_KEY="$bark_key" BARK_URL="$bark_url" NOTIFY_CMD="$custom_cmd" \
        send_notify "traffic-guard 测试" "安装成功，通知渠道工作正常 ✅" \
            && echo "测试通知已发送，请查收。" \
            || echo "测试通知发送失败，可稍后运行 traffic-guard test-notify 重试。"
    fi

    echo
    echo "✔ 安装完成！常用命令:"
    echo "    traffic-guard status            查看当前用量（可与服务商面板对账）"
    echo "    traffic-guard check --dry-run   演练检查（不会真的关机）"
    echo "    traffic-guard test-notify       重发测试通知"
    echo "    traffic-guard uninstall         卸载"
    echo
    echo "建议先跑一天 dry-run 并与服务商面板对账，确认口径后再放心使用。"
}

usage() {
    cat <<EOF
traffic-guard.sh v$VERSION — VPS 流量守护（按计费口径监控流量，超限自动关机）

用法:
  $SCRIPT_NAME install              交互式安装（配置 + 依赖 + 定时任务）
  $SCRIPT_NAME status               查看当前周期用量
  $SCRIPT_NAME check [--dry-run]    执行检查（定时任务调用；--dry-run 演练不关机）
  $SCRIPT_NAME test-notify          发送测试通知
  $SCRIPT_NAME uninstall            卸载定时任务与脚本副本
  $SCRIPT_NAME help                 显示本帮助
EOF
}

main() {
    case "${1:-}" in
        install)     shift; do_install "$@" ;;
        status)      do_status ;;
        check)       shift; do_check "$@" ;;
        test-notify) do_test_notify ;;
        uninstall)   do_uninstall ;;
        -h|--help|help|"") usage ;;
        *) usage; die "未知命令: $1" ;;
    esac
}

# 供单元测试 source（TRAFFIC_GUARD_NO_MAIN=1 时跳过执行）
if [ -z "${TRAFFIC_GUARD_NO_MAIN:-}" ]; then
    main "$@"
fi
