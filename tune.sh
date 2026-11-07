#!/usr/bin/env bash
#=============================================================================
# tune.sh — VPS 节点网络调优（稳定 / 高速 / 低延迟）
#
# 设计原则（来源与甄别说明，2026-10 调研）：
#   1. 主线内核至今只有 BBRv1。BBRv3 需换内核（XanMod / byJoey）且必须重启，
#      本脚本把它作为可选子命令，绝不用"零重启 BBRv3"话术。
#   2. 缓冲区不抄固定值：按 带宽×RTT×内存 推导（BDP 算法吸收自 tcpfit v0.5.9
#      的实测结论，剔除其遥测与推广）。
#   3. Hysteria2 官方文档要求 rmem_max/wmem_max >= 16MB（UDP/QUIC 用）。
#   4. 刻意不设 tcp_notsent_lowat：社区两派分歧（降延迟 vs 拖慢长距起步），
#      默认不动它。
#   5. OpenVZ/LXC 共享内核：只做 sysctl（宿主允许时），不碰内核。
#   6. Skyline Speeder（eBPF CC，内核≥6.12）与本脚本是两套系统：它启用时会
#      接管拥塞控制；本脚本检测到它就不再碰 CC 项，互不打架（见 cmd_skyline）。
#
# 用法：
#   ./tune.sh                 交互式菜单（推荐）
#   ./tune.sh apply           应用调优（默认保守档，全程有确认）
#   ./tune.sh apply --force    强制重新调优（忽略"已调优"检测）
#   ./tune.sh apply --aggressive  激进档（大内存机器）
#   ./tune.sh apply --bw 500 --rtt 50   手动指定带宽(Mbps)与RTT(ms)，跳过探测
#   ./tune.sh status          查看当前调优状态
#   ./tune.sh rollback        回滚到调优前快照
#   ./tune.sh kernel          可选：安装 BBRv3 内核（明确提示需重启）
#   ./tune.sh skyline         可选：Skyline Speeder 高丢包线路加速（eBPF，需内核≥6.12）
#   ./tune.sh v6              IPv6 专项优化（纯 v6 / 双栈机，地址/DNS/MTU/隐私扩展）
#   ./tune.sh swap            swap 助手：小内存机自动推荐大小，回车即开（防 OOM）
#   ./tune.sh verify          校验当前参数是否生效
#=============================================================================
set -uo pipefail

VERSION="1.1.0"
STATE_DIR="/var/lib/myvps-tune"
SNAPSHOT="$STATE_DIR/pre-tune.snapshot"
SYSCTL_FILE="/etc/sysctl.d/99-myvps-tune.conf"
MODULES_FILE="/etc/modules-load.d/myvps-tune.conf"

#── 颜色（非终端自动关闭）──────────────────────────────────────────────────
if [ -t 1 ]; then
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[0;33m'
  C_B=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=''; C_R=''; C_Y=''; C_B=''; C_BOLD=''; C_0=''
fi
info(){ printf '%s %s\n' "${C_B}[*]${C_0}" "$*"; }
ok(){   printf '%s %s\n' "${C_G}[+]${C_0}" "$*"; }
warn(){ printf '%s %s\n' "${C_Y}[!]${C_0}" "$*"; }
die(){  printf '%s %s\n' "${C_R}[x]${C_0}" "$*" >&2; exit "${2:-1}"; }

need_root(){ [ "$(id -u)" = 0 ] || die "需要 root 权限（sudo）"; }

#── 机器画像 ─────────────────────────────────────────────────────────────────
detect_virt(){
  command -v systemd-detect-virt >/dev/null 2>&1 && {
    local v; v=$(systemd-detect-virt 2>/dev/null) || v=""
    [ -n "$v" ] && [ "$v" != "none" ] && { echo "$v"; return; }
  }
  grep -qa 'lxc\|docker\|kubepods' /proc/1/cgroup 2>/dev/null && { echo lxc; return; }
  [ -d /proc/vz ] && { echo openvz; return; }
  grep -q hypervisor /proc/cpuinfo 2>/dev/null && { echo kvm; return; }
  echo unknown
}
CONTAINER_VIRT="openvz lxc docker podman container"
is_container(){ case " $CONTAINER_VIRT " in *" $(detect_virt) "*) return 0;; *) return 1;; esac; }

ram_mb(){ awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo; }
core_n(){ nproc 2>/dev/null || echo 1; }

bbr_version(){
  # 主线 tcp_bbr 是 v1 且无版本标记；google v3 树 MODULE_VERSION=3
  local v; v=$(cat /sys/module/tcp_bbr/version 2>/dev/null) || v=""
  [ -n "$v" ] && { echo "$v"; return; }
  modinfo tcp_bbr 2>/dev/null | awk -F': *' '/^version:/{print $2}'
}

cc_current(){ sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null; }
qdisc_current(){ sysctl -n net.core.default_qdisc 2>/dev/null; }

# Skyline Speeder（eBPF CC）是否正在接管：ssctl 存在且状态含 ACCELERATING
skyline_is_on(){
  command -v ssctl >/dev/null 2>&1 || return 1
  ssctl status 2>/dev/null | grep -q 'ACCELERATING'
}

