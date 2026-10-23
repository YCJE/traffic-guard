#!/usr/bin/env bash
#
# traffic-guard.sh — VPS 流量守护
#
# 按计费口径（上下行取最大值 / 仅上行 / 仅下行 / 双向总和）监控周期流量，
# 达到预警阈值发送通知，达到触发阈值自动关机，防止超出服务商流量额度被扣费。
#
# 用法: traffic-guard {install|menu|status|check [--dry-run]|test-notify|upgrade|uninstall|help}
# 直接输入 traffic-guard 进入交互式管理菜单（类似 x-ui 面板）。
#
# 一键安装: bash <(curl -fsSL https://raw.githubusercontent.com/YCJE/traffic-guard/main/install.sh)
#
# 适用环境: Linux VPS，root 权限；systemd 优先，无 systemd 自动退回 cron。
# 统计后端: vnstat 2.x（推荐，重启不丢计数）或 /proc/net/dev + 持久状态文件。

set -o pipefail

VERSION="1.2.2"
SCRIPT_NAME="traffic-guard"
INSTALL_PATH="/usr/local/bin/traffic-guard"
LEGACY_PATH="/usr/local/bin/traffic-guard.sh"
CONFIG_FILE="${TRAFFIC_GUARD_CONFIG:-/etc/traffic-guard.conf}"
STATE_DIR="/var/lib/traffic-guard"
STATE_FILE="$STATE_DIR/proc-state"
META_FILE="$STATE_DIR/meta"
WARN_STAMP_FILE="$STATE_DIR/last-warn-date"
SERVICE_NAME="traffic-guard"

# ---------------------------------------------------------------- 基础工具

