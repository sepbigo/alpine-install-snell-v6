#!/bin/sh
#===============================================================================
# Snell v6 Alpine 一键自动安装脚本
# 改编自：https://telegra.ph/Alpine安装Snell-v6-10-02
#
# 功能：
#   1. 自动安装依赖、下载最新版 Snell v6、生成配置、注册 OpenRC 开机自启
#   2. 自定义端口和密码（PSK），不填则使用默认值/随机生成
#   3. 安装完成后输出配置信息（可直接填入 Surge / Shadowrocket）
#   4. 安装每日自动更新任务，保持程序始终为最新版
#
# 用法：
#   sh install-snell.sh [选项]
#
# 选项：
#   --port PORT      监听端口 (默认 6160，也可用环境变量 SNELL_PORT)
#   --psk PSK        预共享密钥，12~255 字节 (不填则随机生成 32 位，也可用 SNELL_PSK)
#   --version VER    指定版本，如 v6.0.0rc2 (默认 latest=自动获取最新版，也可用 SNELL_VERSION)
#   --mode MODE      加密模式 default|unshaped|unsafe-raw (默认 default，也可用 SNELL_MODE)
#   --uninstall      卸载 Snell
#   -h, --help       显示帮助
#
# 示例：
#   sh install-snell.sh
#   sh install-snell.sh --port 23456 --psk "我的密码12345678"
#   SNELL_PORT=23456 SNELL_PSK="我的密码12345678" sh install-snell.sh
#===============================================================================
set -eu

DEF_PORT=6160
KB_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
DL_BASE="https://dl.nssurge.com/snell"
CONF_DIR="/etc/snell"
CONF_FILE="$CONF_DIR/snell-server.conf"
VERSION_FILE="$CONF_DIR/.version"
BIN="/usr/local/bin/snell-server"
UPDATE_BIN="/usr/local/bin/snell-update"
SERVICE_FILE="/etc/init.d/snell-server"
UPDATE_LOG="/var/log/snell-update.log"

PORT="${SNELL_PORT:-$DEF_PORT}"
PSK="${SNELL_PSK:-}"
VERSION="${SNELL_VERSION:-latest}"
MODE="${SNELL_MODE:-default}"
ACTION="install"

log() { printf '[snell] %s\n' "$*" >&2; }
die() { printf '[snell] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^#===/p' "$0" | sed 's/^# \{0,1\}//'
}

#---------------- 参数解析 ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --port)        PORT="$2"; shift 2;;
    --port=*)      PORT="${1#--port=}"; shift;;
    --psk)         PSK="$2"; shift 2;;
    --psk=*)       PSK="${1#--psk=}"; shift;;
    --version)     VERSION="$2"; shift 2;;
    --version=*)   VERSION="${1#--version=}"; shift;;
    --mode)        MODE="$2"; shift 2;;
    --mode=*)      MODE="${1#--mode=}"; shift;;
    --uninstall)   ACTION="uninstall"; shift;;
    -h|--help)     usage; exit 0;;
    *) die "未知参数: $1（用 --help 查看用法）";;
  esac
done

#---------------- 卸载 ----------------
do_uninstall() {
  log "正在卸载 Snell…"
  rc-service snell-server stop 2>/dev/null || true
  rc-update del snell-server default 2>/dev/null || true
  rm -f "$SERVICE_FILE" "$BIN" "$BIN.bak" "$UPDATE_BIN"
  rm -rf "$CONF_DIR"
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "snell-update" || true) | crontab - 2>/dev/null || true
  fi
  log "卸载完成"
}

#---------------- 基础检查 ----------------
check_env() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行"
  [ -f /etc/alpine-release ] || die "本脚本仅支持 Alpine Linux"
  case "$MODE" in
    default|unshaped|unsafe-raw) ;;
    *) die "--mode 只能是 default|unshaped|unsafe-raw";;
  esac
  case "$PORT" in
    ''|*[!0-9]*) die "端口必须是数字";;
  esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口范围 1-65535"
  if [ -n "$PSK" ]; then
    [ "${#PSK}" -ge 12 ] && [ "${#PSK}" -le 255 ] || die "PSK 长度必须 12~255 字节"
  fi
}

#---------------- 1. 安装依赖（原文步骤 1，nano 为手动编辑用，自动化不需要） ----------------
install_deps() {
  log "安装依赖…"
  apk update
  apk add gcompat curl wget unzip openrc cronie
}

#---------------- 2. 识别架构（原文步骤 2） ----------------
detect_arch() {
  case "$(uname -m)" in
    x86_64)        printf 'amd64';;
    aarch64|arm64) printf 'aarch64';;
    i386|i686)     printf 'i386';;
    *) die "不支持的架构: $(uname -m)（Snell v6 仅提供 amd64/aarch64/i386）";;
  esac
}