# 从 SSH 连接目标实测 RTT；连不上/无 ping 返回默认 180ms（跨海典型值）
guess_rtt(){
  local dst r=""
  dst="${SSH_CONNECTION:-}"; dst="${dst%% *}"
  [ -n "$dst" ] || { echo 180; return; }
  command -v ping >/dev/null 2>&1 || { echo 180; return; }
  r=$(ping -c 3 -q -W 3 "$dst" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%d", $5}')
  [ -n "$r" ] && echo "$r" || echo 180
}

# 用最近 iperf3 公共服务器粗测带宽（单流 5 秒，够推导用）
guess_bw(){
  command -v iperf3 >/dev/null 2>&1 || { echo ""; return; }
  local best="" rtt cand
  for cand in speedtest.hkg12.hk.leaseweb.net speedtest.sin1.sg.leaseweb.net \
              speedtest.tyo11.jp.leaseweb.net speedtest.lax12.us.leaseweb.net; do
    rtt=$(ping -c 2 -q -W 2 "$cand" 2>/dev/null | awk -F'/' '/rtt|round-trip/{printf "%d", $5}')
    [ -n "$rtt" ] && { echo "$cand"; return; }
  done
  echo ""
}

probe_bw(){
  # 带宽探测：对最近可达的公共 iperf3 服务器跑单流上传 5 秒（文本行解析，与 bench.sh 同法）
  local peer; peer=$(guess_bw)
  [ -n "$peer" ] || { echo ""; return; }
  timeout 30 iperf3 -c "$peer" -P 1 -t 5 -f m 2>/dev/null \
    | awk '$NF=="sender"{v=$(NF-3)} END{if(v!="") printf "%d", v}'
}

#── BDP 推导（算法吸收自 tcpfit，公式有实测数据背书）─────────────────────────
calc_bdp(){ awk -v b="$1" -v r="$2" 'BEGIN{printf "%d", b*1000000/8*(r/1000)}'; }   # 字节

# 缓冲上限 = 2×BDP + 2MiB，受 内存/32 封顶（≥8 条大流并发），下限 4MB
calc_buf_max(){
  awk -v b="$1" -v m="$2" 'BEGIN{
    v = b*2 + 2097152
    cap = m*32768; if(cap > 268435456) cap = 268435456
    if(v > cap) v = cap
    if(v < 4194304) v = 4194304
    printf "%d", v
  }'
}
# tcp_mem 低/压力/最大 = 内存 1/16, 1/8, 1/4（单位：页，4KB）
calc_tcp_mem(){
  awk -v m="$1" 'BEGIN{
    pg = m*1024/4
    low = int(pg/16); pres = int(pg/8); max = int(pg/4)
    if(low<4096) low=4096; if(pres<8192) pres=8192; if(max<16384) max=16384
    printf "%d %d %d", low, pres, max
  }'
}

#── 快照 / 回滚（回滚清单 = 本脚本可能改动的全部键）──────────────────────────
TUNED_KEYS="
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_mem
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_adv_win_scale
net.core.netdev_max_backlog
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_sack
net.ipv4.tcp_dsack
net.ipv4.tcp_fastopen
net.ipv4.tcp_syncookies
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_keepalive_time
net.ipv4.ip_local_port_range
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
net.netfilter.nf_conntrack_max
net.ipv4.tcp_timestamps
"

take_snapshot(){
  mkdir -p "$STATE_DIR"
  [ -f "$SNAPSHOT" ] && return 0   # 保留最早一份，回滚回到"第一次调优前"
  local k v; : > "$SNAPSHOT"
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    printf '%s=%s\n' "$k" "$v" >> "$SNAPSHOT"
  done <<< "$TUNED_KEYS"
  ok "已备份当前参数到 $SNAPSHOT"
}