# 日志统一输出到 stderr: 部分调用方处于命令替换 $(...) 中（如 proc_usage），
# 写 stdout 会混入其返回值导致解析失败
log() {
    echo "[$(date '+%F %T')] $*" >&2
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

# 配置文件转义: 用户输入写入 /etc/traffic-guard.conf 前必须转义，
# 否则含引号/$/反引号的值会破坏配置语法甚至改变语义
dq_escape() { # 双引号上下文
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\$}; s=${s//\`/\\\`}
    printf '%s' "$s"
}
sq_escape() { # 单引号上下文
    local s=$1
    s=${s//\'/\'\\\'\'}
    printf '%s' "$s"
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

# vnstat_field <网卡> <起始日期> <rx|tx> —— 结果写入全局变量 VNSTAT_VAL。
# 不用 echo 返回值: 调用方需要带回 VNSTAT_NOTE 提示编号，而命令替换子 shell
# 中的变量赋值不会传播到父进程，stdout 通道只留给返回值会两头顾此失彼。
# 刚安装后 vnstat 尚未写入首份数据（默认保存间隔最长约 5 分钟）、或网卡未加入
# 数据库时，查询会报错；这两种情况按 0 处理并设置提示 VNSTAT_NOTE，不视为致命错误。
# VNSTAT_NOTE: 1=暂无数据  2=网卡未入库  3=数据库读取异常
vnstat_field() {
    VNSTAT_VAL=0
    local iface="$1" start="$2" field="$3" j out
    j=$(vnstat -i "$iface" --json d -b "$start" 2>&1)
    if [ $? -ne 0 ]; then
        case "$j" in
            *"Not enough data"*|*"not enough data"*)
                [ -z "$VNSTAT_NOTE" ] && VNSTAT_NOTE=1
                return 0 ;;
            *"nable to find interface"*|*"o such interface"*|*"ot found"*)
                VNSTAT_NOTE=2
                return 0 ;;
            *atabase*)
                [ -z "$VNSTAT_NOTE" ] && VNSTAT_NOTE=3
                return 0 ;;
        esac
        # -b 参数可能不被支持，去掉日期参数重试
        j=$(vnstat -i "$iface" --json d 2>/dev/null) || {
            [ -z "$VNSTAT_NOTE" ] && VNSTAT_NOTE=1
            return 0
        }
    fi
    out=$(printf '%s' "$j" | jq -r --arg start "$start" --arg f "$field" '
        def dstr: (.date.year|tostring) + "-"
                + ((.date.month|tostring)|if length < 2 then "0" + . else . end) + "-"
                + ((.date.day|tostring)|if length < 2 then "0" + . else . end);
        def days: if .interfaces then [ .interfaces[] | (.traffic.day // .day // [])[] ]
                  else ((.traffic.day // .day) // [])[] end;
        [ days | select(.date != null) | select(dstr >= $start) | .[$f] ] | (add // 0)
    ' 2>/dev/null) || { VNSTAT_NOTE=3; return 1; }
    case "$out" in ''|*[!0-9]*) VNSTAT_NOTE=3; return 1 ;; esac
    VNSTAT_VAL=$out
    return 0
}

# vnstat_usage <起始日期> —— 成功时累加全局 RX/TX 并返回 0。
# 必须直接调用（勿放子 shell），VNSTAT_NOTE/VNSTAT_VAL 才能带回调用方；
# 调用方需先把 RX/TX 初始化为 0。
vnstat_usage() {
    local start="$1" r t any=0 ifc
    local ifaces=()
    if [ "$INTERFACE" = "ALL" ]; then
        # 优先汇总已入库的网卡；拿不到列表时退回所有非 lo 网卡
        local present
        present=$(vnstat --dbiflist 2>/dev/null || true)
        if [ -n "$present" ]; then
            mapfile -t ifaces < <(printf '%s\n' $present | while read -r i; do
                iface_exists "$i" 2>/dev/null && echo "$i"
            done)
        fi
        [ "${#ifaces[@]}" -gt 0 ] || mapfile -t ifaces < <(ls /sys/class/net 2>/dev/null | grep -v '^lo$')
        [ "${#ifaces[@]}" -gt 0 ] || return 1
    else
        ifaces=("$INTERFACE")
    fi
    for ifc in "${ifaces[@]}"; do
        if vnstat_field "$ifc" "$start" rx; then
            r=$VNSTAT_VAL
            if vnstat_field "$ifc" "$start" tx; then
                t=$VNSTAT_VAL
                RX=$((RX + r)); TX=$((TX + t)); any=1
            fi
        fi
    done
    [ "$any" -eq 1 ] || return 1
    return 0
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
    # 与并发的 status/check 互斥，防止状态文件 read-modify-write 丢失更新。
    # 用独立锁文件（do_check 已持有 .lock，同进程对不同 fd 加锁同一文件会死锁）
    if command -v flock >/dev/null 2>&1 && mkdir -p "$STATE_DIR" 2>/dev/null; then
        exec 8>>"$STATE_DIR/.statelock" && flock 8
    fi
    local raw boot btime ifset start_epoch
    raw=$(proc_raw "$INTERFACE") || return 1
    read -r raw_rx raw_tx <<<"$raw"
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    btime=$(awk '/^btime/ { print $2 }' /proc/stat 2>/dev/null)
    # boot_id 缺失（2.6.39 之前的老内核/OpenVZ）时以内核启动时间作为重启身份，
    # 否则每次运行都会被当作首次运行，计数永远为 0
    if [ -z "$boot" ] && [ -n "$btime" ]; then
        boot="btime-$btime"
    fi
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
        # 数值字段被破坏（手改/磁盘故障）时按状态缺失处理，
        # 否则会进入算术表达式报错或产生计数跳变
        local sf_bad=0
        for v in "$s_cum_rx" "$s_cum_tx"; do
            case "$v" in ''|*[!0-9]*) sf_bad=1 ;; esac
        done
        if [ "$sf_bad" -eq 0 ] && [ -n "$s_last_rx" ]; then
            case "$s_last_rx$s_last_tx" in ''|*[!0-9]*) sf_bad=1 ;; esac
        fi
        if [ "$sf_bad" -eq 1 ]; then
            log "警告: 状态文件损坏，proc 后端计数从头累计"
            s_boot=""; s_cycle=""; s_ifset=""; s_cum_rx=0; s_cum_tx=0; s_last_rx=""; s_last_tx=""
        fi
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

# 初始已用量: 仅对安装/重装时记录的周期（META_FILE 中的 initial_cycle）生效，
# 跨周期自动失效。META 由 do_install 写入，查询侧只读、无副作用（本函数会在
# 命令替换中执行，任何 stdout 之外的输出都会破坏返回值）。
initial_bytes_for() {
    local init=$(( ${INITIAL_GB:-0} * 1000000000 ))
    [ "$init" -gt 0 ] || { echo 0; return; }
    local ic
    ic=$(sed -n 's/^initial_cycle=//p' "$META_FILE" 2>/dev/null)
    [ "$ic" = "$1" ] && echo "$init" || echo 0
}

# collect_usage <后端> <起始日期> —— 设置全局 RX / TX / USED，失败返回 1。
# VNSTAT_NOTE 为空表示数据正常，非空时携带提示编号（1/2/3）。
collect_usage() {
    local backend="$1" start="$2" rx=0 tx=0 used out
    VNSTAT_NOTE=""
    if [ "$backend" = "vnstat" ]; then
        RX=0; TX=0
        vnstat_usage "$start" || return 1
        rx=$RX; tx=$TX
    else
        out=$(proc_usage "$start") || return 1
        read -r rx tx <<<"$out"
        case "$rx$tx" in ''|*[!0-9]*) return 1 ;; esac
    fi
    used=$(( $(apply_mode "$rx" "$tx") + $(initial_bytes_for "$start") ))
    RX=$rx; TX=$tx; USED=$used
    return 0
}

# vnstat_note_text —— 把 VNSTAT_NOTE 编号转成人类可读提示
vnstat_note_text() {
    case "$VNSTAT_NOTE" in
        1) echo "vnstat 本周期暂无数据：刚安装后几分钟内属正常（首次写入最长约 5 分钟），随后自动开始累计" ;;
        2) echo "网卡 $INTERFACE 未加入 vnstat 数据库，统计将一直为 0！修复: sudo vnstat --add -i $INTERFACE（或重新运行 traffic-guard install）" ;;
        3) echo "vnstat 数据库读取异常，建议检查 vnstat 服务状态，或将配置中 BACKEND 改为 \"proc\"" ;;
        *) echo "" ;;
    esac
}

