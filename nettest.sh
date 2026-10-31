#!/usr/bin/env bash
#=============================================================================
# nettest.sh — 大陆三网测试：延迟矩阵 + 回程线路 + 到你省份的个性化延迟
#
# 模式：
#   ./nettest.sh              菜单
#   ./nettest.sh ping         延迟矩阵：京沪穗蓉 v4(12目标) + 京沪穗 v6(9目标)
#                             —— 行业通用基准（融合怪/backtrace 同款目标表），
#                                用途：多台 VPS 横向对比
#   ./nettest.sh home [省份]  ★到「你所在省份」三网的真实延迟：
#                             自动识别 SSH 来源 IP 的省份（跳板机场景请手动指定），
#                             如: home 江苏 / home 四川 / home 内蒙古（支持简称）
#                             节点库: spiritLHLS/icmp_targets（31 省全覆盖）
#   ./nettest.sh route        回程线路判定（backtrace：CN2 GIA/GT/CTGNET/
#                             163/9929/4837/CMIN2/CMI 自动标注）
#   ./nettest.sh trace        nexttrace 详细三网逐跳追踪（含 TCP 模式）
#   ./nettest.sh all          延迟矩阵 + 回程
#=============================================================================
set -uo pipefail

VERSION="1.1.0"
BIN_DIR="/usr/local/bin"
NODES_URL="https://raw.githubusercontent.com/spiritLHLS/icmp_targets/main/nodes.json"

if [ -t 1 ]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
  C_B=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_BOLD=''; C_D=''; C_0=''