cmd_rollback(){
  need_root
  [ -f "$SNAPSHOT" ] || die "没有快照可回滚（$SNAPSHOT 不存在）"
  info "回滚到调优前状态..."
  local k v n=0
  while IFS='=' read -r k v; do
    sysctl -qw "$k=$v" 2>/dev/null && n=$((n+1))
  done < "$SNAPSHOT"
  rm -f "$SYSCTL_FILE" "$MODULES_FILE"
  # initcwnd 恢复：重建默认路由时不带 initcwnd/initrwnd
  if ip route show default 2>/dev/null | grep -q .; then
    local orig; orig=$(ip route show default | head -1)
    local stripped
    stripped=$(echo "$orig" | sed -E 's/\s?initcwnd [0-9]+//; s/\s?initrwnd [0-9]+//')
    # shellcheck disable=SC2086  # 必须按词拆分传给 ip
    ip route change default ${stripped#default} 2>/dev/null \
      && ok "initcwnd 已恢复默认" || warn "initcwnd 恢复失败，请手动检查: ip route show default"
  fi
  rm -rf "$STATE_DIR"
  ok "已回滚 $n 项参数；initcwnd 已处理；配置文件已删除"
  warn "tcp_mem 等部分参数回滚后建议重启一次以彻底还原"
  skyline_is_on && warn "Skyline Speeder 仍在接管 CC（与本次回滚无关）；要一并卸载: ./tune.sh skyline 选卸载"
}

#── 应用调优 ─────────────────────────────────────────────────────────────────
# initcwnd：首屏低延迟关键项；运行时设置，重启丢失（重跑 apply 自动补回）
apply_initcwnd(){
  is_container && return 1
  ip route show default 2>/dev/null | grep -q . || return 1
  local orig; orig=$(ip route show default | head -1)
  # shellcheck disable=SC2086  # 路由参数必须按词拆分
  if ip route change default ${orig#default} initcwnd 20 initrwnd 20 2>/dev/null; then
    ok "initcwnd/initrwnd = 20"
    return 0
  fi
  warn "initcwnd 设置失败（部分虚拟化不支持），已跳过"
  return 1
}

cmd_apply(){
  need_root
  local aggressive=0 bw="" rtt="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --aggressive|-a) aggressive=1; shift ;;
      --bw) bw="$2"; shift 2 ;;
      --rtt) rtt="$2"; shift 2 ;;
      --force|-f) force=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done

  #── 幂等检测：已调优时跳过重复调优（--force 强制重来）────────────────────
  if [ -f "$SYSCTL_FILE" ] && [ "$force" != 1 ]; then
    local tuned_at exp_cc cur_cc exp_rmem cur_rmem drift=0 ic_lost=0
    tuned_at=$(grep -m1 '由 myvps tune' "$SYSCTL_FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+' | head -1)
    ok "检测到已有调优配置${tuned_at:+（${tuned_at} 生成）}"
    exp_cc=$(grep -m1 '^net.ipv4.tcp_congestion_control' "$SYSCTL_FILE" | awk '{print $3}')
    exp_rmem=$(grep -m1 '^net.core.rmem_max' "$SYSCTL_FILE" | awk '{print $3}')
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    # Skyline 接管时 CC 必然不等于配置值，属预期，不算漂移
    if ! skyline_is_on; then
      [ -n "$exp_cc" ] && [ "$exp_cc" != "$cur_cc" ] && drift=1
    fi
    [ -n "$exp_rmem" ] && [ "$exp_rmem" != "$cur_rmem" ] && drift=1
    # initcwnd 是运行时设置，重启即丢（属正常）
    if ! is_container && ip route show default 2>/dev/null | head -1 | grep -q 'initcwnd'; then :; else ic_lost=1; fi

    if [ "$drift" = 1 ]; then
      warn "检测到参数漂移（当前 cc=$cur_cc rmem=$cur_rmem ≠ 配置值），自动重新调优..."
    elif [ "$ic_lost" = 1 ]; then
      apply_initcwnd   # 只补回 initcwnd，不再全量重跑
      ok "其余参数仍生效，已跳过重复调优（强制重调: ./tune.sh apply --force）"
      return 0
    else
      ok "全部参数生效中，已跳过重复调优（强制重调: ./tune.sh apply --force）"
      return 0
    fi
  fi

  local virt ram cores
  virt=$(detect_virt); ram=$(ram_mb); cores=$(core_n)
  echo
  echo "${C_BOLD}── 机器画像 ──${C_0}"
  printf '  %-14s %s\n' "虚拟化" "$virt" "内存" "${ram}MB" "CPU核心" "$cores" \
         "内核" "$(uname -r)" "当前CC" "$(cc_current)" "当前qdisc" "$(qdisc_current)"
  local bv; bv=$(bbr_version)
  [ -n "$bv" ] && printf '  %-14s %s\n' "BBR版本" "$bv"

  if is_container; then
    warn "检测到 $virt（共享宿主内核）：跳过内核相关项，仅尝试 sysctl 调优"
    warn "  若宿主禁止写入 sysctl，参数会静默失败——以 verify 输出为准"
  fi

  #── 带宽与 RTT ──
  [ -n "$rtt" ] || { rtt=$(guess_rtt); info "实测到你 SSH 来源 RTT ≈ ${rtt}ms"; }
  [ -n "$bw" ] || {
    command -v iperf3 >/dev/null 2>&1 && {
      info "探测可用带宽（iperf3 单流 5s，可选跳过：Ctrl-C 后用 --bw 手动指定）..."
      bw=$(probe_bw)
    }
  }
  [ -n "$bw" ] || { bw=500; warn "未测得带宽，按 500Mbps 推导（可 --bw 重跑）"; }

  #── 推导 ──
  local bdp buf_max tcp_mem
  bdp=$(calc_bdp "$bw" "$rtt")
  buf_max=$(calc_buf_max "$bdp" "$ram")
  tcp_mem=$(calc_tcp_mem "$ram")  # 激进档：缓冲上限 ×2（仍受内存/32 封顶约束，只对小 BDP 机器有感）
  [ "$aggressive" = 1 ] && buf_max=$(calc_buf_max "$((bdp*2))" "$ram")
  # Hysteria2 官方要求 rmem/wmem_max ≥ 16MB（QUIC/UDP）；内存 ≥1GB 的机器保底 16MB
  if [ "$ram" -ge 1024 ] && [ "$buf_max" -lt 16777216 ]; then
    buf_max=16777216
    warn "BDP 较小，缓冲上限已抬到 16MB（Hysteria2 官方要求，rmem_max 为上限非预分配）"
  fi
  # buf_default：起步值取 min(2MB, buf_max)——tcp_moderate_rcvbuf 会按需增长
  local buf_def; buf_def=$(( buf_max < 2097152 ? buf_max : 2097152 ))

  echo
  echo "${C_BOLD}── 推导结果 ──${C_0}"
  printf '  %-14s %s Mbps × %s ms = %.1f MB\n' "BDP" "$bw" "$rtt" "$(awk -v v="$bdp" 'BEGIN{print v/1048576}')"
  printf '  %-14s %s MB（上限=2×BDP+2MB，内存1/32封顶）\n' "缓冲上限" "$(awk -v v="$buf_max" 'BEGIN{print int(v/1048576)}')"
  printf '  %-14s %s MB（起步值，按需自动增长）\n' "缓冲默认" "$(awk -v v="$buf_def" 'BEGIN{print int(v/1048576)}')"
  printf '  %-14s %s\n' "tcp_mem" "$(echo "$tcp_mem" | awk '{printf "%dM/%dM/%dM", $1*4/1024, $2*4/1024, $3*4/1024}')"
  [ "$aggressive" = 1 ] && warn "激进档：缓冲上限翻倍（仅大带宽跨海线路有感）"

  #── 拥塞控制：Skyline 启用中则整段让位（它接管 CC，且会守住设置）──────────
  if skyline_is_on; then
    warn "Skyline Speeder 正在加速（ACCELERATING）：跳过本脚本的 CC/qdisc 项，缓冲区等其余调优照常"
    local cc=""   # 空 = 不写 CC/qdisc 两行
  else
  #── 拥塞控制：有 bbr 用 bbr，没有用 cubic（不装内核不吹 BBRv3）──
  local cc=bbr
  modprobe tcp_bbr 2>/dev/null || true
  has_word(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
  has_word "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)" bbr \
    || { warn "内核无 BBR，回退 cubic（换 BBRv3 内核见: ./tune.sh kernel）"; cc=cubic; }
  fi  # skyline_is_on 结束

  take_snapshot

  #── 写配置（临时文件 + 原子替换，逐项校验，拒绝的自动注释）────────────────
  local tmp; tmp=$(mktemp "${SYSCTL_FILE}.XXXXXX") || die "无法创建临时文件（磁盘满/只读?）"
  # Skyline 让位时 CC/qdisc 两行整段不写（写空值会报错，注释行不参与试写）
  local cc_block="net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $cc"
  [ -z "$cc" ] && cc_block="# Skyline Speeder 启用中：CC/qdisc 由它接管，本文件不设（卸载后重跑 apply 恢复 bbr+fq）"
  if ! cat > "$tmp" <<EOF
# 由 myvps tune v$VERSION 生成 $(date '+%F %T')
# 带宽=${bw}Mbps RTT=${rtt}ms 内存=${ram}MB CC=${cc:-由Skyline接管}
# 重新生成: ./tune.sh apply [--bw N --rtt N]

$cc_block

# —— TCP/UDP 缓冲区（BDP 推导；rmem/wmem ≥16MB 同时满足 Hysteria2 官方要求）——
net.core.rmem_max = $buf_max
net.core.wmem_max = $buf_max
net.core.rmem_default = $buf_def
net.core.wmem_default = $buf_def
net.ipv4.tcp_rmem = 4096 $buf_def $buf_max
net.ipv4.tcp_wmem = 4096 $buf_def $buf_max
net.ipv4.tcp_mem = $tcp_mem
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1

# —— 队列与并发（代理节点并发连接承载）——
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535

# —— 低延迟关键项 ——
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1

# —— conntrack（模块加载后才存在，先 modprobe 再写）——
net.netfilter.nf_conntrack_max = 262144

# 刻意不设：
#   tcp_notsent_lowat —— 社区两派分歧（降延迟 vs 拖慢长距起步），默认不动
#   tcp_reordering    —— 现代内核走 RACK，调高只推迟快速重传
# myvps-tune-end
EOF
  then rm -f "$tmp"; die "写入配置失败，未做任何改动"; fi

  grep -qx '# myvps-tune-end' <(tail -1 "$tmp") || { rm -f "$tmp"; die "配置生成不完整，已放弃"; }

  # conntrack 键要先加载模块才能写入
  modprobe nf_conntrack 2>/dev/null || true
  printf '%s\n' tcp_bbr nf_conntrack > "$MODULES_FILE"

  chmod 644 "$tmp" && mv -f "$tmp" "$SYSCTL_FILE" || { rm -f "$tmp"; die "落盘失败"; }

  # 逐项试写：容器只读/内核拒绝的键自动注释并跳过（避免 systemd-sysctl 开机报错）
  # 试写成功 = 实时已生效；循环读的是打开时的文件句柄，sed -i 换新文件不影响本轮
  local bad=0 line k v
  while IFS= read -r line; do
    case "$line" in \#*|'') continue;; esac
    case "$line" in *=*) ;; *) continue;; esac
    k=$(printf '%s' "${line%%=*}" | tr -d ' \t')
    v=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$k" ] || continue
    if ! sysctl -qw "$k=$v" 2>/dev/null; then
      sed -i "s%^[[:space:]]*${k}[[:space:]]*=%# 本机不支持(容器/内核限制): ${k} =%" "$SYSCTL_FILE"
      warn "  不支持或被拒绝: ${k} = ${v} —— 已注释"
      bad=$((bad+1))
    fi
  done < "$SYSCTL_FILE"

  #── initcwnd（首屏低延迟；容器上通常改不了路由，静默跳过）──
  apply_initcwnd

  echo
  if [ "$bad" -gt 0 ]; then
    ok "调优完成（$bad 项被本机环境拒绝已注释，其余生效）: $SYSCTL_FILE"
  else
    ok "调优完成: $SYSCTL_FILE"
  fi
  echo "  查看状态: ./tune.sh status    回滚: ./tune.sh rollback"
  # 小内存无 swap：直接引导进 swap 助手（回车=开，推荐值自动算好）
  if [ "$ram" -le 1024 ] && ! swapon --show 2>/dev/null | grep -q .; then
    cmd_swap
  fi
}