# ---------------------------------------------------------------- 通知

send_notify() {
    local title="$1" body="$2" ok=""
    # et/eb 为 JSON 转义版；走 curl --data-urlencode 的渠道直接用原文
    local et eb
    et=${title//\\/\\\\}; et=${et//\"/\\\"}
    eb=${body//\\/\\\\};  eb=${eb//\"/\\\"}; eb=${eb//$'\n'/ }
    case "$NOTIFY_TYPE" in
        telegram)
            [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || { log "Telegram 未配置完整，跳过通知"; return 1; }
            local tg_base="${TG_API_BASE:-https://api.telegram.org}"
            ok=$(curl -sm 8 "${tg_base}/bot${TG_BOT_TOKEN}/sendMessage" \
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
            ok=$(curl -sm 8 -H 'Content-Type: application/json; charset=utf-8' \
                 -d "{\"device_key\":\"${BARK_KEY}\",\"title\":\"${et}\",\"body\":\"${eb}\",\"group\":\"traffic-guard\"}" \
                 "${bark_url}/push" 2>/dev/null) ;;
        wecom)
            [ -n "$WECOM_KEY" ] || { log "企业微信未配置，跳过通知"; return 1; }
            ok=$(curl -sm 8 -H 'Content-Type: application/json; charset=utf-8' \
                 -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"${et} ${eb}\"}}" \
                 "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=${WECOM_KEY}" 2>/dev/null) ;;
        dingtalk)
            [ -n "$DING_TOKEN" ] || { log "钉钉未配置，跳过通知"; return 1; }
            local durl="https://oapi.dingtalk.com/robot/send?access_token=${DING_TOKEN}"
            if [ -n "$DING_SECRET" ]; then
                if command -v openssl >/dev/null 2>&1; then
                    local ts sign
                    ts=$(date +%s%3N 2>/dev/null)
                    case "$ts" in ''|*[!0-9]*) ts=$(( $(date +%s) * 1000 )) ;; esac
                    sign=$(printf '%s\n%s' "$ts" "$DING_SECRET" \
                           | openssl dgst -sha256 -hmac "$DING_SECRET" -binary 2>/dev/null \
                           | base64 | tr -d '\n')
                    durl="${durl}&timestamp=${ts}&sign=$(printf '%s' "$sign" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"
                else
                    log "警告: 配置了钉钉加签但缺少 openssl，本次按无加签发送（请确认机器人设置了自定义关键词）"
                fi
            fi
            ok=$(curl -sm 8 -H 'Content-Type: application/json; charset=utf-8' \
                 -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"${et} ${eb}\"}}" "$durl" 2>/dev/null) ;;
        feishu)
            [ -n "$FEISHU_KEY" ] || { log "飞书未配置，跳过通知"; return 1; }
            ok=$(curl -sm 8 -H 'Content-Type: application/json; charset=utf-8' \
                 -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"${et} ${eb}\"}}" \
                 "https://open.feishu.cn/open-apis/bot/v2/hook/${FEISHU_KEY}" 2>/dev/null) ;;
        custom)
            [ -n "$NOTIFY_CMD" ] || { log "自定义通知命令未配置，跳过"; return 1; }
            bash -c "$NOTIFY_CMD" traffic-guard "$title: $body"
            return 0 ;;
        *)
            return 0 ;;
    esac
    case "$NOTIFY_TYPE" in
        telegram|serverchan|bark|wecom|dingtalk|feishu)
            if printf '%s' "$ok" | grep -qi '"ok"[ ]*:[ ]*true\|"errcode"[ ]*:[ ]*0\|"code"[ ]*:[ ]*"?0\|"code"[ ]*:[ ]*"?200\|"StatusCode"[ ]*:[ ]*0'; then
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
    # 兼容 Windows 编辑器产生的 CRLF 行尾: 值尾部的 \r 会污染变量（如网卡名变 "eth0\r"）
    # shellcheck disable=SC1090
    . <(sed 's/\r$//' "$CONFIG_FILE")

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
    # 数值兜底: 非法值不致命，恢复默认后继续（防止垃圾值写入 systemd unit）
    case "$CHECK_INTERVAL" in ''|*[!0-9]*) CHECK_INTERVAL=60 ;; esac
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
        [ "$backend" = "vnstat" ] && echo "请确认 vnstat/jq 已安装、vnstat 服务正在运行，且网卡已加入 vnstat 数据库（sudo vnstat --add -i $INTERFACE）。"
        echo "应急方案: 编辑 $CONFIG_FILE，将 BACKEND=\"vnstat\" 改为 BACKEND=\"proc\" 后即可恢复统计。"
        exit 1
    }
    local limit_bytes shut_bytes pct remain_limit remain_shut
    limit_bytes=$(gb_to_bytes "$LIMIT_GB")
    shut_bytes=$(gb_to_bytes $((LIMIT_GB - BUFFER_GB)))
    pct=$(awk -v u="$USED" -v l="$limit_bytes" 'BEGIN { printf "%.1f", u * 100 / l }')
    remain_limit=$(awk -v l="$limit_bytes" -v u="$USED" 'BEGIN { printf "%.2f", (l > u ? l - u : 0) / 1e9 }')
    remain_shut=$(awk -v s="$shut_bytes" -v u="$USED" 'BEGIN { printf "%.2f", (s > u ? s - u : 0) / 1e9 }')
    local note_line=""
    [ -n "$VNSTAT_NOTE" ] && note_line="⚠ 注意     : $(vnstat_note_text)"
    local pace_line=""
    if [ "$USED" -gt 0 ]; then
        local days_elapsed pace_rate proj_shut
        days_elapsed=$(( ( $(date +%s) - $(date -d "$start" +%s) ) / 86400 + 1 ))
        [ "$days_elapsed" -lt 1 ] && days_elapsed=1
        pace_rate=$(awk -v u="$USED" -v d="$days_elapsed" 'BEGIN { printf "%.2f", u / d / 1e9 }')
        if [ "$USED" -ge "$shut_bytes" ]; then
            pace_line="用量速度    : 日均 ${pace_rate} GB；已达到关机阈值（估算）"
        else
            proj_shut=$(awk -v s="$shut_bytes" -v u="$USED" -v d="$days_elapsed" \
                'BEGIN { v = (s - u) / (u / d); printf "%d", (v == int(v)) ? v : int(v) + 1 }')
            if [ "$proj_shut" -gt 365 ]; then
                pace_line="用量速度    : 日均 ${pace_rate} GB；按此速度一年内不会到达关机阈值（估算）"
            else
                pace_line="用量速度    : 日均 ${pace_rate} GB；按此速度预计 $(date -d "+${proj_shut} days" +%m-%d) 到达关机阈值（估算）"
            fi
        fi
    fi
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
$pace_line
通知方式    : $NOTIFY_TYPE
$note_line
====================================================
提示: 请与服务商面板用量对账；若面板数值明显更高，调大 BUFFER_GB。
EOF
}

