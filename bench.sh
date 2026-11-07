#!/usr/bin/env bash
#=============================================================================
# bench.sh — VPS 综合测评调度器（调用外部成熟脚本，带镜像回退与隐私模式）
#
# 模块（全部为 2026-10 验证活跃的上游项目）：
#   1. goecs       oneclickvirt/ecs Go 版融合怪（零依赖，综合性能+网络+解锁）
#   2. IPQuality   xykt/IPQuality（IP 风险/原生性/NAT/黑名单 400+ 库）
#   3. backtrace   oneclickvirt/backtrace（三网回程线路判定）
#   4. iperf3      单线程双栈收发测速（对 Leaseweb/Clouvider 公共服务器）
#
# 隐私设计：goecs -upload=false；IPQuality -p（不生成在线报告）——
#           不同于 NodeQuality（默认上传结果到 api.nodequality.com）
#
# 用法：
#   ./bench.sh              交互菜单
#   ./bench.sh full         融合怪完全体（约 7 分钟）
#   ./bench.sh net          仅网络方向（回程+延迟+测速，约 6 分钟）
#   ./bench.sh ip           仅 IP 质量（10-20 秒）
#   ./bench.sh media        仅流媒体解锁（30-60 秒）
#   ./bench.sh hw           仅硬件性能（CPU/内存/磁盘）
#   ./bench.sh single       单线程双栈测速（自研，约 3 分钟）
#   ./bench.sh all          体检全家桶：ip + net + single（推荐日常）
#
# 资源限额（应对 CPU/内存受限的 VPS，如 CPU 峰值≤30% 的套餐）：
#   ./bench.sh --low-power full      限 CPU 25% + 内存 512MB 跑完全体
#   MYVPS_CPU=30 MYVPS_MEM=400 ./bench.sh full    环境变量自定义限额
#   环境变量 MYVPS_NOLIMIT=1 可彻底禁用所有限额（含默认 nice）
#=============================================================================
set -uo pipefail

VERSION="1.1.0"
WORKDIR="${BENCH_DIR:-$HOME/vps-bench}"
mkdir -p "$WORKDIR"

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
is_root(){ [ "$(id -u)" = 0 ]; }

banner(){ echo; echo "${C_BOLD}═══ VPS 综合测评 v$VERSION ═══${C_0}"; }

#── 资源限额：应对"CPU 不能长时间超 30%"类套餐 ─────────────────────────────
# 原理：systemd-run 事务性 cgroup（跑完自动清理，不残留系统状态）；
#       无 systemd（老系统/容器）自动降级 nice+ionice（软限制）。
# 注意：cgroup 限 CPU% 是对"本工具箱进程树"限，不影响系统其他服务。
LOW_POWER="${MYVPS_LOW_POWER:-0}"
CPU_LIMIT="${MYVPS_CPU:-25}"      # 百分比；MYVPS_CPU=50 → 50%
MEM_LIMIT="${MYVPS_MEM:-512}"     # MB
NO_LIMIT="${MYVPS_NOLIMIT:-0}"
USE_SYSTEMD_RUN=0

setup_limit(){
  [ "$NO_LIMIT" = 1 ] && return 0
  # --low-power 旗标或环境变量显式给限额才启用；默认只做 nice 10（几乎无副作用）
  if [ "$LOW_POWER" != 1 ] && [ -z "${MYVPS_CPU:-}${MYVPS_MEM:-}" ]; then
    renice -n 10 -p $$ >/dev/null 2>&1 || true
    return 0
  fi
  if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    USE_SYSTEMD_RUN=1
    info "资源限额已启用（cgroup）: CPU≤${CPU_LIMIT}% 内存≤${MEM_LIMIT}MB"
  else
    renice -n 10 -p $$ >/dev/null 2>&1 || true
    has ionice && ionice -c2 -n7 -p $$ >/dev/null 2>&1
    warn "无 systemd，降级为软限制（nice 10 + 最低磁盘优先级）——CPU 峰值仍可能超，仅降低被杀概率"
  fi
}
# wrap_run <命令...> — USE_SYSTEMD_RUN=1 时把整条命令包进 cgroup
wrap_run(){
  [ "$USE_SYSTEMD_RUN" = 1 ] || { "$@"; return $?; }
  systemd-run --quiet --pipe --scope --collect \
    --property=CPUQuota=${CPU_LIMIT}% \
    --property=MemoryMax=$((MEM_LIMIT*1024*1024)) \
    -- "$@"
}

