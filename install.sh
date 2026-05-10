#!/usr/bin/env bash
# Hysteria 2 一键安装与优化脚本，适用于 Ubuntu/Debian 及常见 systemd Linux。

set -Eeuo pipefail

SCRIPT_NAME="Hysteria 2 一键安装优化"
LOG_FILE="/var/log/hysteria2-install-$(date +%Y%m%d-%H%M%S).txt"
SYSCTL_CONF="/etc/sysctl.d/99-hysteria2-tuning.conf"
HY2_DIR="/etc/hysteria"
HY2_CONFIG="${HY2_DIR}/config.yaml"
HY2_CERT="${HY2_DIR}/server.crt"
HY2_KEY="${HY2_DIR}/server.key"
SNI_DOMAIN="www.bing.com"
MASQUERADE_URL="https://www.bing.com"
SERVICE_NAME="hysteria-server.service"
MODE="install"
HY2_LOG_LEVEL="error"
IO_TEST_MB=16
IO_SLOW_THRESHOLD_MB=30

if [[ -t 1 ]]; then
  RED='\033[31m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  BLUE='\033[34m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  BOLD=''
  RESET=''
fi

info() { printf "%b\n" "${BLUE}==>${RESET} $*"; }
ok() { printf "%b\n" "${GREEN}✔${RESET} $*"; }
warn() { printf "%b\n" "${YELLOW}警告:${RESET} $*"; }
fail() { printf "%b\n" "${RED}错误:${RESET} $*"; }

on_error() {
  local code=$?
  local line=${1:-unknown}
  local cmd=${2:-unknown}
  {
    echo
    echo "[ERROR] $(date '+%F %T')"
    echo "退出码: ${code}"
    echo "行号: ${line}"
    echo "命令: ${cmd}"
  } >>"${LOG_FILE}" 2>/dev/null || true
  fail "操作失败，详细日志：${LOG_FILE}"
  exit "${code}"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

prepare_log() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}"
  {
    echo "${SCRIPT_NAME}"
    echo "开始时间: $(date '+%F %T %Z')"
    echo "日志文件: ${LOG_FILE}"
    echo
  } >>"${LOG_FILE}"
}

run_cmd() {
  local desc=$1
  shift
  info "${desc}"
  {
    echo
    echo "[$(date '+%F %T')] ${desc}"
    printf '+'
    printf ' %q' "$@"
    echo
  } >>"${LOG_FILE}"
  "$@" >>"${LOG_FILE}" 2>&1
}

try_cmd() {
  local desc=$1
  shift
  info "${desc}"
  {
    echo
    echo "[$(date '+%F %T')] ${desc}"
    printf '+'
    printf ' %q' "$@"
    echo
  } >>"${LOG_FILE}"
  if "$@" >>"${LOG_FILE}" 2>&1; then
    return 0
  fi
  warn "${desc} 未完成，已继续。"
  return 1
}

usage() {
  cat <<EOF
${SCRIPT_NAME}

用法:
  sudo bash $0              安装并优化 Hysteria 2
  sudo bash $0 --uninstall  卸载 Hysteria 2 并清理本脚本写入的配置
  bash $0 --help            查看帮助
EOF
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    fail "请使用 root 运行，例如：sudo bash $0"
    exit 1
  fi
}

need_linux_systemd() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    fail "当前脚本仅支持 Linux。"
    exit 1
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    fail "未检测到 systemctl，当前系统不适合使用官方 Hysteria systemd 安装脚本。"
    exit 1
  fi
}

detect_os() {
  OS_ID="unknown"
  OS_LIKE=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID:-unknown}
    OS_LIKE=${ID_LIKE:-}
  fi
  ok "系统识别：${OS_ID} ${VERSION_ID:-}"
  echo "系统识别: ${OS_ID} ${VERSION_ID:-} / ${OS_LIKE}" >>"${LOG_FILE}"
}

parse_args() {
  if (( $# > 1 )); then
    fail "参数过多。"
    usage
    exit 1
  fi

  case "${1:-}" in
    "")
      MODE="install"
      ;;
    --uninstall)
      MODE="uninstall"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数：$1"
      usage
      exit 1
      ;;
  esac
}