do_check() {
    local dryrun=0
    [ "${1:-}" = "--dry-run" ] && dryrun=1
    load_config || exit 1
    # 无条件确保目录存在: 预警/关机的时间戳记录依赖它，缺失会导致每轮重复通知
    mkdir -p "$STATE_DIR" 2>/dev/null

    if command -v flock >/dev/null 2>&1; then
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

    case "$VNSTAT_NOTE" in
        2|3)
            # 每自然日最多记录一次, 避免每 60 秒刷一条 syslog
            local wtoday wlast
            wtoday=$(date +%F)
            wlast=$(cat "$STATE_DIR/last-backend-warn" 2>/dev/null)
            if [ "$wlast" != "$wtoday" ]; then
                log "警告: $(vnstat_note_text)"
                printf '%s\n' "$wtoday" > "$STATE_DIR/last-backend-warn" 2>/dev/null || true
            fi ;;
    esac

    if [ "$USED" -ge "$shut_bytes" ]; then
        log "已用流量达到触发阈值 $(bytes_to_gb "$shut_bytes")GB，执行保护动作: 关机"
        if [ "$dryrun" -eq 1 ]; then
            log "[dry-run] 演练模式：跳过通知与关机。实际运行将立即关机！"
            return 0
        fi
        # 关机通知每 60 分钟最多一次: 防止关机命令不生效（如容器缺权限）时每轮检查刷屏
        local now_ts last_ts stamp_file="$STATE_DIR/last-shutdown-notify"
        now_ts=$(date +%s)
        last_ts=$(cat "$stamp_file" 2>/dev/null)
        case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac
        if [ $((now_ts - last_ts)) -ge 3600 ]; then
            send_notify "traffic-guard 警告" "本周期流量已达 $(bytes_to_gb "$USED")GB（上限 ${LIMIT_GB}GB），VPS 即将自动关机！"
            printf '%s\n' "$now_ts" > "$stamp_file" 2>/dev/null || true
            sleep 3
        fi
        log "正在执行关机命令..."
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            systemctl poweroff
        else
            command -v poweroff >/dev/null 2>&1 && poweroff || shutdown -h now
        fi
        # 能走到这里说明关机命令未生效（如 LXC 容器无 poweroff 权限），留下明确日志
        log "警告: 关机命令未生效，下轮检查将重试（通知每 60 分钟最多发送一次）"
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
    rm -f "/etc/cron.d/${SERVICE_NAME}" "/etc/cron.d/${SERVICE_NAME}.stopped" \
          "$INSTALL_PATH" "$LEGACY_PATH"
    echo "已卸载定时任务与脚本。"
    local yn
    read -rp "是否同时删除配置与历史数据（$CONFIG_FILE、$STATE_DIR）? [y/N]: " yn
    case "$yn" in
        y|Y)
            rm -rf "$STATE_DIR"
            rm -f "$CONFIG_FILE"
            echo "已删除配置与数据。"
            ;;
        *)
            echo "配置与历史数据已保留（$CONFIG_FILE、$STATE_DIR），重装可继续使用。"
            ;;
    esac
}