#── swap 助手：小内存机自动推荐大小，回车即开 ───────────────────────────────
# 推荐：内存 ≤1G → 2G swap；≤2G → 2G；更大不加（代理节点不需要）
# 封顶：不超过磁盘可用空间的一半（小盘机保护）；绝对不碰已有的 swap
cmd_swap(){
  local ram avail_gb rec_gb
  ram=$(ram_mb)
  # /proc/meminfo 的 SwapTotal 对容器显示的是宿主的，用 swapon 判断真实
  if swapon --show 2>/dev/null | grep -q .; then
    ok "已有 swap（swapon --show 可看），无需处理"
    return 0
  fi
  # df 列序不固定（挂载点可能带空格），从右找第一个"纯数字G"的字段 = Available
  avail_gb=$(df -BG / 2>/dev/null | awk 'NR==2{for(i=NF;i>=1;i--){if($i ~ /^[0-9]+G$/){gsub("G","",$i);print $i; exit}}}')
  case "$avail_gb" in ''|*[!0-9]*) avail_gb=1 ;; esac
  # 推荐大小：小内存机推荐 2G；磁盘可用不足 4G 时按一半封顶（至少 1G）
  rec_gb=2
  if [ "$avail_gb" -lt 4 ]; then
    rec_gb=$(( avail_gb / 2 ))
    [ "$rec_gb" -lt 1 ] && rec_gb=1
  fi
  echo
  echo "${C_BOLD}── swap 内存兜底 ──${C_0}"
  echo "  内存 ${ram}MB，无 swap —— 高负载时代理进程可能被 OOM 直接杀掉"
  echo "  推荐 swap 大小: ${C_BOLD}${rec_gb}GB${C_0}（磁盘 / 可用 ${avail_gb}GB）"
  echo "  swap 文件: /swapfile，Swappiness 保持默认（不抢内存，只做兜底）"
  printf '%s 创建并启用? [Enter=开/其他=跳过] '
  read -r ans || ans=""
  [ -n "$ans" ] && { info "已跳过（想用时随时: ./tune.sh swap）"; return 0; }
  if [ -f /swapfile ]; then
    warn "/swapfile 已存在但未启用——先检查: swapon --show、free -m"
    return 1
  fi
  # 容器里的 swap 需要宿主允许（多数 PVE LXC 模板默认禁）——先试再报
  if fallocate -l "${rec_gb}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((rec_gb*1024)) status=none 2>/dev/null; then
    chmod 600 /swapfile
    if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
      # 开机自动挂载（容器里 fstab 的 swap 由宿主忽略，无害）
      grep -q '^/swapfile' /etc/fstab 2>/dev/null || \
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
      ok "swap 已启用: ${rec_gb}GB（free -m 查看；已写入 fstab 开机自动挂）"
      is_container && warn "LXC/容器环境：若重启后 swap 消失，是宿主模板禁了容器 swap（PVE 面板可开）"
      return 0
    fi
    # 失败清理干净
    rm -f /swapfile
    warn "swapon 被拒绝——多数是容器宿主禁了 swap（PVE LXC 需宿主侧开启），已清理残留文件"
    return 1
  fi
  rm -f /swapfile
  warn "磁盘空间不足，swap 创建失败（已清理）"
  return 1
}

