#!/usr/bin/env bash
#
# traffic-guard 一键安装脚本
#
# 用法（在 VPS 上以 root 或 sudo 执行）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YCJE/traffic-guard/main/install.sh)
#
# 没有 curl 时:
#   bash <(wget -qO- https://raw.githubusercontent.com/YCJE/traffic-guard/main/install.sh)
#
# 可用环境变量:
#   TG_RAW_URL    主脚本下载地址（默认 GitHub raw，自建镜像时替换）
#   TG_SELF_URL   本引导脚本自身的下载地址（非 root 时用 sudo 重新拉取）

set -u

SELF_URL="${TG_SELF_URL:-https://raw.githubusercontent.com/YCJE/traffic-guard/main/install.sh}"
SCRIPT_URL="${TG_RAW_URL:-https://raw.githubusercontent.com/YCJE/traffic-guard/main/traffic-guard.sh}"
INSTALL_PATH="/usr/local/bin/traffic-guard"
LEGACY_PATH="/usr/local/bin/traffic-guard.sh"

log() { echo "[traffic-guard] $*"; }
die() { echo "[traffic-guard] 错误: $*" >&2; exit 1; }

# 中断(Ctrl-C/断网)时清理临时文件; 预初始化以兼容 set -u
BOOTSTRAP=""
TMP=""
trap 'rm -f "$BOOTSTRAP" "$TMP" 2>/dev/null' EXIT

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || die "请先安装 curl 或 wget（例如: apt install -y curl）"

dl() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 60 "$1" -o "$2"
    else
        wget -qT 60 -O "$2" "$1"
    fi
}

# 非 root 时下载到临时文件后用 sudo 执行，原因:
# 1) 进程替换的 /dev/fd 在部分 sudo 配置下不会传递给 root 进程，直接报文件不存在
# 2) 管道给 bash 会占用 stdin，导致安装向导的交互读取失效
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "请直接使用 root 用户运行本脚本"
    log "当前非 root，下载安装脚本后通过 sudo 执行..."
    BOOTSTRAP="$(mktemp /tmp/traffic-guard-install.XXXXXX)"
    dl "$SELF_URL" "$BOOTSTRAP" || { rm -f "$BOOTSTRAP"; die "下载失败，请检查网络后重试"; }
    bash -n "$BOOTSTRAP" || { rm -f "$BOOTSTRAP"; die "下载脚本校验失败，已中止"; }
    sudo bash "$BOOTSTRAP"
    rc=$?
    rm -f "$BOOTSTRAP"
    exit "$rc"   # 把安装向导的退出码传给调用方, 失败可在脚本中感知
fi

TMP="$(mktemp /tmp/traffic-guard.XXXXXX)"
log "正在下载主脚本..."
dl "$SCRIPT_URL" "$TMP" || { rm -f "$TMP"; die "下载失败，请检查网络后重试"; }
bash -n "$TMP" || { rm -f "$TMP"; die "下载脚本语法校验失败，已中止安装"; }

mkdir -p "$(dirname "$INSTALL_PATH")"
install -m 755 "$TMP" "$INSTALL_PATH"
rm -f "$TMP" "$LEGACY_PATH"
log "已安装到 $INSTALL_PATH"
log "启动安装向导..."
exec "$INSTALL_PATH" install