# ---------------------------------------------------------------- 升级

do_upgrade() {
    need_root
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || die "升级需要 curl 或 wget，请先安装"
    local url="${TG_RAW_URL:-https://raw.githubusercontent.com/YCJE/traffic-guard/main/traffic-guard.sh}"
    local tmp="$INSTALL_PATH.new" newver
    mkdir -p "$(dirname "$INSTALL_PATH")" 2>/dev/null
    echo "正在获取最新版本: $url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 60 "$url" -o "$tmp" || { rm -f "$tmp"; die "下载失败，请检查网络后重试"; }
    else
        wget -qO "$tmp" "$url" || { rm -f "$tmp"; die "下载失败，请检查网络后重试"; }
    fi
    bash -n "$tmp" || { rm -f "$tmp"; die "下载脚本语法校验失败，已放弃升级"; }
    newver=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
    chmod 755 "$tmp"
    mv -f "$tmp" "$INSTALL_PATH"   # 原子替换，不影响正在运行的实例
    rm -f "$LEGACY_PATH"
    echo "✔ 升级完成: ${VERSION} -> ${newver:-unknown}（下次运行生效）"
    # 重新生成定时任务，确保 ExecStart 指向当前路径
    if load_config; then
        install_scheduler >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------- 定时监控控制

monitor_state() {
    if [ -d /run/systemd/system ]; then
        # is-active 失败时自身已打印 inactive, 再 echo 会输出两遍, 因此捕获后统一输出
        local s
        s=$(systemctl is-active "${SERVICE_NAME}.timer" 2>/dev/null)
        echo "${s:-unknown}"
    else
        if [ -f "/etc/cron.d/${SERVICE_NAME}" ]; then echo active
        elif [ -f "/etc/cron.d/${SERVICE_NAME}.stopped" ]; then echo stopped
        else echo "not-installed"; fi
    fi
}

service_control_menu() {
    while :; do
        echo
        echo "定时监控当前状态: $(monitor_state)"
        echo "  1. 启动监控"
        echo "  2. 停止监控"
        echo "  3. 重启监控"
        echo "  4. 查看详细状态"
        echo "  0. 返回上级菜单"
        local c
        read -rp "请选择: " c || return 0   # stdin 关闭时退出, 防止空转死循环
        case "$c" in
            1)
                if [ -d /run/systemd/system ]; then
                    systemctl start "${SERVICE_NAME}.timer" 2>/dev/null
                else
                    mv -f "/etc/cron.d/${SERVICE_NAME}.stopped" "/etc/cron.d/${SERVICE_NAME}" 2>/dev/null
                fi
                echo "✔ 已启动（当前状态: $(monitor_state)）" ;;
            2)
                if [ -d /run/systemd/system ]; then
                    systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null
                else
                    mv -f "/etc/cron.d/${SERVICE_NAME}" "/etc/cron.d/${SERVICE_NAME}.stopped" 2>/dev/null
                fi
                echo "✔ 已停止（当前状态: $(monitor_state)）" ;;
            3)
                if [ -d /run/systemd/system ]; then
                    systemctl restart "${SERVICE_NAME}.timer" 2>/dev/null
                    echo "✔ 已重启（当前状态: $(monitor_state)）"
                else
                    echo "cron 模式无需重启"
                fi ;;
            4)
                if [ -d /run/systemd/system ]; then
                    systemctl status "${SERVICE_NAME}.timer" --no-pager -l
                else
                    echo "cron 文件: /etc/cron.d/${SERVICE_NAME}"
                    cat "/etc/cron.d/${SERVICE_NAME}" 2>/dev/null
                fi ;;
            0) return ;;
        esac
    done
}