install_deps() {
  info "检查并安装必要组件"
  if command -v apt-get >/dev/null 2>&1; then
    run_cmd "更新 apt 软件源" apt-get update
    run_cmd "安装依赖：curl/openssl/nftables" env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates openssl procps iproute2 nftables util-linux
  elif command -v dnf >/dev/null 2>&1; then
    run_cmd "安装依赖：curl/openssl/nftables" dnf install -y curl ca-certificates openssl procps-ng iproute nftables util-linux
  elif command -v yum >/dev/null 2>&1; then
    run_cmd "安装依赖：curl/openssl/nftables" yum install -y curl ca-certificates openssl procps-ng iproute nftables util-linux
  elif command -v zypper >/dev/null 2>&1; then
    run_cmd "安装依赖：curl/openssl/nftables" zypper --non-interactive install curl ca-certificates openssl procps iproute2 nftables util-linux
  else
    fail "未找到受支持的软件包管理器，请先手动安装 curl、openssl、procps、iproute2、nftables。"
    exit 1
  fi
}

hysteria_running() {
  systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null || pgrep -x hysteria >/dev/null 2>&1
}

cleanup_nft_rules() {
  local tables family table
  if ! command -v nft >/dev/null 2>&1; then
    warn "未检测到 nft 命令，跳过 nftables 残留清理。"
    return 0
  fi

  info "清理 nftables 中的 Hysteria 残留规则"
  tables=$(nft list tables 2>>"${LOG_FILE}" | awk '$1 == "table" && $3 ~ /hysteria/ {print $2 " " $3}' || true)
  if [[ -z ${tables} ]]; then
    ok "未发现 Hysteria nftables 残留表。"
    return 0
  fi

  while read -r family table; do
    [[ -z ${family:-} || -z ${table:-} ]] && continue
    try_cmd "删除 nftables 表 ${family} ${table}" nft delete table "${family}" "${table}" || true
  done <<<"${tables}"
}

official_uninstall() {
  local installer
  if ! command -v curl >/dev/null 2>&1; then
    warn "未检测到 curl，跳过官方卸载脚本。"
    return 1
  fi

  installer=$(mktemp)
  info "下载 Hysteria 2 官方卸载脚本"
  if curl -fsSL https://get.hy2.sh/ -o "${installer}" >>"${LOG_FILE}" 2>&1; then
    try_cmd "执行 Hysteria 2 官方卸载脚本" bash "${installer}" --remove || true
    rm -f "${installer}"
    return 0
  fi

  rm -f "${installer}"
  warn "官方卸载脚本下载失败，将使用本地兜底清理。"
  return 1
}

uninstall_hysteria() {
  printf "%b\n" "${YELLOW}${BOLD}开始卸载 Hysteria 2${RESET}"
  printf "%b\n" "详细日志将写入：${LOG_FILE}"

  try_cmd "停止 Hysteria 服务" systemctl stop "${SERVICE_NAME}" || true
  try_cmd "禁用 Hysteria 服务" systemctl disable "${SERVICE_NAME}" || true
  cleanup_nft_rules
  official_uninstall || true

  [[ -d "/etc/systemd/system/${SERVICE_NAME}.d" ]] && run_cmd "删除 systemd 覆盖配置" rm -rf "/etc/systemd/system/${SERVICE_NAME}.d"
  [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]] && run_cmd "删除 systemd 服务文件" rm -f "/etc/systemd/system/${SERVICE_NAME}"
  [[ -f "${SYSCTL_CONF}" ]] && run_cmd "删除内核优化配置" rm -f "${SYSCTL_CONF}"
  [[ -d "${HY2_DIR}" ]] && run_cmd "删除 Hysteria 配置目录" rm -rf "${HY2_DIR}"
  [[ -x "/usr/local/bin/hysteria" ]] && run_cmd "删除 Hysteria 可执行文件" rm -f "/usr/local/bin/hysteria"

  run_cmd "重载 systemd" systemctl daemon-reload
  try_cmd "重载剩余 sysctl 配置" sysctl --system || true
  ok "卸载完成。"
}

