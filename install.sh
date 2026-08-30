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

# 非 root 时通过 sudo 重新拉取执行（进程替换下的 /dev/fd 无法跨 sudo 继承）
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "请直接使用 root 用户运行本脚本"
    log "当前非 root，尝试使用 sudo 重新执行..."
    if command -v curl >/dev/null 2>&1; then
        exec sudo bash <(curl -fsSL "$SELF_URL")
    else
        exec sudo bash <(wget -qO- "$SELF_URL")
    fi
fi

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || die "请先安装 curl 或 wget（例如: apt install -y curl）"

dl() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 60 "$1" -o "$2"
    else
        wget -qO "$2" "$1"
    fi
}

TMP="$(mktemp /tmp/traffic-guard.XXXXXX)"
log "正在下载主脚本..."
dl "$SCRIPT_URL" "$TMP" || { rm -f "$TMP"; die "下载失败，请检查网络后重试"; }
bash -n "$TMP" || { rm -f "$TMP"; die "下载脚本语法校验失败，已中止安装"; }

install -m 755 "$TMP" "$INSTALL_PATH"
rm -f "$TMP" "$LEGACY_PATH"
log "已安装到 $INSTALL_PATH"
log "启动安装向导..."
exec "$INSTALL_PATH" install