# ---------------------------------------------------------------- 菜单辅助

pause_back() {
    read -rp "按回车返回菜单..." _
}

edit_config_menu() {
    local editor="${EDITOR:-}"
    if [ -z "$editor" ]; then
        if command -v nano >/dev/null 2>&1; then editor=nano; else editor=vi; fi
    fi
    "$editor" "$CONFIG_FILE"
    if ( load_config ) 2>/dev/null; then
        echo "✔ 配置有效"
    else
        echo "✘ 配置有误（错误信息见上），请重新编辑修正！"
    fi
}

view_logs_menu() {
    echo "最近 30 条 traffic-guard 日志:"
    if command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        journalctl -t "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null
    else
        grep -h "$SERVICE_NAME" /var/log/syslog /var/log/messages 2>/dev/null | tail -n 30
    fi
}

# ---------------------------------------------------------------- 交互菜单

show_menu() {
    need_root
    while :; do
        if [ ! -r "$CONFIG_FILE" ]; then
            echo "尚未安装 traffic-guard（未找到配置文件 $CONFIG_FILE）。"
            local yn
            read -rp "现在执行安装向导? [y/n]: " yn
            case "$yn" in
                n|N) return ;;
                *) do_install || return ;;
            esac
        fi
        echo
        echo "─────── traffic-guard 管理面板 v$VERSION ───────"
        echo "  1. 查看当前用量与状态"
        echo "  2. 演练检查（dry-run，不会关机）"
        echo "  3. 立即检查（真实执行，可能触发自动关机！）"
        echo "  4. 测试通知"
        echo "  5. 编辑配置"
        echo "  6. 查看最近日志"
        echo "  7. 定时监控 启动/停止/重启"
        echo "  8. 升级到最新版"
        echo "  9. 卸载 traffic-guard"
        echo "  0. 退出"
        echo "────────────────────────────────────────"
        local c
        read -rp "请选择: " c || return 0   # stdin 关闭(断线/管道)时退出, 防止空转死循环
        case "$c" in
            1) ( do_status ); pause_back ;;
            2) ( do_check --dry-run ); pause_back ;;
            3)
                local yn
                read -rp "将真实执行检查并可能触发自动关机，确认? [y/N]: " yn
                case "$yn" in y|Y) ( do_check ) ;; *) echo "已取消" ;; esac
                pause_back ;;
            4) ( do_test_notify ); pause_back ;;
            5) edit_config_menu; pause_back ;;
            6) view_logs_menu; pause_back ;;
            7) service_control_menu ;;
            8) do_upgrade; pause_back ;;
            9)
                local yn
                read -rp "确认卸载 traffic-guard? [y/N]: " yn
                case "$yn" in y|Y) do_uninstall; return ;; *) echo "已取消" ;; esac ;;
            0|q|Q) return ;;
        esac
    done
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
            if [ -d /run/systemd/system ]; then
                systemctl enable --now vnstat >/dev/null 2>&1 || true
                # 确认守护进程真的在跑，没跑就再拉一次
                systemctl is-active --quiet vnstat 2>/dev/null || \
                    systemctl restart vnstat >/dev/null 2>&1 || true
            fi
            return 0
        fi
        echo "检测到 vnstat 版本过旧（$major.x），将使用 proc 后端。"
    fi
    return 1
}

