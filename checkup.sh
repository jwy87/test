#!/usr/bin/env bash
#=============================================================================
# checkup.sh — VPS 秒级体检（系统 / 网络 / BBR / 到大陆三网延迟）
#
# 纯净轻量：只读检测，不改任何系统配置。目标 IP 为融合怪/backtrace 同款
# 三网京沪穗表（2026-10 从 oneclickvirt/backtrace 源码核对）。
#
# 用法：
#   ./checkup.sh            全部体检
#   ./checkup.sh --no-ping  跳过大陆延迟（纯离线检查）
#   ./checkup.sh --json     JSON 输出（机器可读）
#=============================================================================
set -uo pipefail

VERSION="1.0.0"

if [ -t 1 ]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
  C_B=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_BOLD=''; C_D=''; C_0=''
fi

DO_PING=1; OUT_JSON=0
for a in "$@"; do
  case "$a" in
    --no-ping) DO_PING=0 ;;
    --json)    OUT_JSON=1 ;;
  esac
done

#── 工具 ─────────────────────────────────────────────────────────────────────
warn(){ printf '  %s %s\n' "${C_Y}[!]${C_0}" "$*"; }
sec(){ echo; echo "${C_BOLD}── $1 ──${C_0}"; }
kv(){ printf '  %-24s %s\n' "$1" "$2"; }
j(){ [ "$OUT_JSON" = 1 ] && printf '%s\n' "$1" || true; }
has(){ command -v "$1" >/dev/null 2>&1; }

#── 三网目标（oneclickvirt/backtrace v0.0.21 同款）────────────────────────────
CT_BJ=219.141.140.10; CU_BJ=202.106.195.68; CM_BJ=221.179.155.161
CT_SH=202.96.209.133;  CU_SH=210.22.97.1;   CM_SH=211.136.112.200
CT_GZ=58.60.188.222;   CU_GZ=210.21.196.6;  CM_GZ=120.196.165.24
CT_BJ6=2400:89c0:1053:3::69;  CU_BJ6=2400:89c0:1013:3::54;  CM_BJ6=2409:8c00:8421:1303::55
CT_SH6=240e:e1:aa00:4000::24; CU_SH6=2408:80f1:21:5003::a;  CM_SH6=2409:8c1e:75b0:3003::26
CT_GZ6=240e:97c:2f:3000::44;  CU_GZ6=2408:8756:f50:1001::c; CM_GZ6=2409:8c54:871:1001::12

PING_COUNT=4

# var_value <名字> — 取已定义变量的值（替代 eval，变量名全部来自本文件静态定义）
var_value(){ eval "printf '%s' \"\${$1:-}\""; }

# tcp_ping <ip> [port] — 纯 bash TCP 探测（无 ping 权限时的兜底）
tcp_ping(){
  local ip="$1" port="${2:-80}" t0 t1
  t0=$(date +%s%N)
  if (echo > /dev/tcp/"${ip%:*}"/"$port") 2>/dev/null || \
     timeout 2 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null; then
    t1=$(date +%s%N)
    echo $(( (t1-t0)/1000000 ))
  else
    echo ""
  fi
}

# ping4 <目标> — 返回 "avg_ms loss%"
ping4(){
  local ip="$1"
  if has ping; then
    ping -4 -c $PING_COUNT -q -W 2 "$ip" 2>/dev/null \
      | awk -F'/' '/rtt|round-trip/{printf "%d", $5}'
  else
    local ms; ms=$(tcp_ping "$ip" 80); echo "${ms:-}"
  fi
}
ping6(){
  local ip="$1"
  if has ping; then
    ping -6 -c $PING_COUNT -q -W 2 "$ip" 2>/dev/null \
      | awk -F'/' '/rtt|round-trip/{printf "%d", $5}'
  fi
}

#── 1. 系统信息 ──────────────────────────────────────────────────────────────
sec "系统信息"
OS_PRETTY=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)
[ -n "$OS_PRETTY" ] || OS_PRETTY="$(uname -s) $(uname -r)"
KV_VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
[ "$KV_VIRT" = none ] && KV_VIRT=physical
RAM=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
# 文件系统名可能含空格（如 "C:/Program Files/Git"），按列特征而非固定位置取值
DISK=$(df -hP / 2>/dev/null | awk 'NR==2{
  for(i=NF;i>=1;i--){
    if($i ~ /^[0-9.]+[KMGTP]?$/) {avail=$i; used=$(i-1); size=$(i-2); break}
  }
  for(i=1;i<=NF;i++) if($i ~ /%/) {cap=$i; break}
  print size" 总 / "avail" 可用（"cap"）"}')