handle_existing_hysteria() {
  local choice
  if ! hysteria_running; then
    return 0
  fi

  warn "检测到本机已有 Hysteria 2 正在运行。"
  printf "%b" "${BOLD}请选择操作：[u] 卸载 / [q] 退出（默认 q）：${RESET}"
  read -r choice
  case "${choice:-q}" in
    u|U|uninstall|卸载)
      uninstall_hysteria
      exit 0
      ;;
    q|Q|quit|exit|退出)
      ok "已退出，未做更改。"
      exit 0
      ;;
    *)
      fail "未知选择，已退出。"
      exit 1
      ;;
  esac
}

random_hex() {
  openssl rand -hex 24
}

random_port_range() {
  local seed start end
  seed=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
  start=$((50000 + seed % 9001))
  end=$((start + 999))
  printf '%s-%s' "${start}" "${end}"
}

validate_port_range() {
  local range=$1
  local start end
  if [[ ! ${range} =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]]; then
    fail "端口跳跃必须使用范围格式，例如 50000-60000。"
    exit 1
  fi
  start=${range%-*}
  end=${range#*-}
  if (( start < 1 || end > 65535 || start >= end )); then
    fail "端口范围无效：${range}"
    exit 1
  fi
  PORT_START=${start}
  PORT_END=${end}
}

read_user_input() {
  local input default_range
  printf "%b" "${BOLD}请输入 Hysteria 认证密码（回车随机生成）：${RESET}"
  read -r input
  AUTH_PASSWORD=${input:-$(random_hex)}

  printf "%b" "${BOLD}请输入 Salamander 混淆密码（回车随机生成）：${RESET}"
  read -r input
  OBFS_PASSWORD=${input:-$(random_hex)}

  default_range=$(random_port_range)
  printf "%b" "${BOLD}请输入端口跳跃范围，例如 50000-60000（回车随机高位范围：${default_range}）：${RESET}"
  read -r input
  input=${input//[[:space:]]/}
  PORT_RANGE=${input:-${default_range}}
  validate_port_range "${PORT_RANGE}"

  {
    echo "认证密码: ${AUTH_PASSWORD}"
    echo "混淆密码: ${OBFS_PASSWORD}"
    echo "端口范围: ${PORT_RANGE}"
  } >>"${LOG_FILE}"
}

sysctl_exists() {
  local key=$1
  [[ -e "/proc/sys/${key//./\/}" ]]
}

append_sysctl_if_exists() {
  local key=$1
  local value=$2
  if sysctl_exists "${key}"; then
    printf '%s = %s\n' "${key}" "${value}" >>"${SYSCTL_CONF}.tmp"
  else
    warn "跳过不存在的内核参数：${key}"
    echo "跳过不存在的内核参数: ${key}" >>"${LOG_FILE}"
  fi
}

enable_bbr_and_tune_kernel() {
  local available current
  info "检测并优化 BBR 与内核参数"

  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    if command -v modprobe >/dev/null 2>&1; then
      run_cmd "尝试加载 tcp_bbr 模块" modprobe tcp_bbr || true
    fi
  fi

  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  : >"${SYSCTL_CONF}.tmp"
  printf '# Hysteria 2 UDP/QUIC tuning\n' >>"${SYSCTL_CONF}.tmp"
  printf '# Generated at %s\n\n' "$(date '+%F %T %Z')" >>"${SYSCTL_CONF}.tmp"

  append_sysctl_if_exists fs.file-max 1000000
  append_sysctl_if_exists net.core.rmem_max 67108864
  append_sysctl_if_exists net.core.wmem_max 67108864
  append_sysctl_if_exists net.core.rmem_default 16777216
  append_sysctl_if_exists net.core.wmem_default 16777216
  append_sysctl_if_exists net.core.netdev_max_backlog 250000
  append_sysctl_if_exists net.ipv4.ip_local_port_range "1024 65535"
  append_sysctl_if_exists net.ipv4.udp_rmem_min 8192
  append_sysctl_if_exists net.ipv4.udp_wmem_min 8192

  if [[ ${available} == *bbr* ]]; then
    append_sysctl_if_exists net.core.default_qdisc fq
    append_sysctl_if_exists net.ipv4.tcp_congestion_control bbr
  else
    warn "当前内核未提供 BBR，已继续 UDP/QUIC 参数优化。"
    echo "当前内核未提供 BBR: ${available}" >>"${LOG_FILE}"
  fi

  run_cmd "写入内核优化配置" mv "${SYSCTL_CONF}.tmp" "${SYSCTL_CONF}"
  run_cmd "应用内核优化配置" sysctl -p "${SYSCTL_CONF}"

  current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  if [[ ${available} == *bbr* && ${current} == "bbr" ]]; then
    ok "BBR 已开启。"
  elif [[ ${available} == *bbr* ]]; then
    warn "BBR 未能确认开启，请查看日志：${LOG_FILE}"
  fi
}

install_hysteria() {
  local installer
  installer=$(mktemp)
  # 等价于官方推荐命令：bash <(curl -fsSL https://get.hy2.sh/)
  # 拆成下载与执行两步，便于捕获 curl 失败并写入本地日志。
  run_cmd "下载 Hysteria 2 官方安装脚本" curl -fsSL https://get.hy2.sh/ -o "${installer}"
  run_cmd "执行 Hysteria 2 官方安装脚本" bash "${installer}"
  rm -f "${installer}"

  if ! id hysteria >/dev/null 2>&1; then
    fail "未检测到 hysteria 用户，官方安装脚本可能未正确完成。"
    exit 1
  fi
}

quic_windows_by_memory() {
  local mem_kb mem_mb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_mb=$((mem_kb / 1024))

  if (( mem_mb < 1024 )); then
    QUIC_STREAM=4194304
    QUIC_CONN=16777216
  elif (( mem_mb < 4096 )); then
    QUIC_STREAM=8388608
    QUIC_CONN=33554432
  elif (( mem_mb < 8192 )); then
    QUIC_STREAM=16777216
    QUIC_CONN=67108864
  else
    QUIC_STREAM=33554432
    QUIC_CONN=134217728
  fi

  ok "内存 ${mem_mb}MB，QUIC 窗口：stream=${QUIC_STREAM}, conn=${QUIC_CONN}"
  echo "QUIC 窗口: mem=${mem_mb}MB stream=${QUIC_STREAM} conn=${QUIC_CONN}" >>"${LOG_FILE}"
}

detect_disk_io() {
  local log_dir source base rota tmp start_ns end_ns elapsed_ns speed_mb
  log_dir=$(dirname "${LOG_FILE}")
  source=""
  base=""
  rota=""
  speed_mb=0
  HY2_LOG_LEVEL="error"

  info "检测磁盘类型与日志 IO"

  if command -v findmnt >/dev/null 2>&1; then
    source=$(findmnt -no SOURCE --target "${log_dir}" 2>>"${LOG_FILE}" | head -n1 || true)
  fi

  if [[ ${source} == /dev/* ]] && command -v lsblk >/dev/null 2>&1; then
    base=$(lsblk -no PKNAME "${source}" 2>>"${LOG_FILE}" | head -n1 || true)
    base=${base:-$(basename "${source}")}
    rota=$(lsblk -dn -o ROTA "/dev/${base}" 2>>"${LOG_FILE}" | awk 'NR == 1 {print $1}' || true)
  fi

  case "${rota}" in
    1)
      warn "检测到日志目录位于 HDD/机械盘，日志级别固定为 error。"
      ;;
    0)
      ok "检测到日志目录位于 SSD/NVMe，日志级别仍按低 IO 策略使用 error。"
      ;;
    *)
      warn "未能确认磁盘类型，将按低 IO 策略使用 error。"
      ;;
  esac

  tmp="${log_dir}/.hysteria2-iotest.$$"
  start_ns=$(date +%s%N)
  if dd if=/dev/zero of="${tmp}" bs=1M count="${IO_TEST_MB}" conv=fdatasync status=none >>"${LOG_FILE}" 2>&1; then
    end_ns=$(date +%s%N)
    elapsed_ns=$((end_ns - start_ns))
    if (( elapsed_ns > 0 )); then
      speed_mb=$((IO_TEST_MB * 1000000000 / elapsed_ns))
    fi
    if (( speed_mb > 0 && speed_mb < IO_SLOW_THRESHOLD_MB )); then
      warn "日志目录同步写入约 ${speed_mb}MB/s，低于 ${IO_SLOW_THRESHOLD_MB}MB/s，日志级别固定为 error。"
    elif (( speed_mb > 0 )); then
      ok "日志目录同步写入约 ${speed_mb}MB/s。"
    fi
  else
    warn "IO 测速失败，已按低 IO 策略使用 error。"
  fi
  rm -f "${tmp}" >>"${LOG_FILE}" 2>&1 || true

  echo "磁盘检测: source=${source:-unknown} base=${base:-unknown} rota=${rota:-unknown} speed=${speed_mb}MB/s logLevel=${HY2_LOG_LEVEL}" >>"${LOG_FILE}"
}

generate_certificate() {
  local openssl_conf
  openssl_conf=$(mktemp)
  run_cmd "创建 Hysteria 配置目录" mkdir -p "${HY2_DIR}"

  cat >"${openssl_conf}" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${SNI_DOMAIN}

[v3_req]
subjectAltName = DNS:${SNI_DOMAIN}
EOF

  run_cmd "生成自签名证书（CN=${SNI_DOMAIN}）" openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 -keyout "${HY2_KEY}" -out "${HY2_CERT}" -config "${openssl_conf}" -extensions v3_req
  rm -f "${openssl_conf}"
  run_cmd "保护私钥权限" chmod 600 "${HY2_KEY}"
}

yaml_single_quote() {
  local raw=$1
  local escaped=""
  local i char
  for ((i = 0; i < ${#raw}; i++)); do
    char=${raw:i:1}
    if [[ ${char} == "'" ]]; then
      escaped+="''"
    else
      escaped+="${char}"
    fi
  done
  printf "'%s'" "${escaped}"
}

write_hysteria_config() {
  local auth_yaml obfs_yaml
  auth_yaml=$(yaml_single_quote "${AUTH_PASSWORD}")
  obfs_yaml=$(yaml_single_quote "${OBFS_PASSWORD}")
  info "写入 Hysteria 2 服务端配置"
  cat >"${HY2_CONFIG}" <<EOF
listen: :${PORT_RANGE}

tls:
  cert: ${HY2_CERT}
  key: ${HY2_KEY}

auth:
  type: password
  password: ${auth_yaml}

obfs:
  type: salamander
  salamander:
    password: ${obfs_yaml}

quic:
  initStreamReceiveWindow: ${QUIC_STREAM}
  maxStreamReceiveWindow: ${QUIC_STREAM}
  initConnReceiveWindow: ${QUIC_CONN}
  maxConnReceiveWindow: ${QUIC_CONN}
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
EOF
  chmod 640 "${HY2_CONFIG}"
  run_cmd "修复 /etc/hysteria 权限" chown -R hysteria:hysteria "${HY2_DIR}"
}

configure_systemd() {
  local dropin_dir="/etc/systemd/system/${SERVICE_NAME}.d"
  run_cmd "创建 systemd 覆盖配置目录" mkdir -p "${dropin_dir}"
  cat >"${dropin_dir}/10-hysteria2-tuning.conf" <<EOF
[Service]
Environment="HYSTERIA_LOG_LEVEL=${HY2_LOG_LEVEL}"
Environment="HYSTERIA_DISABLE_UPDATE_CHECK=1"
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
EOF
  run_cmd "重载 systemd" systemctl daemon-reload
}

open_local_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    run_cmd "放行 UFW UDP 端口范围 ${PORT_RANGE}" ufw allow "${PORT_START}:${PORT_END}/udp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    run_cmd "放行 firewalld UDP 端口范围 ${PORT_RANGE}" firewall-cmd --permanent --add-port="${PORT_RANGE}/udp"
    run_cmd "重载 firewalld" firewall-cmd --reload
  fi
}

start_service() {
  run_cmd "启用并重启 Hysteria 服务" systemctl enable --now "${SERVICE_NAME}"
  run_cmd "重启 Hysteria 服务加载新配置" systemctl restart "${SERVICE_NAME}"
  run_cmd "检查 Hysteria 服务状态" systemctl is-active --quiet "${SERVICE_NAME}"
}

get_public_ip() {
  local ip
  ip=$(curl -4fsS --max-time 6 https://api.ipify.org 2>>"${LOG_FILE}" || true)
  if [[ -z ${ip} ]]; then
    ip=$(curl -6fsS --max-time 6 https://api64.ipify.org 2>>"${LOG_FILE}" || true)
  fi
  if [[ -z ${ip} ]]; then
    ip=$(hostname -I 2>>"${LOG_FILE}" | awk '{print $1}' || true)
  fi
  if [[ -z ${ip} ]]; then
    fail "无法自动获取服务器 IP，请查看日志：${LOG_FILE}"
    exit 1
  fi
  printf '%s' "${ip}"
}

uri_encode() {
  local LC_ALL=C
  local raw=$1
  local encoded=""
  local i char hex
  for ((i = 0; i < ${#raw}; i++)); do
    char=${raw:i:1}
    case "${char}" in
      [a-zA-Z0-9.~_-]) encoded+="${char}" ;;
      *) printf -v hex '%%%02X' "'${char}"; encoded+="${hex}" ;;
    esac
  done
  printf '%s' "${encoded}"
}

print_result() {
  local server_ip uri_host auth_enc obfs_enc name_enc link
  info "生成小火箭导入链接"
  server_ip=$(get_public_ip)
  if [[ ${server_ip} == *:* ]]; then
    uri_host="[${server_ip}]"
  else
    uri_host="${server_ip}"
  fi
  auth_enc=$(uri_encode "${AUTH_PASSWORD}")
  obfs_enc=$(uri_encode "${OBFS_PASSWORD}")
  name_enc=$(uri_encode "Hysteria2-${server_ip}")
  link="hysteria2://${auth_enc}@${uri_host}:${PORT_RANGE}/?insecure=1&sni=${SNI_DOMAIN}&obfs=salamander&obfs-password=${obfs_enc}#${name_enc}"

  {
    echo
    echo "公网 IP: ${server_ip}"
    echo "Shadowrocket URI: ${link}"
  } >>"${LOG_FILE}"

  printf "\n%b\n" "${GREEN}${BOLD}安装完成${RESET}"
  printf "%b\n" "配置文件：${HY2_CONFIG}"
  printf "%b\n" "详细日志：${LOG_FILE}"
  printf "%b\n" "监听端口：UDP ${PORT_RANGE}"
  printf "%b\n" "认证密码：${AUTH_PASSWORD}"
  printf "%b\n" "混淆类型：salamander"
  printf "%b\n" "混淆密码：${OBFS_PASSWORD}"
  printf "%b\n" "日志级别：${HY2_LOG_LEVEL}"
  printf "%b\n" "TLS SNI：${SNI_DOMAIN}（自签名，客户端需 insecure=1）"
  printf "\n%b\n" "${BOLD}Shadowrocket / Hysteria 2 导入链接：${RESET}"
  printf "%s\n" "${link}"
}

main() {
  parse_args "$@"
  need_root
  prepare_log
  printf "%b\n" "${GREEN}${BOLD}${SCRIPT_NAME}${RESET}"
  printf "%b\n" "详细日志将写入：${LOG_FILE}"
  need_linux_systemd
  if [[ ${MODE} == "uninstall" ]]; then
    uninstall_hysteria
    exit 0
  fi
  handle_existing_hysteria
  detect_os
  install_deps
  read_user_input
  enable_bbr_and_tune_kernel
  install_hysteria
  quic_windows_by_memory
  detect_disk_io
  generate_certificate
  write_hysteria_config
  configure_systemd
  open_local_firewall
  start_service
  print_result
}

main "$@"