vnstat_add_iface() {
    command -v vnstat >/dev/null 2>&1 || return 1
    local ifc try total=0 added=0
    for ifc in "$@"; do
        total=$((total + 1))
        for try in 1 2 3; do
            # 失败常见于守护进程刚启动时数据库被占用，等待后重试
            if vnstat --add -i "$ifc" >/dev/null 2>&1; then added=$((added + 1)); break; fi
            sleep 2
        done
    done
    [ "$added" -eq 0 ] && return 1
    [ "$added" -ne "$total" ] && echo "  注意: 部分网卡未能加入 vnstat 数据库"
    return 0
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
        case "$iface" in
            ALL) break ;;
            *[!A-Za-z0-9._-]*)
                echo "  网卡名含非法字符，请重新输入" ;;
            *)
                if iface_exists "$iface"; then break; else echo "  网卡 $iface 不存在，请重新输入"; fi ;;
        esac
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
    echo "  4) 企业微信群机器人"
    echo "  5) 钉钉群机器人"
    echo "  6) 飞书群机器人"
    echo "  7) 自定义命令（消息文本作为 \$1 传入）"
    local notify_choice notify_type tg_token="" tg_chat="" tg_api="" sc_key="" bark_key="" bark_url="" wecom_key="" ding_token="" ding_secret="" feishu_key="" custom_cmd=""
    notify_choice=$(ask "请选择 [0-7]" "0")
    case "$notify_choice" in
        1)
            notify_type=telegram
            tg_token=$(ask "Telegram Bot Token" "")
            tg_chat=$(ask "Telegram Chat ID" "")
            echo "  （国内服务器收不到推送时，可填 Telegram API 反代地址）"
            tg_api=$(ask "TG API 地址（官方则回车）" "") ;;
        2)
            notify_type=serverchan
            sc_key=$(ask "Server酱 SendKey" "") ;;
        3)
            notify_type=bark
            bark_key=$(ask "Bark Device Key" "")
            bark_url=$(ask "Bark 服务器地址（官方则回车）" "https://api.day.app") ;;
        4)
            notify_type=wecom
            wecom_key=$(ask "企业微信 Webhook Key（机器人地址 key= 后的内容）" "") ;;
        5)
            notify_type=dingtalk
            ding_token=$(ask "钉钉机器人 Access Token" "")
            ding_secret=$(ask "钉钉加签密钥 SEC 开头（未开启加签则回车）" "") ;;
        6)
            notify_type=feishu
            feishu_key=$(ask "飞书 Webhook Key（hook/ 后的内容）" "") ;;
        7)
            notify_type=custom
            custom_cmd=$(ask "自定义命令（例如: curl -sm5 https://hook.example --data-urlencode \"msg=\$1\"）" "") ;;
        *) notify_type=none ;;
    esac

    # 10. 统计后端
    local backend_note="proc（无需额外依赖）"
    if ensure_vnstat; then
        if [ "$iface" = "ALL" ]; then
            vnstat_add_iface $(ls /sys/class/net 2>/dev/null | grep -v '^lo$')
        else
            vnstat_add_iface "$iface"
        fi
        if [ $? -eq 0 ]; then
            backend_note="vnstat（推荐，重启不丢计数）"
            BACKEND=auto
        else
            echo "警告: 网卡加入 vnstat 数据库失败，自动改用 proc 后端。"
            BACKEND=proc
        fi
    else
        echo "vnstat 不可用，将使用 proc 后端（通过状态文件跨重启累计）。"
        BACKEND=auto
    fi
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
# /etc/traffic-guard.conf — 由 traffic-guard install 生成
INTERFACE="$(dq_escape "$iface")"
LIMIT_GB=$limit
MODE="$mode"
BUFFER_GB=$buffer
WARN_GB=$warn
RESET_DAY=$reset_day
INITIAL_GB=$initial
CHECK_INTERVAL=$interval
NOTIFY_TYPE="$notify_type"
TG_BOT_TOKEN="$(dq_escape "$tg_token")"
TG_CHAT_ID="$(dq_escape "$tg_chat")"
TG_API_BASE="$(dq_escape "$tg_api")"
SERVERCHAN_KEY="$(dq_escape "$sc_key")"
BARK_KEY="$(dq_escape "$bark_key")"
BARK_URL="$(dq_escape "$bark_url")"
WECOM_KEY="$(dq_escape "$wecom_key")"
DING_TOKEN="$(dq_escape "$ding_token")"
DING_SECRET="$(dq_escape "$ding_secret")"
FEISHU_KEY="$(dq_escape "$feishu_key")"
NOTIFY_CMD='$(sq_escape "$custom_cmd")'
BACKEND="$resolved_backend"
EOF
    )
    chmod 600 "$CONFIG_FILE"

    # 记录初始用量所属周期: 仅在当前周期内生效，跨周期失效；重装幂等不重复计
    if [ "$initial" -gt 0 ]; then
        local cstart
        RESET_DAY="$reset_day"
        cstart=$(cycle_start)
        mkdir -p "$STATE_DIR"
        printf 'initial_cycle=%s\n' "$cstart" > "$META_FILE.tmp" && mv "$META_FILE.tmp" "$META_FILE"
    fi

    # 安装脚本本体与定时任务
    local self
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$self" != "$INSTALL_PATH" ]; then
        cp -f "$self" "$INSTALL_PATH" && chmod 755 "$INSTALL_PATH"
    fi
    rm -f "$LEGACY_PATH"
    install_scheduler

    # 通知自检
    if [ "$notify_type" != "none" ]; then
        echo
        echo "发送测试通知..."
        NOTIFY_TYPE="$notify_type" TG_BOT_TOKEN="$tg_token" TG_CHAT_ID="$tg_chat" TG_API_BASE="$tg_api" \
        SERVERCHAN_KEY="$sc_key" BARK_KEY="$bark_key" BARK_URL="$bark_url" \
        WECOM_KEY="$wecom_key" DING_TOKEN="$ding_token" DING_SECRET="$ding_secret" FEISHU_KEY="$feishu_key" \
        NOTIFY_CMD="$custom_cmd" \
        send_notify "traffic-guard 测试" "安装成功，通知渠道工作正常 ✅" \
            && echo "测试通知已发送，请查收。" \
            || echo "测试通知发送失败，可稍后运行 traffic-guard test-notify 重试。"
    fi

    echo
    echo "✔ 安装完成！常用命令:"
    echo "    traffic-guard                   打开交互式管理菜单（推荐）"
    echo "    traffic-guard status            查看当前用量（可与服务商面板对账）"
    echo "    traffic-guard check --dry-run   演练检查（不会真的关机）"
    echo "    traffic-guard test-notify       重发测试通知"
    echo "    traffic-guard upgrade           在线升级"
    echo "    traffic-guard uninstall         卸载"
    echo
    echo "建议先跑一天 dry-run 并与服务商面板对账，确认口径后再放心使用。"
    if [ "$resolved_backend" = "vnstat" ]; then
        echo
        echo "提示: vnstat 首次写入数据需要几分钟（默认保存间隔最长约 5 分钟），"
        echo "      期间 status 用量显示为 0 属正常现象，无需处理。"
    fi
}