LOAD=$(cat /proc/loadavg | awk '{print $1" "$2" "$3}')
UPTIME=$(uptime -p 2>/dev/null || awk '{print int($1/86400)"天"}' /proc/uptime)
kv "系统" "$OS_PRETTY"
kv "内核" "$(uname -r)"
kv "架构" "$(uname -m)"
kv "虚拟化" "$KV_VIRT"
kv "CPU" "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs) ($(nproc)核)"
kv "内存" "${RAM}MB"
kv "磁盘(/)" "$DISK"
kv "负载" "$LOAD"
kv "已运行" "$UPTIME"
j "{\"section\":\"system\",\"os\":\"$OS_PRETTY\",\"kernel\":\"$(uname -r)\",\"virt\":\"$KV_VIRT\",\"ram_mb\":$RAM}"

#── 2. 网络接口与 IP 双栈 ────────────────────────────────────────────────────
sec "IP 双栈"
V4=""; V6=""
if has curl; then
  V4=$(curl -4 -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || curl -4 -s --max-time 5 http://ip-api.com/line?fields=query 2>/dev/null)
  V6=$(curl -6 -s --max-time 5 https://api.ip.sb/ip 2>/dev/null)
fi
[ -n "$V4" ] && kv "IPv4 出口" "$V4" || kv "IPv4 出口" "${C_R}无/失败${C_0}"
[ -n "$V6" ] && kv "IPv6 出口" "$V6" || kv "IPv6 出口" "${C_D}无${C_0}"
kv "双栈" "$([ -n "$V4" ] && [ -n "$V6" ] && echo "${C_G}完整双栈${C_0}" || echo "单栈")"
j "{\"section\":\"ip\",\"ipv4\":\"${V4:-null}\",\"ipv6\":\"${V6:-null}\"}"

#── 3. BBR / 拥塞控制状态 ────────────────────────────────────────────────────
sec "拥塞控制"
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
QD=$(sysctl -n net.core.default_qdisc 2>/dev/null)
BBR_V=$(cat /sys/module/tcp_bbr/version 2>/dev/null)
if ! has sysctl && [ ! -d /proc/sys/net ]; then
  warn "当前环境非 Linux（或无 /proc/sys）——拥塞控制检查仅适用于 Linux VPS"
  kv "算法" "N/A"
else
  kv "算法" "${CC:-未知}"
  kv "qdisc" "${QD:-未知}"
  # 调优状态标记
  TUNE_CONF=/etc/sysctl.d/99-myvps-tune.conf
  if [ -f "$TUNE_CONF" ]; then
    tdate=$(grep -m1 '由 myvps tune' "$TUNE_CONF" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    kv "调优状态" "${C_G}已调优${C_0}（myvps${tdate:+，$tdate}）"
  else
    kv "调优状态" "未调优（运行 tune.sh apply）"
  fi
  if [ "${CC:-}" = bbr ]; then
    if [ "${BBR_V:-1}" = 3 ]; then
      kv "BBR 版本" "${C_G}v3${C_0}"
    else
      kv "BBR 版本" "v1（主线内核；v3 需换内核，见 tune.sh kernel）"
    fi
  fi
  kv "可用算法" "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  kv "rmem_max" "$(numfmt --to=iec $(sysctl -n net.core.rmem_max 2>/dev/null) 2>/dev/null || sysctl -n net.core.rmem_max 2>/dev/null)"
  kv "wmem_max" "$(numfmt --to=iec $(sysctl -n net.core.wmem_max 2>/dev/null) 2>/dev/null || sysctl -n net.core.wmem_max 2>/dev/null)"
  [ "$(sysctl -n net.core.rmem_max 2>/dev/null)" -lt 16777216 ] 2>/dev/null && \
    warn "rmem_max < 16MB：不满足 Hysteria2 官方建议（QUIC/UDP 需要）"
  kv "slow_start_after_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
fi
j "{\"section\":\"cc\",\"algorithm\":\"$CC\",\"qdisc\":\"$QD\",\"bbr_version\":\"${BBR_V:-v1}\"}"

#── 4. 大陆三网延迟 ──────────────────────────────────────────────────────────
if [ "$DO_PING" = 1 ]; then
  sec "大陆三网延迟（ICMP ×$PING_COUNT，单位 ms）"
  printf '  %-14s %-10s %-10s %-10s\n' "" "北京" "上海" "广州"
  for isp in CT CU CM; do
    case $isp in
      CT) label="电信";;
      CU) label="联通";;
      CM) label="移动";;
    esac
    bj=$(ping4 "$(var_value "${isp}_BJ")")
    sh=$(ping4 "$(var_value "${isp}_SH")")
    gz=$(ping4 "$(var_value "${isp}_GZ")")
    printf '  %-14s %-10s %-10s %-10s\n' "$label" \
      "$([ -n "$bj" ] && echo "${bj}ms" || echo "-")" \
      "$([ -n "$sh" ] && echo "${sh}ms" || echo "-")" \
      "$([ -n "$gz" ] && echo "${gz}ms" || echo "-")"
  done
  # IPv6（有 v6 才测）
  if [ -n "$V6" ]; then
    echo "  ${C_D}── IPv6 ──${C_0}"
    printf '  %-14s %-10s %-10s %-10s\n' "" "北京" "上海" "广州"
    for isp in CT CU CM; do
      case $isp in CT) label="电信";; CU) label="联通";; CM) label="移动";; esac
      bj=$(ping6 "$(var_value "${isp}_BJ6")")
      sh=$(ping6 "$(var_value "${isp}_SH6")")
      gz=$(ping6 "$(var_value "${isp}_GZ6")")
      printf '  %-14s %-10s %-10s %-10s\n' "$label" \
        "$([ -n "$bj" ] && echo "${bj}ms" || echo "-")" \
        "$([ -n "$sh" ] && echo "${sh}ms" || echo "-")" \
        "$([ -n "$gz" ] && echo "${gz}ms" || echo "-")"
    done
  fi
  echo
  echo "  ${C_D}提示：<50ms 优秀(港/日/韩) | 50-150ms 良好(东南亚) | 150-250ms 正常(美西) | >300ms 偏远${C_0}"
  echo "  ${C_D}完整回程路由判定请用: ./nettest.sh${C_0}"