#---------------- 3. 解析版本号 ----------------
resolve_version() {
  # $1=版本要求(latest 或具体版本)，$2=架构；输出如 v6.0.0rc2
  if [ "$1" = "latest" ]; then
    log "正在获取最新版本号…"
    ver="$(curl -fsSL --max-time 30 "$KB_URL" \
      | grep -oE "snell-server-(v6[^\"]*)-linux-$2\\.zip" \
      | sed -E 's/^snell-server-//; s/-linux-.*//' \
      | sort -V | tail -n 1)" || ver=""
    [ -n "$ver" ] || die "无法从官方更新日志获取最新版本号，请检查网络或用 --version 指定"
    printf '%s' "$ver"
  else
    printf '%s' "$1"
  fi
}

#---------------- 4. 下载并安装二进制 ----------------
download_install() {
  # $1=版本号，$2=架构
  url="$DL_BASE/snell-server-$1-linux-$2.zip"
  tmpd="$(mktemp -d)"
  log "下载 $url"
  curl -fsSL --max-time 120 --retry 2 -o "$tmpd/snell.zip" "$url" \
    || { rm -rf "$tmpd"; die "下载失败，请检查网络或版本号"; }
  unzip -o -q "$tmpd/snell.zip" -d "$tmpd" \
    || { rm -rf "$tmpd"; die "解压失败"; }
  [ -f "$tmpd/snell-server" ] || { rm -rf "$tmpd"; die "压缩包中没有 snell-server"; }
  if [ -f "$BIN" ]; then
    cp -f "$BIN" "$BIN.bak"
    log "旧版本已备份到 $BIN.bak"
  fi
  cp -f "$tmpd/snell-server" "$BIN"
  chmod 755 "$BIN"
  rm -rf "$tmpd"
  "$BIN" -v >/dev/null 2>&1 || die "新二进制无法运行"
  mkdir -p "$CONF_DIR"
  printf '%s' "$1" > "$VERSION_FILE"
  log "已安装 snell-server $1"
}

#---------------- 5. 生成配置文件（原文步骤 3，wizard 改为自动生成） ----------------
gen_psk() {
  # 32 位字母数字，满足 v6 的 12~255 字节要求
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

write_config() {
  mkdir -p "$CONF_DIR"
  # 重装且未指定 --psk 时，保留原来的 PSK（避免客户端配置失效）
  if [ -z "$PSK" ] && [ -f "$CONF_FILE" ]; then
    PSK="$(sed -n 's/^psk *= *//p' "$CONF_FILE" | head -n 1)"
  fi
  if [ -z "$PSK" ]; then
    PSK="$(gen_psk)"
    log "已随机生成 PSK"
  fi
  {
    echo "[snell-server]"
    echo "listen = 0.0.0.0:$PORT"
    echo "psk = $PSK"
    echo "ipv6 = true"
    if [ "$MODE" != "default" ]; then
      echo "mode = $MODE"
    fi
  } > "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  log "配置文件已写入 $CONF_FILE"
}

#---------------- 6. OpenRC 服务（原文步骤 4） ----------------
write_service() {
  cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run

name="snell-server"
command="/usr/local/bin/snell-server"
command_args="-c /etc/snell/snell-server.conf"
command_background="yes"
pidfile="/run/${name}.pid"

depend() {
        need net
}
EOF
  chmod +x "$SERVICE_FILE"
  rc-update add snell-server default
  log "OpenRC 服务已注册（开机自启）"
}

#---------------- 7. 自动更新任务 ----------------
install_updater() {
  cat > "$UPDATE_BIN" <<'EOF'
#!/bin/sh
# snell-update — Snell v6 每日自动更新（由 install-snell.sh 安装）
# 从官方更新日志获取最新 v6 版本，有新版则下载替换并重启服务。
set -eu

KB_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
DL_BASE="https://dl.nssurge.com/snell"
BIN="/usr/local/bin/snell-server"
CONF_DIR="/etc/snell"
VERSION_FILE="$CONF_DIR/.version"
LOG="/var/log/snell-update.log"
LOCK="/run/snell-update.lock"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

[ -x "$BIN" ] || exit 0

case "$(uname -m)" in
  x86_64) arch=amd64;;
  aarch64|arm64) arch=aarch64;;
  i386|i686) arch=i386;;
  *) exit 0;;
esac