usage() {
    cat <<EOF
traffic-guard v$VERSION — VPS 流量守护（按计费口径监控流量，超限自动关机）

用法:
  $SCRIPT_NAME                      打开交互式管理菜单
  $SCRIPT_NAME install              交互式安装（配置 + 依赖 + 定时任务）
  $SCRIPT_NAME status               查看当前周期用量
  $SCRIPT_NAME check [--dry-run]    执行检查（定时任务调用；--dry-run 演练不关机）
  $SCRIPT_NAME test-notify          发送测试通知
  $SCRIPT_NAME upgrade              升级到 GitHub 最新版
  $SCRIPT_NAME uninstall            卸载定时任务与脚本
  $SCRIPT_NAME help                 显示本帮助
EOF
}

main() {
    case "${1:-}" in
        install)     shift; do_install "$@" ;;
        menu)        show_menu ;;
        status)      do_status ;;
        check)       shift; do_check "$@" ;;
        test-notify) do_test_notify ;;
        upgrade)     do_upgrade ;;
        uninstall)   do_uninstall ;;
        -h|--help|help) usage ;;
        "")          usage ;;
        *) usage; die "未知命令: $1" ;;
    esac
}

# 供单元测试 source（TRAFFIC_GUARD_NO_MAIN=1 时跳过执行）
if [ -z "${TRAFFIC_GUARD_NO_MAIN:-}" ]; then
    # 无参数且在终端中运行 -> 进入管理菜单（x-ui 风格）；否则按子命令分发
    if [ "$#" -eq 0 ] && [ -t 0 ]; then
        show_menu
    else
        main "$@"
    fi
fi