#── 状态 ─────────────────────────────────────────────────────────────────────
cmd_status(){
  echo "${C_BOLD}── 调优状态 ──${C_0}"
  printf '  %-22s %s\n' "内核" "$(uname -r)" \
    "虚拟化" "$(detect_virt)" \
    "拥塞控制" "$(cc_current)" \
    "qdisc" "$(qdisc_current)"
  local bv; bv=$(bbr_version)
  printf '  %-22s %s\n' "BBR 版本" "${bv:-v1或未加载}"
  if command -v ssctl >/dev/null 2>&1; then
    if skyline_is_on; then
      printf '  %-22s %s\n' "Skyline Speeder" "ACCELERATING（接管中，CC 由它管）"
    else
      printf '  %-22s %s\n' "Skyline Speeder" "已安装未加速（ssctl status 查看）"
    fi
  fi
  if [ -f "$SYSCTL_FILE" ]; then
    echo "  配置文件: $SYSCTL_FILE"
    grep -v '^#' "$SYSCTL_FILE" | grep '=' | while IFS= read -r l; do
      printf '  %-38s %s\n' "${l%%=*}" "$(sysctl -n "${l%%=*}" 2>/dev/null || echo '-')"
    done
  else
    echo "  配置文件: 未创建（未调优或已回滚）"
  fi
  ip route show default 2>/dev/null | grep -o 'initcwnd [0-9]*' | head -1 | xargs -r -I{} echo "  路由: {}"
  [ -f "$SNAPSHOT" ] && echo "  快照: $SNAPSHOT（$(wc -l < "$SNAPSHOT") 项，可回滚）"
}

#── 校验 ─────────────────────────────────────────────────────────────────────
cmd_verify(){
  local pass=0 fail=0
  check(){ # check <描述> <实际值> <期望值>
    if [ "$2" = "$3" ]; then ok "  $1 = $2"; pass=$((pass+1))
    else warn "  $1 = $2（期望 $3）"; fail=$((fail+1)); fi
  }
  echo "${C_BOLD}── 参数校验 ──${C_0}"
  if skyline_is_on; then
    ok "  拥塞控制 = $(cc_current)（Skyline Speeder 接管中，本脚本不校验此项）"
    pass=$((pass+1))
  else
    check "拥塞控制" "$(cc_current)" "$(grep '^net.ipv4.tcp_congestion_control' "$SYSCTL_FILE" 2>/dev/null | awk '{print $3}')"
    check "qdisc" "$(qdisc_current)" "$(grep '^net.core.default_qdisc' "$SYSCTL_FILE" 2>/dev/null | awk '{print $3}')"
  fi
  check "rmem_max" "$(sysctl -n net.core.rmem_max 2>/dev/null)" "$(grep '^net.core.rmem_max' "$SYSCTL_FILE" 2>/dev/null | awk '{print $3}')"
  check "slow_start_after_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)" "0"
  check "mtu_probing" "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)" "1"
  echo
  [ "$fail" = 0 ] && ok "全部通过（$pass 项）" || warn "$fail 项未生效（多为容器限制或需重启）"
}