latest="$(curl -fsSL --max-time 30 "$KB_URL" 2>/dev/null \
  | grep -oE "snell-server-(v6[^\"]*)-linux-${arch}\\.zip" \
  | sed -E 's/^snell-server-//; s/-linux-.*//' | sort -V | tail -n 1)" || latest=""
[ -n "$latest" ] || { log "获取最新版本失败"; exit 0; }

installed="$(cat "$VERSION_FILE" 2>/dev/null || echo none)"
[ "$installed" = "$latest" ] && exit 0

log "发现新版本: $installed -> $latest，开始更新"
tmpd="$(mktemp -d)"
if curl -fsSL --max-time 120 --retry 2 -o "$tmpd/snell.zip" \
     "$DL_BASE/snell-server-${latest}-linux-${arch}.zip" 2>/dev/null \
   && unzip -o -q "$tmpd/snell.zip" -d "$tmpd" 2>/dev/null \
   && [ -f "$tmpd/snell-server" ]; then
  cp -f "$BIN" "$BIN.bak"
  cp -f "$tmpd/snell-server" "$BIN" && chmod 755 "$BIN"
  if "$BIN" -v >/dev/null 2>&1; then
    printf '%s' "$latest" > "$VERSION_FILE"
    rc-service snell-server restart >/dev/null 2>&1 || true
    log "更新成功，已重启服务"
  else
    cp -f "$BIN.bak" "$BIN"
    log "新二进制校验失败，已回滚"
  fi
else
  log "下载/解压失败，本次跳过"
fi
rm -rf "$tmpd"
EOF
  chmod +x "$UPDATE_BIN"

  # cron 每日 03:00 执行（去重）
  (crontab -l 2>/dev/null | grep -v "snell-update" || true
   echo "0 3 * * * $UPDATE_BIN >/dev/null 2>&1") | crontab -
  # 确保 cron 守护进程在运行并开机自启
  rc-update add cronie default 2>/dev/null || true
  if ! rc-service cronie status 2>/dev/null | grep -q started; then
    rc-service cronie start 2>/dev/null || true
  fi
  if ! pgrep -f "cron" >/dev/null 2>&1; then
    log "警告：cron 守护进程似乎未运行，自动更新可能不生效，请手动执行 rc-service cronie start"
  else
    log "自动更新任务已安装（每天 03:00）"
  fi
}

#---------------- 8. 启动服务 ----------------
start_service() {
  if rc-service snell-server status 2>/dev/null | grep -q started; then
    rc-service snell-server restart
  else
    rc-service snell-server start
  fi
  sleep 2
  rc-service snell-server status 2>/dev/null | grep -q started \
    || die "服务启动失败，请查看日志：cat /var/log/messages | grep snell"
}

#---------------- 9. 输出配置信息 ----------------
detect_ip() {
  curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null \
    || curl -s --max-time 8 https://ifconfig.me 2>/dev/null \
    || curl -s --max-time 8 https://api.ipify.org 2>/dev/null \
    || printf '你的服务器IP'
}

print_info() {
  bin_ver="$("$BIN" -v 2>&1 | grep -oE 'v[0-9][^ )]*' | head -n 1)"
  ip="$(detect_ip)"
  printf '\n'
  printf '============================================================\n'
  printf ' Snell v6 安装完成\n'
  printf '============================================================\n'
  printf ' 安装版本   : %s (%s)\n' "$(cat "$VERSION_FILE" 2>/dev/null)" "$bin_ver"
  printf ' 监听地址   : 0.0.0.0:%s\n' "$PORT"
  printf ' PSK 密码   : %s\n' "$PSK"
  printf ' 配置文件   : %s\n' "$CONF_FILE"
  printf ' 加密模式   : %s\n' "$MODE"
  printf '\n'
  printf ' 服务管理：\n'
  printf '   rc-service snell-server start|stop|restart|status\n'
  printf '   日志查看：cat /var/log/messages | grep snell\n'
  printf '\n'
  printf ' 自动更新：每天 03:00 检查官方最新版并自动升级\n'
  printf '   手动检查：%s\n' "$UPDATE_BIN"
  printf '   更新日志：%s\n' "$UPDATE_LOG"
  printf '\n'
  printf ' 客户端配置（把 <服务器IP> 换成你的服务器公网 IP）：\n'
  printf '\n'
  printf '   Surge：\n'
  printf '     Snell-V6 = snell, %s, %s, psk=%s, version=6\n' "$ip" "$PORT" "$PSK"
  printf '\n'
  printf '   Shadowrocket：类型选 Snell，地址=%s 端口=%s 密码=%s，版本选 6\n' "$ip" "$PORT" "$PSK"
  printf '\n'
  printf '============================================================\n'
}

#---------------- 主流程 ----------------
main() {
  if [ "$ACTION" = "uninstall" ]; then
    check_env
    do_uninstall
    exit 0
  fi
  check_env
  install_deps
  ARCH="$(detect_arch)"
  VER="$(resolve_version "$VERSION" "$ARCH")"
  download_install "$VER" "$ARCH"
  write_config
  write_service
  install_updater
  start_service
  print_info
}

main "$@"