fi

#── 5. 快速健康检查 ─────────────────────────────────────────────────────────
sec "健康检查"
MEM_AVAIL=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
DISK_PCT=$(df -P / 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if($i ~ /%/) {gsub("%","",$i); print $i; exit}}')
case "$DISK_PCT" in ''|*[!0-9]*) DISK_PCT=""; ;; esac
kv "可用内存" "${MEM_AVAIL}MB"
[ "$RAM" -le 1024 ] && ! swapon --show 2>/dev/null | grep -q . && warn "小内存无 swap：高负载时代理进程可能被 OOM 杀"
if [ -n "$DISK_PCT" ]; then
  kv "磁盘使用率" "${DISK_PCT}%"
  [ "$DISK_PCT" -ge 90 ] && warn "磁盘使用率 ${DISK_PCT}%（>90%）"
fi
# conntrack
CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
if [ -n "$CT_COUNT" ] && [ -n "$CT_MAX" ] && [ "$CT_MAX" -gt 0 ]; then
  kv "conntrack" "$CT_COUNT / $CT_MAX"
  [ "$CT_COUNT" -gt $((CT_MAX*80/100)) ] && warn "conntrack 使用率超 80%"
fi
# 时钟漂移
if has curl; then
  OFFSET=$(curl -s --max-time 5 http://worldtimeapi.org/api/ip 2>/dev/null | grep -oE '"utc_datetime":"[^"]*"' | cut -d'"' -f4 | cut -c1-19)
  [ -n "$OFFSET" ] && kv "UTC 时间(参考)" "$OFFSET"
fi

echo
echo "${C_BOLD}体检完成。${C_0}深度测评: ./bench.sh    调优: ./tune.sh"