#── 可选：BBRv3 内核安装（明确提示需重启）────────────────────────────────────
supported_xanmod(){
  [ "$(uname -m)" = x86_64 ] || return 1
  command -v apt >/dev/null 2>&1 || return 1
  # 用 /etc/os-release（lsb_release 在精简镜像常缺失）；仓库实测仅 bookworm/trixie/noble
  local id ver
  id=$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  ver=$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
  case "$id" in
    debian)  case "$ver" in 12|13) return 0;; esac;;
    ubuntu)  [ "${ver%%.*}" -ge 24 ] 2>/dev/null && return 0;;
  esac
  return 1
}

cmd_kernel(){
  need_root
  echo "${C_BOLD}── BBRv3 内核安装（可选） ──${C_0}"
  echo
  echo "  事实先说清楚："
  echo "  · 主线内核只有 BBRv1；BBRv3 必须换内核，换内核${C_R}必须重启${C_0}——不存在'零重启'"
  echo "  · '3.2-Pro' 无此版本（XanMod 包名 x64v3 是 CPU 指令集等级，与 BBR 版本无关）"
  echo "  · BBRv1→v3 对代理节点的实际提升有限（v3 主要修带宽估计与 RTT 不公平），"
  echo "    sysctl 调优的收益通常比换内核更大、更安全"
  echo
  is_container && die "容器环境（$(detect_virt)）无法更换内核"
  [ "$(cc_current)" = bbr ] && [ "$(bbr_version)" = 3 ] && { ok "已是 BBRv3，无需安装"; return 0; }

  echo "  可选方案："
  echo "    1) XanMod LTS（apt 仓库，Debian12/13 + Ubuntu24.04 + x86_64，最稳）"
  echo "    2) byJoey/Actions-bbr-v3（跟随 kernel.org stable，Debian12+/Ubuntu24.04+，含 arm64）"
  echo "    0) 取消"
  echo
  printf '  选择 [0-2]: '
  read -r sel || sel=0
  case "$sel" in
    1)
      supported_xanmod || die "当前系统不在 XanMod 支持列表（Debian12/13、Ubuntu24.04、x86_64）"
      info "添加 XanMod 仓库并安装 LTS 内核（BBRv3 内置）..."
      # 依赖：wget 取密钥、gpg 转密钥环（精简镜像可能缺）
      local need_pkgs=""
      command -v wget >/dev/null 2>&1 || need_pkgs="$need_pkgs wget"
      command -v gpg  >/dev/null 2>&1 || need_pkgs="$need_pkgs gnupg"
      [ -n "$need_pkgs" ] && apt-get install -y $need_pkgs 2>/dev/null
      command -v wget >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1 \
        || die "缺少 wget/gpg 且自动安装失败"
      local codename
      codename=$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
      case "$codename" in bookworm|trixie|noble) ;; *) die "未知系统代号: $codename";; esac
      install -d -m 0755 /etc/apt/keyrings
      wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -vo /etc/apt/keyrings/xanmod-archive-keyring.gpg \
        || die "密钥下载失败（网络?）"
      echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $codename main" \
        > /etc/apt/sources.list.d/xanmod-release.list
      apt update && apt install -y linux-xanmod-lts-x64v3 \
        || { rm -f /etc/apt/sources.list.d/xanmod-release.list; die "安装失败，已移除仓库配置"; }
      echo
      ok "内核已安装。${C_R}需要重启生效${C_0}：reboot"
      warn "重启前建议确认 grub 默认启动项为新内核（多数云面板支持救援模式兜底）"
      ;;
    2)
      info "运行 byJoey/Actions-bbr-v3 官方安装器..."
      bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh) \
        || die "安装器执行失败"
      echo
      ok "按安装器提示操作，${C_R}装完需重启${C_0}"
      ;;
    *) info "已取消";;
  esac
}