#── 解析 --low-power 旗标（可出现在任意位置，剥掉后不传给子命令）──────────
newargs=()
for a in "$@"; do
  case "$a" in
    --low-power) LOW_POWER=1 ;;
    *) newargs+=("$a") ;;
  esac
done
[ ${#newargs[@]} -gt 0 ] && set -- "${newargs[@]}" || set --

#── 网络助手：GitHub 直连失败自动换 spiritlhl CDN 镜像（格式：前缀+完整URL，已实测）──
gh_fetch(){ # gh_fetch <github-url> <输出文件>
  local url="$1" out="$2"
  curl -fsSL --max-time 60 "$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  curl -fsSL --max-time 60 "https://cdn.spiritlhl.net/$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  curl -fsSL --max-time 60 "https://cdn0.spiritlhl.top/$url" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
  return 1
}
gh_run(){ # gh_run <github-url> [参数...]  下载脚本到本地再执行（避免管道中断问题）
  local url="$1"; shift
  local tmp; tmp=$(mktemp)
  gh_fetch "$url" "$tmp" || { rm -f "$tmp"; return 1; }
  bash "$tmp" "$@"; local rc=$?
  rm -f "$tmp"; return $rc
}
gh_run_limited(){ # 同 gh_run，但包进资源限额 cgroup（--low-power 时实际生效）
  local url="$1"; shift
  local tmp; tmp=$(mktemp)
  gh_fetch "$url" "$tmp" || { rm -f "$tmp"; return 1; }
  wrap_run bash "$tmp" "$@"; local rc=$?
  rm -f "$tmp"; return $rc
}

#── 依赖 ─────────────────────────────────────────────────────────────────────
ensure_pkg(){
  local pkgs=("$@")
  local missing=()
  for p in "${pkgs[@]}"; do has "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  info "安装依赖: ${missing[*]}"
  if has apt; then
    is_root || { warn "非 root，尝试 sudo"; SUDO=sudo; }
    ${SUDO:-} apt-get update -qq 2>/dev/null; ${SUDO:-} apt-get install -y -qq "${missing[@]}" 2>/dev/null
  elif has dnf; then sudo dnf install -y "${missing[@]}" 2>/dev/null
  elif has apk; then sudo apk add "${missing[@]}" 2>/dev/null
  elif has yum; then sudo yum install -y "${missing[@]}" 2>/dev/null
  else warn "无包管理器，请手动安装: ${missing[*]}"; return 1; fi
  for p in "${pkgs[@]}"; do has "$p" || { warn "$p 安装失败"; return 1; }; done
}

#── 模块 1: goecs 融合怪 ─────────────────────────────────────────────────────
install_goecs(){
  has goecs && return 0
  info "安装 goecs（oneclickvirt/ecs Go 版，零依赖）..."
  local tmp; tmp=$(mktemp)
  gh_fetch "https://raw.githubusercontent.com/oneclickvirt/ecs/master/goecs.sh" "$tmp" \
    || { rm -f "$tmp"; warn "goecs 安装器下载失败"; return 1; }
  export noninteractive=true
  bash "$tmp" install >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  # 安装器可能装到 /usr/local/bin，不在 PATH 时补上
  has goecs || export PATH="/usr/local/bin:$PATH"
  has goecs
}

run_goecs(){ # run_goecs [额外开关...]
  install_goecs || die "goecs 不可用"
  local out="$WORKDIR/goecs-$(date +%Y%m%d-%H%M%S).log"
  info "运行 goecs（结果同时存 $out）..."
  # 公共默认：中文 / 不上传 / 出日志；wrap_run = CPU/内存限额（--low-power 时启用）
  wrap_run goecs -menu=false -l=zh -upload=false -log "$@" 2>&1 | tee "$out"
  ok "已保存: $out"
}

#── 模块 2: IPQuality ────────────────────────────────────────────────────────
run_ipq(){ # run_ipq [-4|-6]
  local out="$WORKDIR/ipq-$(date +%Y%m%d-%H%M%S).ansi"
  info "运行 IPQuality（隐私模式 -p，不上传）..."
  # 官方域名入口（与 NodeQuality 内部用法一致）；失败回退 raw 仓库路径（文件名 ip.sh）
  # IPQuality 是并行 curl 查询为主、CPU 占用低，限额只为保险统一走 wrap_run
  wrap_run bash -c 'bash <(curl -fsSL --max-time 60 https://IP.Check.Place) "$@"' _ -y -p -l cn "$@" -o "$out" 2>&1 \
    || gh_run "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" -y -p -l cn "$@" -o "$out"
  [ -f "$out" ] && ok "报告已保存: $out" || warn "报告未生成（脚本可能改了输出路径）"
}

#── 模块 3: 单线程双栈测速 ───────────────────────────────────────────────────
# 设计说明：Ookla 官方 CLI 无单线程参数（1.2.0 二进制+手册核实），
# sivel/speedtest-cli 已归档，HyperSpeed 已死。
# 单线程 = iperf3 -P 1 对公共服务器收/发各测，双栈各来一轮——
# 这正是 NodeQuality 内部 Net.Check.Place 的实现方式。
IPERF_PEERS=(
  "speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb"
  "speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb"
  "speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb"
  "speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb"
  "speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb"
  "nyc.speedtest.clouvider.net|纽约|Clouvider"
)

pick_peer(){ # pick_peer [4|6] → 输出 "host|city|prov"
  local fam="${1:-4}" line host city rtt best_rtt=99999 best=""
  for line in "${IPERF_PEERS[@]}"; do
    host=${line%%|*}
    rtt=$(ping -"$fam" -c 2 -q -W 2 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%d", $5}')
    [ -z "$rtt" ] && continue
    [ "$rtt" -lt "$best_rtt" ] && { best_rtt=$rtt; best=$line; }
  done
  [ -n "$best" ] && echo "$best"
}

run_single(){ # run_single [4|6]
  local fam="${1:-4}"
  ensure_pkg iperf3 ping || return 1
  local peer_line; peer_line=$(pick_peer "$fam")
  [ -n "$peer_line" ] || { warn "v$fam: 无可达 iperf3 对端"; return 1; }
  local host=${peer_line%%|*} city
  city=$(echo "$peer_line" | cut -d'|' -f2)
  echo
  echo "${C_BOLD}── 单线程测速 IPv$fam（对端: $city $host）──${C_0}"
  printf '  %-10s %s Mbps\n' "发送↑" "$(iperf_try "$fam" "$host" up   || echo 失败)"
  printf '  %-10s %s Mbps\n' "接收↓" "$(iperf_try "$fam" "$host" down || echo 失败)"
}

# iperf_try <fam> <host> <up|down> — 单流 8s；公共服务器 5201 常占线，轮换 4 个端口
# 结果解析：-f m 固定 Mbits 单位；sender 行速率在 $(NF-3)，receiver 行在 $(NF-2)
iperf_try(){
  local fam="$1" host="$2" dir="$3" p out v
  for p in 5201 5202 5203 5204; do
    if [ "$dir" = up ]; then
      out=$(wrap_run iperf3 -"$fam" -c "$host" -p "$p" -P 1 -t 8 -f m 2>/dev/null)
      v=$(echo "$out" | awk '$NF=="sender"{v=$(NF-3)} END{if(v!="") printf "%.1f", v}')
    else
      out=$(iperf3 -"$fam" -c "$host" -p "$p" -P 1 -t 8 -f m -R 2>/dev/null)
      v=$(echo "$out" | awk '$NF=="receiver"{v=$(NF-2)} END{if(v!="") printf "%.1f", v}')
    fi
    [ -n "$v" ] && { echo "$v"; return 0; }
  done
  warn "  $host 4 个端口均失败（占线/防火墙），可稍后重试"
  return 1
}

run_single_dual(){
  echo
  echo "${C_BOLD}── 单线程双栈测速（iperf3 -P 1，8 秒/方向）──${C_0}"
  ip -4 route show default 2>/dev/null | grep -q . && run_single 4 || warn "无 IPv4，跳过"
  ip -6 route show default 2>/dev/null | grep -q . && run_single 6 || warn "无 IPv6，跳过"
}

#── 模块 4: 流媒体解锁（RegionRestrictionCheck）──────────────────────────────
run_media(){
  info "运行流媒体解锁检测（check.unlock.media）..."
  gh_run_limited "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh" -M 0 2>/dev/null
}

#── 组合 ─────────────────────────────────────────────────────────────────────
mode_full(){  # 融合怪完全体
  banner
  warn "完全体约 7 分钟（低配机最差可到 30+ 分钟），Ctrl-C 可中断"
  run_goecs
}
mode_net(){   # 仅网络
  banner
  run_goecs -cpu=false -memory=false -disk=false -ut=false -email=false
}
mode_ip(){
  banner
  run_ipq
}
mode_media(){
  banner
  run_media
}
mode_hw(){
  banner
  if [ "$LOW_POWER" = 1 ] || [ -n "${MYVPS_CPU:-}${MYVPS_MEM:-}" ] && [ "$NO_LIMIT" != 1 ]; then
    warn "限额模式下 CPU/内存跑分数字会偏低（受限是真实的，但分数不能与别人对比）"
  fi
  run_goecs -backtrace=false -nt3=false -ping=false -speed=false -ut=false -email=false -security=false
}
mode_single(){
  banner
  run_single_dual
}
mode_all(){   # 日常推荐
  banner
  run_ipq
  run_single_dual
  info "回程与三网延迟请运行: ./nettest.sh"
}

#── 菜单 ─────────────────────────────────────────────────────────────────────
menu(){
  banner
  echo "  1) 日常体检组合   IP质量 + 单线程双栈测速（约 4 分钟）推荐"
  echo "  2) 融合怪完全体   综合+网络+解锁 全测（约 7-30 分钟）"
  echo "  3) 仅网络方向     回程+延迟+测速（约 6 分钟）"
  echo "  4) 仅 IP 质量     风险/原生/NAT/黑名单（约 20 秒）"
  echo "  5) 仅流媒体解锁   Netflix/Disney+/AI 等（约 1 分钟）"
  echo "  6) 仅硬件性能     CPU/内存/磁盘（约 5 分钟）"
  echo "  7) 单线程双栈测速 iperf3 收/发（约 3 分钟）"
  if [ "$LOW_POWER" = 1 ]; then
    echo
    echo "  ${C_G}[限额模式]${C_0} CPU≤${CPU_LIMIT}% 内存≤${MEM_LIMIT}MB（应对受限套餐）"
  else
    echo
    echo "  ${C_D}受限套餐（CPU 峰值受限/小内存）？加 --low-power 限额运行:${C_0}"
    echo "  ${C_D}  ./bench.sh --low-power full    或自定义: MYVPS_CPU=30 MYVPS_MEM=400 ./bench.sh full${C_0}"
  fi
  echo
  printf '选择: '
  read -r sel || exit 0
  case "$sel" in
    1) mode_all ;;
    2) mode_full ;;
    3) mode_net ;;
    4) mode_ip ;;
    5) mode_media ;;
    6) mode_hw ;;
    7) mode_single ;;
    *) exit 0 ;;
  esac
}

setup_limit

case "${1:-menu}" in
  full)    mode_full ;;
  net)     mode_net ;;
  ip)      mode_ip ;;
  media)   mode_media ;;
  hw)      mode_hw ;;
  single)  mode_single ;;
  all)     mode_all ;;
  menu|--menu|-m) menu ;;
  -h|--help|help) sed -n '2,26p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
  *) die "未知参数: $1（see --help）" ;;
esac