fi
info(){ printf '%s %s\n' "${C_B}[*]${C_0}" "$*"; }
ok(){   printf '%s %s\n' "${C_G}[+]${C_0}" "$*"; }
warn(){ printf '%s %s\n' "${C_Y}[!]${C_0}" "$*"; }
die(){  printf '%s %s\n' "${C_R}[x]${C_0}" "$*" >&2; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

#── 基准目标 IP（oneclickvirt/backtrace v0.0.21 同款，2026-10 核对）──────────
V4_TARGETS=(
  "北京电信 219.141.140.10"   "上海电信 202.96.209.133"  "广州电信 58.60.188.222"   "成都电信 61.139.2.69"
  "北京联通 202.106.195.68"   "上海联通 210.22.97.1"     "广州联通 210.21.196.6"    "成都联通 119.6.6.6"
  "北京移动 221.179.155.161"  "上海移动 211.136.112.200" "广州移动 120.196.165.24"  "成都移动 211.137.96.205"
)
V6_TARGETS=(
  "北京电信 2400:89c0:1053:3::69"    "上海电信 240e:e1:aa00:4000::24"  "广州电信 240e:97c:2f:3000::44"
  "北京联通 2400:89c0:1013:3::54"    "上海联通 2408:80f1:21:5003::a"   "广州联通 2408:8756:f50:1001::c"
  "北京移动 2409:8c00:8421:1303::55" "上海移动 2409:8c1e:75b0:3003::26" "广州移动 2409:8c54:871:1001::12"
)

need_root(){ [ "$(id -u)" = 0 ] || die "此操作需要 root"; }
have_v6_route(){ ip -6 route show default 2>/dev/null | grep -q .; }
have_v4_route(){ ip -4 route show default 2>/dev/null | grep -q .; }

# fetch <url> <out> — GitHub 直连 → spiritlhl CDN 镜像×2（前缀+完整URL，均已实测）
fetch(){
  local url="$1" out="$2"
  curl -fsSL --max-time 60 "$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  curl -fsSL --max-time 60 "https://cdn.spiritlhl.net/$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  curl -fsSL --max-time 60 "https://cdn0.spiritlhl.top/$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  return 1
}

#── Part 1: 延迟矩阵（行业基准）──────────────────────────────────────────────
do_ping(){
  local count=10
  echo
  echo "${C_BOLD}── 大陆三网 ICMP 延迟矩阵（每目标 ${count} 次）──${C_0}"
  has ping || die "缺少 ping"
  printf '  %-14s %-20s %8s %8s %8s\n' "目标" "IP" "平均" "最好" "丢包"
  local name ip stats avg best loss
  if have_v4_route; then
    echo "  ${C_D}── IPv4 ──${C_0}"
    for entry in "${V4_TARGETS[@]}"; do
      name=${entry%% *}; ip=${entry##* }
      stats=$(ping -4 -c $count -q -W 2 "$ip" 2>/dev/null)
      avg=$(echo "$stats" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')
      best=$(echo "$stats" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $4}')
      loss=$(echo "$stats" | awk -F'[ ,]+' '/packet loss/{for(i=1;i<=NF;i++) if($i=="loss") print $(i-1)}' | tr -d '%')
      [ -z "$avg" ] && { printf '  %-14s %-20s %8s\n' "$name" "$ip" "${C_R}超时${C_0}"; continue; }
      # 颜色分档：<150 绿 | 150-250 黄 | >=250 红
      local color="$C_G"
      awk -v a="$avg" 'BEGIN{exit !(a>=150)}' && color="$C_Y"
      awk -v a="$avg" 'BEGIN{exit !(a>=250)}' && color="$C_R"
      printf '  %-14s %-20s %s%8s%s %8s %7s%%\n' "$name" "$ip" "$color" "$avg" "$C_0" "$best" "${loss:-100}"
    done
  else
    warn "无 IPv4 默认路由，跳过 v4 延迟"
  fi
  if have_v6_route; then
    echo "  ${C_D}── IPv6 ──${C_0}"
    for entry in "${V6_TARGETS[@]}"; do
      name=${entry%% *}; ip=${entry##* }
      stats=$(ping -6 -c $count -q -W 2 "$ip" 2>/dev/null)
      avg=$(echo "$stats" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')
      best=$(echo "$stats" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $4}')
      loss=$(echo "$stats" | awk -F'[ ,]+' '/packet loss/{for(i=1;i<=NF;i++) if($i=="loss") print $(i-1)}' | tr -d '%')
      [ -z "$avg" ] && { printf '  %-14s %-20s %8s\n' "$name" "$ip" "${C_R}超时${C_0}"; continue; }
      printf '  %-14s %-20s %8s %8s %7s%%\n' "$name" "$ip" "$avg" "$best" "${loss:-100}"
    done
  else
    warn "无 IPv6 默认路由，跳过 v6 延迟"
  fi
  echo
  echo "  ${C_D}参考: <50 优秀(港日韩) | 50-150 良好 | 150-250 正常(美西) | >300 偏远${C_0}"
  echo "  ${C_D}此表为全国基准（多机对比用）。测到你${C_BOLD}所在省份${C_0}${C_D}的延迟请用: ./nettest.sh home${C_0}"
}

#── Part 2: 到你省份的个性化延迟 ─────────────────────────────────────────────
# 识别 SSH 来源 IP 所在省份（ip-api.com 免费 API，中文返回；跳板机场景请手动指定）
detect_province(){
  local src_ip="${SSH_CONNECTION%% *}" prov=""
  [ -n "$src_ip" ] || { echo ""; return; }
  has curl || { echo ""; return; }
  prov=$(curl -s --max-time 6 "http://ip-api.com/json/${src_ip}?lang=zh-CN&fields=status,regionName" 2>/dev/null \
         | grep -oE '"regionName":"[^"]*"' | cut -d'"' -f4)
  echo "$prov"
}

PY_BIN=""
detect_py(){
  # 逐个验证能真跑（Windows 商店 python3 假壳会静默失败，须排除）
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys; sys.exit(0)" 2>/dev/null; then
      PY_BIN="$c"; return 0
    fi
  done
  return 1
}

# 从节点库提取目标: extract_targets <省份关键词> <json文件> → "运营商|v4/v6|IP" 行
# 解析器: jq 优先，python3/python 兜底（Debian/Ubuntu 标配），都没有则失败
extract_targets(){
  local prov="$1" jf="$2"
  if has jq; then
    jq -r --arg p "$prov" \
      '.[] | select(.province | contains($p)) | .isp as $i | .ip_version as $v | (.ips | split(","))[0] as $ip | select($ip != "") | "\($i)|\($v)|\($ip)"' "$jf"
  elif detect_py; then
    PYTHONIOENCODING=utf-8 "$PY_BIN" - "$prov" "$jf" <<'PYEOF'
import json, sys
prov, path = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
for t in data:
    if prov in t.get('province', ''):
        ip = (t.get('ips') or '').split(',')[0].strip()
        if ip:
            print(f"{t['isp']}|{t['ip_version']}|{ip}")
PYEOF
  else
    return 1
  fi
}

do_home(){
  local prov="${1:-}"
  echo
  echo "${C_BOLD}── 到你所在省份的三网延迟（个性化）──${C_0}"
  # 省份：参数优先 → SSH 来源自动识别
  if [ -z "$prov" ]; then
    local src_ip="${SSH_CONNECTION%% *}"
    [ -n "$src_ip" ] && info "SSH 来源 IP: $src_ip"
    prov=$(detect_province)
    if [ -n "$prov" ]; then
      ok "识别到省份: $prov"
    else
      warn "无法自动识别省份（跳板机/API 超时）。请手动指定:"
      echo "  示例: ./nettest.sh home 江苏    ./nettest.sh home 四川    ./nettest.sh home 内蒙古"
      return 1
    fi
  fi
  # 节点库下载（31 省 × 三网 × v4/v6）
  local jf; jf=$(mktemp)
  if ! fetch "$NODES_URL" "$jf"; then
    rm -f "$jf"; warn "节点库下载失败（GitHub 与镜像均不可达）"; return 1
  fi
  # 解析器兜底：无 jq 且无 python 时尝试装 jq（root 才行，失败则明说）
  if ! has jq && ! detect_py; then
    { [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null 2>&1 && apt-get install -y -qq jq >/dev/null 2>&1; } || true
  fi
  local targets; targets=$(extract_targets "$prov" "$jf"); rm -f "$jf"
  [ -n "$targets" ] || { warn "节点库中没有匹配「$prov」的省份（支持简称，如: home 江苏）"; return 1; }
  has ping || die "缺少 ping"

  local count=10
  echo "  目标省份: ${C_BOLD}$prov${C_0}（每目标 ${count} 次探测）"
  echo
  printf '  %-10s %-6s %-42s %8s %8s %7s\n' "运营商" "协议" "目标 IP" "平均ms" "最好ms" "丢包"
  local line isp ver ip stats avg best loss color
  while IFS='|' read -r isp ver ip; do
    [ -z "$ip" ] && continue
    if [ "$ver" = "v6" ]; then
      stats=$(ping -6 -c $count -q -W 2 "$ip" 2>/dev/null)
    else
      stats=$(ping -4 -c $count -q -W 2 "$ip" 2>/dev/null)
    fi
    avg=$(echo "$stats" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')
    best=$(echo "$stats" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $4}')
    loss=$(echo "$stats" | awk -F'[ ,]+' '/packet loss/{for(i=1;i<=NF;i++) if($i=="loss") print $(i-1)}' | tr -d '%')
    if [ -z "$avg" ]; then
      printf '  %-10s %-6s %-42s %s\n' "$isp" "$ver" "$ip" "${C_R}超时${C_0}"
      continue
    fi
    color="$C_G"
    awk -v a="$avg" 'BEGIN{exit !(a>=100)}' && color="$C_Y"
    awk -v a="$avg" 'BEGIN{exit !(a>=200)}' && color="$C_R"
    printf '  %-10s %-6s %-42s %s%8s%s %8s %6s%%\n' "$isp" "$ver" "$ip" "$color" "$avg" "$C_0" "$best" "${loss:-100}"
  done <<< "$targets"
  echo
  echo "  ${C_D}这是 VPS → 你省份三网的真实 RTT，比全国基准更接近你的日常体验${C_0}"
  echo "  ${C_D}参考: <50 优秀 | 50-100 良好 | 100-200 可用 | >200 偏高${C_0}"
}

#── Part 3: 回程路由线路判定 ─────────────────────────────────────────────────
install_backtrace(){
  [ -x "$BIN_DIR/backtrace" ] && return 0
  info "下载 backtrace（回程线路判定，融合怪同款）..."
  local arch=""
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64;;
    aarch64|arm64) arch=arm64;;
    *) return 1;;
  esac
  need_root
  local tmp; tmp=$(mktemp)
  fetch "https://github.com/oneclickvirt/backtrace/releases/latest/download/backtrace-linux-${arch}" "$tmp" \
    || { rm -f "$tmp"; return 1; }
  install -m 755 "$tmp" "$BIN_DIR/backtrace" && rm -f "$tmp"
}

do_route(){
  echo
  echo "${C_BOLD}── 三网回程路由线路判定 ──${C_0}"
  echo "  ${C_D}自动判定: CN2 GIA/GT · CTGNET · 163 · 9929/CUG · 4837 · CMIN2/CMI${C_0}"
  echo
  if install_backtrace; then
    "$BIN_DIR/backtrace"
  else
    warn "backtrace 下载失败，回退 nexttrace --fast-trace"
    do_trace
  fi
}

#── Part 4: nexttrace 详细追踪 ───────────────────────────────────────────────
install_nexttrace(){
  [ -x "$BIN_DIR/nexttrace" ] && return 0
  info "安装 NextTrace（nxtrace.org 官方安装器）..."
  need_root
  bash <(curl -sL https://nxtrace.org/nt) >/dev/null 2>&1 || return 1
  has nexttrace || has "$BIN_DIR/nexttrace"
}

do_trace(){
  echo
  echo "${C_BOLD}── NextTrace 三网详细回程 ──${C_0}"
  install_nexttrace || die "NextTrace 安装失败（网络?）"
  local NT=nexttrace
  has nexttrace || NT="$BIN_DIR/nexttrace"
  echo
  echo "  ${C_D}ICMP 快速模式（北上广三网+教育网）:${C_0}"
  "$NT" --fast-trace 2>/dev/null || "$NT" -F 2>/dev/null
  echo
  echo "  ${C_D}TCP 80 端口模式（更能反映真实代理流量路径）:${C_0}"
  "$NT" --fast-trace --tcp 2>/dev/null || true
}

#── 菜单 ─────────────────────────────────────────────────────────────────────
menu(){
  while :; do
  echo
  echo "${C_BOLD}── 三网测试 ──${C_0}"
  echo "  1) 延迟矩阵    京沪穗蓉基准（多机横向对比用）"
  echo "  2) 到我省份    自动识别 SSH 来源省份的三网延迟 ${C_BOLD}★推荐${C_0}"
  echo "  3) 回程线路    backtrace 判定 CN2 GIA/9929/CMIN2 等"
  echo "  4) 详细追踪    nexttrace 逐跳（含 TCP 模式）"
  echo "  5) 全部        1 + 3"
  echo "  0) 返回/退出"
  echo
  printf '选择: '
  read -r sel || exit 0
  case "$sel" in
    1) do_ping ;;
    2) do_home "${2:-}" ;;
    3) do_route ;;
    4) do_trace ;;
    5) do_ping; do_route ;;
    *) exit 0 ;;
  esac
  done
}

#── 入口 ─────────────────────────────────────────────────────────────────────
MODE="${1:-menu}"
case "$MODE" in
  ping)  do_ping ;;
  route) do_route ;;
  trace) do_trace ;;
  home)  do_home "${2:-}" ;;
  all)   do_ping; do_route ;;
  menu)  menu ;;
  -h|--help) sed -n '2,17p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
  *) die "未知参数: $MODE（ping|home|route|trace|all）" ;;
esac