#── 可选：Skyline Speeder 高丢包线路加速（eBPF，无需重启）────────────────────
# 上游: github.com/CYBERVERSE-Research/skyline-speeder（GPL-2.0，2026-10 核实活跃）
# 定位: 内核≥6.12 的 VPS，晚高峰丢包 10-30% 的普线（163/4837）效果最明显；
#       它自动估带宽（不像 tcp-brutal 要手填），有拥塞护栏（延迟+ECN），可一键卸载
cmd_skyline(){
  need_root
  echo "${C_BOLD}── Skyline Speeder 高丢包线路加速（可选） ──${C_0}"
  echo
  echo "  它是什么：eBPF 拥塞控制，接管本机 TCP 发送端。专治${C_BOLD}随机丢包 10-30%、RTT 100-300ms${C_0}"
  echo "  的跨境普线（163/4837 晚高峰）——丢包不降速，按实测带宽发送，真堵了（延迟涨/ECN）才刹车。"
  echo "  客户端什么都不用装。比 tcp-brutal 省心：不用手填带宽；比 BBR 抗丢包。"
  echo
  echo "  ${C_Y}先判断适不适合你：${C_0}"
  echo "  ✅ 回程是 163/4837 普线，晚高峰卡（nettest.sh route 可查回程）"
  echo "  ✅ 内核 ≥ 6.12（Debian 13 自带；Debian 12 / Ubuntu 22.04/24.04 自带的都不够，先 ./tune.sh kernel 或换系统）"
  echo "  ❌ GIA/9929/CMIN2 优质线路——不怎么丢包，BBR 就够，没必要"
  echo "  ❌ 丢包是 VPS 出口自身拥塞（自己发太猛排队溢出）——用了反而更慢"
  echo
  # 环境预检
  is_container && { warn "容器环境（$(detect_virt)）：Skyline 需要 eBPF struct_ops，共享内核装不了"; return 1; }
  local kmaj; kmaj=$(uname -r | cut -d. -f1-2 | awk -F. '{print $1*1000+$2}')
  [ "$kmaj" -ge 6012 ] 2>/dev/null \
    || { warn "内核 $(uname -r) < 6.12，不满足要求（BBRv3 内核也不够新时需换 Debian 13 / 手动升内核）"; return 1; }
  if skyline_is_on; then
    ok "Skyline 已在加速中（ACCELERATING）"
    echo "  看加速中的连接: sudo ssctl flows    暂停: sudo ssctl drain    卸载: 见下方选项"
    printf '%s 要卸载吗? [y/N] '
    read -r ans || ans=n
    case "$ans" in
      [Yy]*)
        curl -fsSL https://raw.githubusercontent.com/CYBERVERSE-Research/skyline-speeder/main/scripts/bootstrap.sh \
          | bash -s -- --uninstall \
          && { ok "已卸载，切回 bbr + fq"; info "重跑 ./tune.sh apply --force 恢复本工具箱的 CC 设置"; } \
          || warn "卸载失败（网络?），可手动重试或看上游文档"
        ;;
      *) info "保持现状";;
    esac
    return 0
  fi

  echo "  装完即时生效（无需重启），${C_Y}只对新连接生效${C_0}——测试时记得重新连接"
  echo "  一键卸载随时可退：切回 bbr + fq，不留后台"
  echo
  printf '%s 安装 Skyline Speeder? [y/N] '
  read -r ans || ans=n
  case "$ans" in
    [Yy]*) ;;
    *) info "已取消（GIA 等优质线路用户不需要它）"; return 0 ;;
  esac
  info "运行上游官方安装器（预编译包，无需编译工具；失败自动改源码构建）..."
  curl -fsSL https://raw.githubusercontent.com/CYBERVERSE-Research/skyline-speeder/main/scripts/bootstrap.sh | bash \
    || die "安装器执行失败（网络?）——可先看脚本再装: git clone https://github.com/CYBERVERSE-Research/skyline-speeder.git"
  echo
  if skyline_is_on; then
    ok "Skyline 已接管本机新连接（ACCELERATING）"
  else
    warn "已安装但未见 ACCELERATING 状态，运行 sudo ssctl status 看第一行："
    echo "    ATTACHED, NOT DEFAULT / STANDBY → 执行: sudo ssctl enable"
  fi
  echo
  echo "  ${C_BOLD}与本工具箱的关系${C_0}：它接管 CC/qdisc，tune.sh 检测到它会自动跳过这两项，"
  echo "  缓冲区（BDP）/initcwnd 等其余调优照常叠加生效。卸载它后重跑 ./tune.sh apply 恢复 bbr+fq。"
}

#── IPv6 专项优化（纯 v6 / 双栈机通用）──────────────────────────────────────
# 面向"主打 v6 的 VPS"（如 v6-only 套餐）：不装任何东西，只调 sysctl。
# 设计原则与 apply 一致：可回滚、逐项试写、拒绝的自动注释。
V6_SYSCTL_FILE="/etc/sysctl.d/99-myvps-v6.conf"
V6_TUNED_KEYS="
net.ipv6.conf.all.use_tempaddr
net.ipv6.conf.default.use_tempaddr
net.ipv6.conf.all.disable_ipv6
net.ipv6.conf.default.disable_ipv6
net.ipv6.conf.all.accept_ra
net.ipv6.conf.default.accept_ra
net.ipv6.conf.all.forwarding
net.ipv6.conf.default.forwarding
"
v6_snapshot(){
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/pre-v6.snapshot" ] && return 0
  local k v; : > "$STATE_DIR/pre-v6.snapshot"
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    v=$(sysctl -n "$k" 2>/dev/null) || continue
    printf '%s=%s\n' "$k" "$v" >> "$STATE_DIR/pre-v6.snapshot"
  done <<< "$V6_TUNED_KEYS"
}
v6_rollback(){
  [ -f "$STATE_DIR/pre-v6.snapshot" ] || { info "无 v6 快照（未做过 v6 优化）"; return 0; }
  local k v n=0
  while IFS='=' read -r k v; do
    sysctl -qw "$k=$v" 2>/dev/null && n=$((n+1))
  done < "$STATE_DIR/pre-v6.snapshot"
  rm -f "$V6_SYSCTL_FILE" "$STATE_DIR/pre-v6.snapshot"
  ok "已回滚 $n 项 v6 参数，配置文件已删除"
}
cmd_v6(){
  need_root
  echo "${C_BOLD}── IPv6 专项优化 ──${C_0}"
  echo
  # 环境确认：没有 v6 地址就别瞎调
  if ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
    warn "本机无 IPv6 全局地址（纯 v4 机器不需要本项）"
    printf '%s 仍要继续? [y/N] '
    read -r ans || ans=n
    case "$ans" in [Yy]*) ;; *) info "已取消"; return 0 ;; esac
  fi
  local slaac=0
  slaac=$(ip -6 addr show scope global 2>/dev/null | grep -c 'mngtmpaddr\|dynamic')
  # MTU：隧道环境（<1500）提示（tcp_mtu_probing 已由 apply 设 1）
  local mtu; mtu=$(ip -6 route show default 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}' | head -1)
  [ -n "$mtu" ] && [ "$mtu" -lt 1500 ] && warn "v6 默认路由 MTU=$mtu（隧道环境）：tcp_mtu_probing 已由 apply 设为 1，大包会自动探测协商"

  echo "  将要做的事（全部可回滚: ./tune.sh v6 --rollback）："
  echo "   1. use_tempaddr=0   关隐私扩展——出口 IP 稳定（代理节点/白名单场景关键）"
  echo "   2. disable_ipv6=0   确保双栈机的 v6 没被云镜像静默关掉"
  echo "   3. accept_ra=2      开着 forwarding 也接受 RA（防上游抖动掉地址）"
  echo "   4. DNS 体检          确认能解析 AAAA（纯 v6 机常见坑：DNS 只走 v4）"
  echo "   5. v4 兜底           纯 v6 机提示 NAT64/DNS64 兜底 v4-only 服务"
  echo
  printf '%s 应用? [Y/n] '
  read -r ans || ans=y
  case "${ans:-y}" in [Nn]*) info "已取消"; return 0 ;; esac

  v6_snapshot

  local tmp; tmp=$(mktemp "${V6_SYSCTL_FILE}.XXXXXX") || die "无法创建临时文件"
  cat > "$tmp" <<EOF
# 由 myvps tune v$VERSION v6 生成 $(date '+%F %T')
# 目的：IPv6 出口稳定（关临时地址轮换）+ 防 v6 被静默禁用
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.use_tempaddr = 0
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
# accept_ra=2：即使 forwarding 开着也接受 RA（KVM 网桥 + 未来开转发都稳）
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
# myvps-v6-end
EOF
  grep -qx '# myvps-v6-end' <(tail -1 "$tmp") || { rm -f "$tmp"; die "配置生成不完整"; }
  chmod 644 "$tmp" && mv -f "$tmp" "$V6_SYSCTL_FILE"

  # 逐项试写（容器里 v6 sysctl 常被拒，注释跳过）
  local bad=0 line k v
  while IFS= read -r line; do
    case "$line" in \#*|'') continue;; esac
    k=$(printf '%s' "${line%%=*}" | tr -d ' \t')
    v=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if ! sysctl -qw "$k=$v" 2>/dev/null; then
      sed -i "s%^[[:space:]]*${k}[[:space:]]*=%# 本机不支持: ${k} =%" "$V6_SYSCTL_FILE"
      warn "  不支持或被拒绝: ${k} —— 已注释"
      bad=$((bad+1))
    fi
  done < "$V6_SYSCTL_FILE"

  # DNS AAAA 解析体检（只读）
  echo
  if command -v getent >/dev/null 2>&1; then
    if getent ahosts v6.test-ipv6.com 2>/dev/null | grep -q .; then
      ok "DNS AAAA 解析正常"
    else
      warn "AAAA 解析失败：纯 v6 机请检查 /etc/resolv.conf 有没有 v6 可达的 DNS"
      echo "    可加: nameserver 2001:4860:4860::8888（Google v6 DNS）"
    fi
  fi
  # 纯 v6 机的 v4 兜底提示
  if ! ip -4 route show default 2>/dev/null | grep -q .; then
    warn "纯 IPv6 机器：部分 v4-only 服务（Docker Hub 等）会失败，NAT64 兜底："
    echo "    resolv.conf 的 DNS 换成 DNS64 服务器即可自动翻译 v4 地址:"
    echo "    nameserver 2602:fc59::10  （Public NAT64+DNS64，免费）"
  fi
  # use_tempaddr 改动要新地址生成才生效，老临时地址自然过期
  ok "v6 优化完成${bad:+（$bad 项被拒已注释）}: $V6_SYSCTL_FILE"
  [ "${slaac:-0}" -gt 0 ] 2>/dev/null && info "已有临时地址会自然过期（几分钟），新连接即用稳定地址"
  echo "  回滚: ./tune.sh v6 --rollback"
}

#── 菜单 ─────────────────────────────────────────────────────────────────────
menu(){
  echo
  echo "${C_BOLD}╔════════════════════════════════════════╗${C_0}"
  echo "${C_BOLD}║     VPS 节点网络调优  v$VERSION          ║${C_0}"
  echo "${C_BOLD}╚════════════════════════════════════════╝${C_0}"
  echo "  1) 一键调优（推荐，BDP 推导 + 确认式）"
  echo "  2) 一键调优（激进档）"
  echo "  3) IPv6 专项（纯 v6 / 双栈机：出口稳定 + DNS + NAT64 提示）"
  echo "  4) swap 兜底    小内存机推荐大小，回车即开（防 OOM 杀进程）"
  echo "  5) 查看状态"
  echo "  6) 校验参数"
  echo "  7) 回滚"
  echo "  8) 安装 BBRv3 内核（可选，需重启）"
  echo "  9) Skyline 加速（可选，高丢包普线专用，内核≥6.12）"
  echo "  0) 退出"
  echo
  printf '选择: '
  read -r sel || exit 0
  case "$sel" in
    1) cmd_apply ;;
    2) cmd_apply --aggressive ;;
    3) cmd_v6 ;;
    4) cmd_swap ;;
    5) cmd_status ;;
    6) cmd_verify ;;
    7) cmd_rollback ;;
    8) cmd_kernel ;;
    9) cmd_skyline ;;
    *) exit 0 ;;
  esac
}

case "${1:-menu}" in
  apply)    cmd_apply "${@:2}" ;;
  status)   cmd_status ;;
  verify)   cmd_verify ;;
  rollback) cmd_rollback ;;
  kernel)   cmd_kernel ;;
  skyline)  cmd_skyline ;;
  swap)     cmd_swap ;;
  v6)       case "${2:-}" in --rollback) v6_rollback ;; *) cmd_v6 ;; esac ;;
  menu|--menu|-m) menu ;;
  -h|--help|help)
    sed -n '2,32p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//' ;;
  *) die "未知子命令: $1（see --help）" ;;
esac
