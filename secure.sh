#!/usr/bin/env bash
#=============================================================================
# secure.sh — VPS 安全加固（小白友好版）
#
# 设计原则：
#   1. 绝不把你锁在门外 —— 所有 SSH 修改前自动备份、语法校验、失败自动还原
#   2. 一键加固只做「零风险项」；改端口/防火墙/禁密码单独放菜单，带引导
#   3. 改端口用双端口过渡（新旧同时监听，你验证成功后才关旧端口）
#   4. 防火墙启用前先放行 SSH 和已在监听的业务端口（不弄断已有节点）
#
# 模式：
#   ./secure.sh                 菜单
#   ./secure.sh auto [--yes]    ★一键加固：更新+自动安全更新+防爆破+SSH基础加固
#   ./secure.sh check           安全体检（只读）
#   ./secure.sh key             添加 SSH 公钥（自动校验格式/指纹，防误粘私钥）
#   ./secure.sh nokey           禁用密码登录（密钥验证三重门，未验证直接拒绝）
#   ./secure.sh port            修改 SSH 端口（双端口过渡）
#   ./secure.sh ufw             防火墙 UFW（先放行 SSH/业务端口再启用）
#   ./secure.sh ufw-open <端口> 放行端口 tcp+udp（装好节点后补放行用）
#   ./secure.sh rollback        回滚本脚本对 SSH 的全部修改
#
# 参考（2026-11 核对）：tansir-1/vps-security-bootstrap v10.1.0 的 SSH 事务与
# 验证门模式、gnafehefang/VPS-QuickSetup 的双端口过渡、Lynthar/CloudServer-Audit
# 的审计项清单。pyxia.org/secure.sh 已无法访问（DNS 失效）。
#=============================================================================
set -uo pipefail

VERSION="1.0.0"
STATE_DIR="/var/lib/myvps-secure"
SSHD_CONF="/etc/ssh/sshd_config"
SSHD_DDIR="/etc/ssh/sshd_config.d"
F2B_JAIL="/etc/fail2ban/jail.d/myvps-sshd.local"
SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
MARK_B="# >>> myvps-secure begin（本块由 secure.sh 管理，勿手改）>>>"
MARK_E="# <<< myvps-secure end <<<"

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
need_root(){ [ "$(id -u)" = 0 ] || die "需要 root：sudo bash $0"; }
need_apt(){ has apt-get || die "本模块自动配置仅支持 Debian/Ubuntu（apt 系）；当前系统可先跑 check 看状态"; }

confirm_y(){ # confirm_y "提示" [默认y/n] → 用户输 y 才继续
  local def="${2:-y}" ans
  printf '%s %s' "${C_Y}[?]${C_0}" "$1 ${def:+[回车=$def]} "
  read -r ans </dev/tty 2>/dev/null || read -r ans || ans="$def"
  ans="${ans:-$def}"
  case "$ans" in [Yy]|[Yy][Ee][Ss]) return 0;; *) return 1;; esac
}

#── SSH 服务与生效配置 ───────────────────────────────────────────────────────
ssh_svc(){ # 返回 ssh 服务单元名
  if systemctl cat ssh.service >/dev/null 2>&1; then echo ssh
  elif systemctl cat sshd.service >/dev/null 2>&1; then echo sshd
  else echo ssh; fi
}
sshd_eff(){ "$SSHD_BIN" -T 2>/dev/null; } # 生效配置全量（需 root）
sshd_ports(){ # 当前生效 SSH 端口（空格分隔）
  local p
  p=$(sshd_eff | awk '/^port /{printf "%s ", $2}')
  [ -n "$p" ] || p=$(grep -E '^[[:space:]]*Port[[:space:]]' "$SSHD_CONF" 2>/dev/null | awk '{printf "%s ", $2}')
  echo "${p:-22}"
}
ufw_active(){ has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; }

#── SSH 配置写入（事务式：备份 → 写 → 校验 → 生效，失败自动还原）──────────
# 用法: managed_apply <restart|reload>，配置行先放入 BLOCK 数组（"Key Value"）
BLOCK=(); RELOAD_MODE="reload"; COMMENT_PORTS=0
backup_sshd(){
  mkdir -p "$STATE_DIR"
  cp -a "$SSHD_CONF" "$STATE_DIR/sshd_config.last" 2>/dev/null || return 1
  cp -a "$SSHD_CONF" "$STATE_DIR/sshd_config.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  ls -1t "$STATE_DIR"/sshd_config.bak.* 2>/dev/null | tail -n +6 | xargs -r rm -f -- # 只留最近5份
}
restore_sshd(){
  [ -f "$STATE_DIR/sshd_config.last" ] || return 1
  cp -a "$STATE_DIR/sshd_config.last" "$SSHD_CONF"
  "$SSHD_BIN" -t 2>/dev/null && { systemctl reload "$(ssh_svc)" 2>/dev/null || true; } \
    || systemctl restart "$(ssh_svc)" 2>/dev/null || true
}
managed_apply(){
  local tmp rest f
  [ -f "$SSHD_CONF" ] || die "找不到 $SSHD_CONF"
  backup_sshd || die "SSH 配置备份失败，中止（未做任何修改）"
  # 去掉旧管理块 + （需要时）注释其它位置的 Port 指令，避免双定义
  rest=$(sed "\|^$MARK_B$|,\|^$MARK_E$|d" "$SSHD_CONF" 2>/dev/null || cat "$SSHD_CONF")
  if [ "$COMMENT_PORTS" = 1 ]; then
    rest=$(printf '%s\n' "$rest" | sed -E 's/^([[:space:]]*Port[[:space:]])/#\1/I')
    for f in "$SSHD_DDIR"/*.conf; do
      [ -f "$f" ] || continue
      sed -i -E 's/^([[:space:]]*Port[[:space:]])/#\1/I' "$f"
    done
  fi
  tmp=$(mktemp)
  { echo "$MARK_B"; printf '%s\n' "${BLOCK[@]}"; echo "$MARK_E"; printf '%s\n' "$rest"; } > "$tmp"
  cat "$tmp" > "$SSHD_CONF" && rm -f "$tmp"
  if ! "$SSHD_BIN" -t 2>/dev/null; then
    warn "新配置语法校验失败（sshd -t），已自动还原，你的 SSH 未受影响"
    restore_sshd; return 1
  fi
  if [ "$RELOAD_MODE" = restart ]; then
    systemctl restart "$(ssh_svc)" 2>/dev/null || { restore_sshd; return 1; }
  else
    systemctl reload "$(ssh_svc)" 2>/dev/null || systemctl restart "$(ssh_svc)" 2>/dev/null || { restore_sshd; return 1; }
  fi
  return 0
}
managed_clean(){ # 仅移除管理块（还原为我们改之前由我们加的行）
  [ -f "$SSHD_CONF" ] || return 1
  local tmp; tmp=$(mktemp)
  sed "\|^$MARK_B$|,\|^$MARK_E$|d" "$SSHD_CONF" > "$tmp" && cat "$tmp" > "$SSHD_CONF" && rm -f "$tmp"
  "$SSHD_BIN" -t 2>/dev/null && systemctl reload "$(ssh_svc)" 2>/dev/null || true
}

#── 步骤 1：系统更新 ────────────────────────────────────────────────────────
step_update(){
  echo; echo "${C_BOLD}[1/4] 系统更新${C_0}"
  info "检查并安装更新（首次可能需要几分钟，请稍候）..."
  apt-get update -qq >/dev/null 2>&1 || { warn "apt update 失败（网络/源问题），跳过本步"; return 0; }
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq \
    -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' \
    upgrade >/dev/null 2>&1 && ok "系统已更新到最新" || warn "apt upgrade 有报错（可稍后手动: apt upgrade）"
}
#── 步骤 2：自动安全更新 ────────────────────────────────────────────────────
step_autoupd(){
  echo; echo "${C_BOLD}[2/4] 自动安全更新（unattended-upgrades）${C_0}"
  if [ -f /etc/apt/apt.conf.d/20auto-upgrades ] && grep -q '"1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
     && systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    ok "已配置（此前开过），跳过"; return 0
  fi
  apt-get install -y -qq unattended-upgrades >/dev/null 2>&1 || { warn "安装失败，跳过"; return 0; }
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  ok "已启用：每天自动检查并安装安全补丁（只装 security 源，不会乱升级）"
}
#── 步骤 3：fail2ban 防暴力破解 ─────────────────────────────────────────────
f2b_write(){ # f2b_write "端口列表" → 写 jail 并验证生效
  local ports="$1"
  mkdir -p /etc/fail2ban/jail.d
  cat > "$F2B_JAIL" <<EOF
# 由 myvps secure.sh 管理
[sshd]
enabled = true
backend = systemd
port = $ports
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  fail2ban-client -t >/dev/null 2>&1 # 老版本无 -t，不作为硬门槛
  systemctl restart fail2ban >/dev/null 2>&1 || { warn "fail2ban 重启失败"; return 1; }
  sleep 1
  fail2ban-client status sshd >/dev/null 2>&1 && ok "fail2ban 已生效，监控 SSH 端口: $ports（错 5 次封 1 小时）" \
    || { warn "fail2ban sshd jail 未正常运行，配置已保留"; return 1; }
}
step_f2b(){
  echo; echo "${C_BOLD}[3/4] fail2ban 防暴力破解${C_0}"
  local ports; ports=$(sshd_ports)
  if systemctl is-active --quiet fail2ban 2>/dev/null && [ -f "$F2B_JAIL" ] \
     && grep -q "port = $ports" "$F2B_JAIL" 2>/dev/null; then
    ok "已配置且运行中（监控端口: $ports），跳过"; return 0
  fi
  has fail2ban || apt-get install -y -qq fail2ban >/dev/null 2>&1 || { warn "fail2ban 安装失败，跳过"; return 0; }
  systemctl enable fail2ban >/dev/null 2>&1 || true
  f2b_write "$ports"
}
#── 步骤 4：SSH 基础加固（零锁门风险项）────────────────────────────────────
step_sshd_hard(){
  echo; echo "${C_BOLD}[4/4] SSH 基础加固${C_0}"
  local eff; eff=$(sshd_eff)
  if printf '%s\n' "$eff" | grep -q '^permitemptypasswords no$' && [ -f "$SSHD_CONF" ] \
     && grep -q '^# >>> myvps-secure' "$SSHD_CONF"; then
    ok "已加固（此前做过），跳过"; return 0
  fi
  BLOCK=(
    "PubkeyAuthentication yes"
    "PermitEmptyPasswords no"
    "MaxAuthTries 5"
    "LoginGraceTime 60"
    "ClientAliveInterval 120"
    "ClientAliveCountMax 3"
  )
  RELOAD_MODE=reload; COMMENT_PORTS=0
  if managed_apply; then
    ok "已加固：空密码禁用 / 认证尝试限 5 次 / 登录窗口 60 秒 / 连接保活"
    info "未改动：端口、root登录、密码登录（改这些请用菜单 4/5，带验证不锁门）"
  fi
  # 顺手修 /root/.ssh 权限
  if [ -d /root/.ssh ]; then chmod 700 /root/.ssh; [ -f /root/.ssh/authorized_keys ] && chmod 600 /root/.ssh/authorized_keys; fi
}

#── 重启检测（装了新内核等组件时提示，绝不自动重启）─────────────────────────
reboot_needed(){
  [ -f /var/run/reboot-required ] && return 0
  local latest
  latest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
  [ -n "$latest" ] && [ "$latest" != "$(uname -r)" ] && return 0
  return 1
}

cmd_auto(){
  local yes=0
  [ "${1:-}" = "--yes" ] && yes=1
  echo
  echo "${C_BOLD}═══ 一键安全加固（零锁门风险，不封任何端口，不重启）═══${C_0}"
  echo "  内容：系统更新 → 自动安全更新 → fail2ban防爆破 → SSH基础加固"
  echo "  ${C_D}不会做（需你手动选）：禁密码登录 / 改端口 / 防火墙${C_0}"
  if [ "$yes" != 1 ]; then
    confirm_y "开始？" || { echo "已取消"; return 0; }
  fi
  need_root; need_apt
  step_update
  step_autoupd
  step_f2b
  step_sshd_hard
  echo
  echo "${C_G}═══ 加固完成（全程未重启，当前连接未受影响）═══${C_0}"
  if reboot_needed; then
    warn "本次更新装了需要重启才生效的组件（如新内核）——${C_BOLD}不急，不影响现在使用${C_0}"
    echo "   挑个方便的时间手动 reboot 即可；重启后调优里只有 initcwnd 一项会丢，"
    echo "   跑一次 菜单 2)网络调优 就补上（脚本会自动识别只补这一项，其余全部持久）"
  fi
  echo "  建议下一步（都在菜单里）："
  echo "   3) 添加 SSH 密钥 —— 最推荐，之后才能安全地禁用密码登录"
  echo "   6) 防火墙 —— 装好节点后再开，脚本会提醒放行端口"
}

#── 安全体检（只读）─────────────────────────────────────────────────────────
cmd_check(){
  echo; echo "${C_BOLD}═══ 安全体检（只读，不改任何配置）═══${C_0}"
  if [ "$(id -u)" != 0 ]; then warn "非 root，部分项目看不到完整信息（建议 sudo 重跑）"; fi
  echo
  echo "${C_BOLD}── SSH 登录面 ──${C_0}"
  local eff; eff=$(sshd_eff 2>/dev/null)
  if [ -n "$eff" ]; then
    printf '  %-26s %s\n' "端口" "$(sshd_ports | tr '\n' ' ')"
    printf '  %-26s %s\n' "密码登录" "$(printf '%s' "$eff" | awk '/^passwordauthentication/{print $2}')"
    printf '  %-26s %s\n' "root 登录" "$(printf '%s' "$eff" | awk '/^permitrootlogin/{print $2}')"
    printf '  %-26s %s\n' "密钥登录" "$(printf '%s' "$eff" | awk '/^pubkeyauthentication/{print $2}')"
    if [ "$(printf '%s' "$eff" | awk '/^passwordauthentication/{print $2}')" = yes ]; then
      warn "密码登录开着：建议菜单 3 配好密钥 → 菜单 4 关闭密码登录"
    else
      ok "密码登录已关闭"
    fi
  else
    warn "无法读取 sshd 生效配置（需 root）"
  fi
  if [ -s /root/.ssh/authorized_keys ]; then
    local n; n=$(grep -c '^ssh-\|^ecdsa-\|^sk-' /root/.ssh/authorized_keys 2>/dev/null)
    printf '  %-26s %s\n' "root 公钥" "${n:-0} 把"
  else
    printf '  %-26s %s\n' "root 公钥" "${C_Y}无（配密钥前别关密码登录）${C_0}"
  fi
  echo
  echo "${C_BOLD}── 防护组件 ──${C_0}"
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    local banned; banned=$(fail2ban-client status sshd 2>/dev/null | grep -oE 'Currently banned:[[:space:]]*[0-9]+' | grep -oE '[0-9]+')
    printf '  %-26s %s\n' "fail2ban" "${C_G}运行中${C_0}（当前封禁 ${banned:-0} 个 IP）"
  else
    printf '  %-26s %s\n' "fail2ban" "${C_Y}未运行（一键加固可装）${C_0}"
  fi
  local au; au=$(grep -c 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
  printf '  %-26s %s\n' "自动安全更新" "$([ "${au:-0}" -ge 1 ] 2>/dev/null && echo "${C_G}已开启${C_0}" || echo "${C_Y}未开启${C_0}")"
  printf '  %-26s %s\n' "防火墙 UFW" "$(ufw_active && echo "${C_G}启用${C_0}" || echo "未启用（有云安全组也可）")"
  echo
  echo "${C_BOLD}── 对外开放端口（0.0.0.0/:: 监听）──${C_0}"
  local listeners; listeners=$(ss -H -lntup 2>/dev/null | awk '$5 !~ /^127\.|^::1:|\[::1\]/')
  if [ -n "$listeners" ]; then
    printf '%s\n' "$listeners" | awk '{printf "  %-8s %-24s %s\n", $1, $5, $6}' | head -20
  else
    echo "  （无 或 需要 root 查看）"
  fi
  echo
  echo "${C_BOLD}── 近期登录 ──${C_0}"
  last -n 5 -a 2>/dev/null | head -6 || echo "  （无 last 命令）"
  local fails
  fails=$( { journalctl -u ssh -u sshd --since -24h --no-pager 2>/dev/null; cat /var/log/auth.log 2>/dev/null; } \
           | grep -ci 'failed password\|invalid user' )
  [ -n "$fails" ] && printf '  %-26s %s 次\n' "24小时失败登录尝试" "$fails"
  echo
  echo "  体检完成。加固/配置见: bash $0（菜单）"
}

#── 添加公钥 ────────────────────────────────────────────────────────────────
cmd_key(){
  need_root
  echo
  echo "${C_BOLD}═══ 添加 SSH 公钥（免密登录）═══${C_0}"
  echo "  没有密钥？在你的 ${C_BOLD}电脑${C_0}（不是 VPS）上生成："
  echo "   Windows: 打开 PowerShell 输入  ssh-keygen -t ed25519  一路回车"
  echo "   公钥文件: C:\\Users\\你的用户名\\.ssh\\id_ed25519.pub（记事本打开，复制整行）"
  echo "   Mac/Linux: ssh-keygen -t ed25519 → cat ~/.ssh/id_ed25519.pub"
  echo
  local pub tmp fp
  while :; do
    printf '%s 粘贴公钥整行（ssh-ed25519 开头）: ' "${C_B}[?]${C_0}"
    read -r pub || die "输入中断"
    pub="${pub%$'\r'}"
    [ -n "$pub" ] || { warn "没收到内容，重新粘贴"; continue; }
    case "$pub" in
      *PRIVATE\ KEY*) warn "这是 ${C_R}私钥${C_0}！私钥绝不能上传服务器，请粘贴 .pub 结尾的公钥文件内容"; continue;;
      ssh-*|ecdsa-*|sk-*) : ;;
      *) warn "公钥应以 ssh-ed25519 / ssh-rsa / ecdsa- 开头，请检查是否复制完整"; continue;;
    esac
    tmp=$(mktemp); printf '%s\n' "$pub" > "$tmp"
    if fp=$(ssh-keygen -lf "$tmp" 2>/dev/null); then rm -f "$tmp"; break; fi
    rm -f "$tmp"; warn "公钥校验不通过（可能没复制完整），重新粘贴"
  done
  # 写入 root（小白通常 root 登录）；若有真实调用用户也一并写入
  local targets="$HOME"
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && targets="$HOME /home/$SUDO_USER"
  for h in $targets; do
    mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
    if [ "$h" != "$HOME" ]; then chown "$SUDO_USER" "$h/.ssh" 2>/dev/null || true; fi
    touch "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
    if grep -Fxq "$pub" "$h/.ssh/authorized_keys"; then
      info "$h：该公钥已存在，跳过"
    else
      printf '%s\n' "$pub" >> "$h/.ssh/authorized_keys"
      ok "$h：已添加"
    fi
    [ "$h" != "$HOME" ] && chown "$SUDO_USER:$SUDO_USER" "$h/.ssh/authorized_keys" 2>/dev/null || true
  done
  ok "公钥指纹: $fp"
  echo
  warn "现在 ${C_BOLD}新开一个窗口${C_0}测试（别关当前窗口）:  ssh root@服务器IP"
  echo "  能登录成功 → 回来运行菜单 4 关闭密码登录，安全性拉满"
  echo "  登录失败   → 公钥没配对，当前窗口还开着，随时能改"
}

#── 禁用密码登录（三重验证门）───────────────────────────────────────────────
cmd_nokey(){
  need_root
  echo
  echo "${C_BOLD}═══ 禁用密码登录（让爆破彻底无效）═══${C_0}"
  # 门 1：必须已有公钥
  if [ ! -s /root/.ssh/authorized_keys ]; then
    die "root 还没有可用公钥，拒绝关闭密码登录（否则你会被锁在门外）。先运行: bash $0 key"
  fi
  local eff; eff=$(sshd_eff)
  if [ "$(printf '%s' "$eff" | awk '/^passwordauthentication/{print $2}')" = no ]; then
    ok "密码登录已经是关闭状态，无需重复操作"; return 0
  fi
  echo "  检测到 root 有 $(grep -c '^ssh-\|^ecdsa-\|^sk-' /root/.ssh/authorized_keys) 把公钥"
  # 门 2：人工确认已实际测过密钥登录
  warn "关闭后 ${C_R}只能用密钥登录${C_0}，密码再也登不上（当前已连接的窗口不受影响）"
  confirm_y "你已经在【另一个窗口】用密钥成功登录过这台服务器了吗？" n \
    || { echo "已取消。先去测试: 新窗口执行 ssh -i 你的私钥 root@服务器IP"; return 0; }
  # 门 3：写入 + 生效校验，失败自动还原
  BLOCK=(
    "PasswordAuthentication no"
    "KbdInteractiveAuthentication no"
    "ChallengeResponseAuthentication no"
    "PermitEmptyPasswords no"
    "PermitRootLogin prohibit-password"
  )
  RELOAD_MODE=reload; COMMENT_PORTS=0
  if ! managed_apply; then die "配置未生效，已自动还原到改前状态"; fi
  eff=$(sshd_eff)
  if [ "$(printf '%s' "$eff" | awk '/^passwordauthentication/{print $2}')" != no ]; then
    restore_sshd; die "生效校验失败，已自动还原（未关闭密码登录）"
  fi
  ok "密码登录已关闭：PasswordAuthentication no + PermitRootLogin prohibit-password"
  echo
  warn "当前窗口 ${C_BOLD}先别关${C_0}，再开一个新窗口用密钥登录验证一次，确认无碍"
  echo "  如果新窗口登不上 → 运行 bash $0 rollback 一键还原"
}

#── 修改 SSH 端口（双端口过渡）──────────────────────────────────────────────
suggest_port(){ # 随机推荐一个未占用端口
  local used p; used=$(ss -tanH 2>/dev/null | awk '{p=$4; sub(/^.*:/,"",p); if(p~/^[0-9]+$/) print p}' | sort -u | tr '\n' ' ')
  for p in $(shuf -i 20000-65000 2>/dev/null || seq 22222 23322); do
    case " $used $(sshd_ports | tr '\n' ' ') " in *" $p "*) continue;; esac
    echo "$p"; return
  done
}
cmd_port(){
  need_root
  echo
  echo "${C_BOLD}═══ 修改 SSH 端口 ═══${C_0}"
  echo "  1) 添加新端口    新旧端口同时监听，验证成功后再关旧的（安全，推荐）"
  echo "  2) 关闭旧端口    前提：你已用新端口登录成功"
  echo "  3) 恢复默认 22"
  echo "  0) 返回"
  printf '选择: '
  local sel; read -r sel || return 0
  case "$sel" in
    1) port_add ;;
    2) port_remove_old ;;
    3) port_reset ;;
    *) return 0 ;;
  esac
}
port_add(){
  local cur new
  cur=$(sshd_ports)
  echo "  当前 SSH 端口: ${C_BOLD}$cur${C_0}"
  local sug; sug=$(suggest_port)
  printf '%s 新端口 [回车用推荐值 %s]: ' "${C_B}[?]${C_0}" "${sug:-手动输入}"
  read -r new || return 0
  new="${new:-$sug}"
  case "$new" in ''|*[!0-9]*) die "端口必须是数字";; esac
  [ "$new" -ge 1 ] && [ "$new" -le 65535 ] || die "端口范围 1-65535"
  ss -tlnH 2>/dev/null | grep -q ":$new " && die "端口 $new 已被其他程序占用"
  case " $cur " in *" $new "*) die "$new 已是当前 SSH 端口";; esac
  # 防火墙先放行新端口（若 UFW 启用）
  if ufw_active; then
    ufw allow "$new/tcp" >/dev/null 2>&1 && info "UFW 已放行 $new/tcp"
  fi
  # Ubuntu 24.10+ 的 ssh.socket 模式下改端口不生效，切换为常驻服务
  if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    info "检测到 ssh.socket 模式，切换为 ssh.service（否则新端口不生效）..."
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable --now "$(ssh_svc)" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  BLOCK=(); for p in $cur; do BLOCK+=("Port $p"); done; BLOCK+=("Port $new")
  RELOAD_MODE=restart; COMMENT_PORTS=1
  managed_apply || die "修改失败，已还原"
  sleep 1
  if ss -tlnH 2>/dev/null | grep -q ":$new "; then
    ok "SSH 已同时监听: $cur $new（旧端口暂时保留）"
  else
    warn "端口 $new 未检测到监听，请人工核实: ss -tlnp | grep ssh"
  fi
  f2b_write "$(sshd_ports)" >/dev/null 2>&1 || true
  echo
  warn "${C_BOLD}新开窗口${C_0}测试登录:  ssh -p $new root@服务器IP"
  echo "  成功 → 回来菜单 5 选「关闭旧端口」"
  warn "失败也不怕：旧端口还开着，跑 bash $0 rollback 即可全部还原"
  info "如果云厂商控制台有安全组，记得也放行 $new/tcp"
}
port_remove_old(){
  local ports keep p olds=""
  ports=$(sshd_ports)
  echo "  当前监听端口: $ports"
  printf '%s 保留哪个端口（填新端口）: ' "${C_B}[?]${C_0}"
  read -r keep || return 0
  case " $ports " in *" $keep "*) : ;; *) die "$keep 不在当前 SSH 端口列表里";; esac
  confirm_y "确认你已用端口 $keep 成功登录过？关掉旧端口后它将是唯一入口" n || return 0
  for p in $ports; do [ "$p" != "$keep" ] && olds="$olds $p"; done
  BLOCK=("Port $keep")
  RELOAD_MODE=restart; COMMENT_PORTS=1
  managed_apply || die "修改失败，已还原"
  if ufw_active; then
    for p in $olds; do ufw delete allow "$p/tcp" >/dev/null 2>&1 || true; ufw delete allow "$p" >/dev/null 2>&1 || true; done
  fi
  f2b_write "$keep" >/dev/null 2>&1 || true
  ok "旧端口已关闭:$olds —— 现在 SSH 只监听 $keep"
  warn "云厂商安全组里也可以把旧端口规则删掉了"
}
port_reset(){
  confirm_y "恢复 SSH 端口为默认 22？" n || return 0
  if ufw_active; then ufw allow 22/tcp >/dev/null 2>&1 || true; fi
  BLOCK=("Port 22")
  RELOAD_MODE=restart; COMMENT_PORTS=1
  managed_apply || die "修改失败，已还原"
  f2b_write 22 >/dev/null 2>&1 || true
  ok "已恢复 22（云安全组记得同步）"
}

#── UFW 防火墙 ──────────────────────────────────────────────────────────────
cmd_ufw(){
  need_root
  echo
  echo "${C_BOLD}═══ 防火墙（UFW）═══${C_0}"
  if ufw_active; then
    ufw status | sed 's/^/  /'
    echo
    echo "  1) 放行端口    2) 删除规则    3) 关闭防火墙    0) 返回"
    printf '选择: '
    local sel p; read -r sel || return 0
    case "$sel" in
      1) printf '端口（如 443 或 tcp:443）: '; read -r p; ufw_allow_one "$p" ;;
      2) printf '端口: '; read -r p; ufw delete allow "$p" >/dev/null 2>&1; ufw delete allow "$p/tcp" >/dev/null 2>&1; ufw delete allow "$p/udp" >/dev/null 2>&1; ok "已删除 $p 的规则" ;;
      3) confirm_y "关闭防火墙？（端口不再过滤）" n && { ufw --force disable; ok "已关闭"; } ;;
      *) return 0 ;;
    esac
    return 0
  fi
  # 未启用 → 引导启用
  echo "  启用后规则：${C_BOLD}默认拒绝所有进入，放行 SSH 和你指定的端口${C_0}"
  echo "  已在监听的服务端口会自动列出供你确认，不会弄断现有节点"
  confirm_y "现在配置并启用防火墙？" || return 0
  has ufw || apt-get install -y -qq ufw >/dev/null 2>&1 || die "ufw 安装失败"
  local ports; ports=$(sshd_ports)
  for p in $ports; do ufw allow "$p/tcp" >/dev/null 2>&1; done
  info "已放行 SSH 端口: $ports"
  # 列出正在监听的业务端口，默认放行（不弄断现有服务）
  local biz
  biz=$(ss -H -lntup 2>/dev/null | awk '$5 !~ /^127\.|^::1:|\[::1\]/ {split($5,a,":"); print a[length(a)]}' | sort -un | tr '\n' ' ')
  for p in $biz; do
    case " $ports " in *" $p "*) continue;; esac
    ufw allow "$p" >/dev/null 2>&1 && info "自动放行在监听端口: $p（保住现有服务/节点）"
  done
  local extra
  printf '%s 还要放行哪些端口（以后装节点用，如 443 8443；回车跳过）: ' "${C_B}[?]${C_0}"
  read -r extra || extra=""
  for p in $extra; do ufw_allow_one "$p"; done
  ufw default deny incoming  >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1 || die "ufw 启用失败"
  ok "防火墙已启用（默认拒绝进入 / 放行 SSH:$ports${biz:+ / 在监听端口:$biz}${extra:+ / 手动:$extra}）"
  echo
  warn "两件事别忘："
  echo "   1. 以后装好节点要放行端口:  bash $0 ufw-open 443   （tcp+udp 都放）"
  echo "   2. ${C_BOLD}云厂商控制台的安全组${C_0}是另一层，也只放行需要的端口"
}
ufw_allow_one(){ # "443"=tcp+udp 都放 | "tcp:443"/"udp:443" 指定协议
  local spec="$1" proto port
  case "$spec" in
    tcp:*|udp:*) proto="${spec%%:*}"; port="${spec##*:}" ;;
    *) proto=""; port="$spec" ;;
  esac
  case "$port" in ''|*[!0-9]*) warn "忽略无效端口: $spec"; return;; esac
  if [ -n "$proto" ]; then
    ufw allow "$port/$proto" >/dev/null 2>&1 && ok "已放行 $port/$proto"
  else
    ufw allow "$port/tcp" >/dev/null 2>&1; ufw allow "$port/udp" >/dev/null 2>&1
    ok "已放行 $port（tcp+udp）"
  fi
}
cmd_ufw_open(){
  [ -n "${1:-}" ] || die "用法: bash $0 ufw-open <端口>（如 443；或 tcp:443）"
  need_root
  ufw_active || die "防火墙未启用，先运行: bash $0 ufw"
  ufw_allow_one "$1"
}

#── 回滚 ────────────────────────────────────────────────────────────────────
cmd_rollback(){
  need_root
  echo
  echo "${C_BOLD}═══ 回滚 SSH 配置 ═══${C_0}"
  if [ ! -f "$STATE_DIR/sshd_config.last" ]; then
    # 没有备份 → 尝试仅移除管理块
    if grep -q '^# >>> myvps-secure' "$SSHD_CONF" 2>/dev/null; then
      confirm_y "无备份文件，仅移除本脚本加的配置块？" n || return 0
      managed_clean && ok "已移除（端口指令若被注释请手动检查 $SSHD_CONF）"
    else
      info "没有可回滚的内容（没改过或已回滚）"
    fi
    return 0
  fi
  echo "  将还原到最近一次修改前（$(stat -c '%y' "$STATE_DIR/sshd_config.last" 2>/dev/null | cut -d. -f1)）"
  confirm_y "确认还原？" || return 0
  restore_sshd && ok "SSH 配置已还原（端口/登录方式回到之前）" || warn "还原后校验异常，请立即人工检查: $SSHD_CONF"
  warn "当前已连接的会话不受影响；新窗口验证一下再关当前窗口"
}

#── 菜单 ────────────────────────────────────────────────────────────────────
menu(){
  while :; do
  echo
  echo "${C_BOLD}── VPS 安全加固 v$VERSION ──${C_0}"
  echo "  1) 一键加固 ${C_BOLD}★推荐${C_0}   更新+自动安全补丁+fail2ban防爆破+SSH基础加固（零风险）"
  echo "  2) 安全体检           只读：SSH/防护组件/开放端口/近期登录"
  echo "  3) 添加 SSH 密钥      免密登录，防爆破根本手段（含生成指引）"
  echo "  4) 禁用密码登录       需先配好密钥；三重验证门，失败自动还原"
  echo "  5) 修改 SSH 端口      双端口过渡：新旧同开，验证后才关旧的"
  echo "  6) 防火墙 UFW         先放行 SSH/在监听端口，不弄断节点"
  echo "  7) 回滚 SSH 修改"
  echo "  0) 返回/退出"
  echo
  printf '选择: '
  read -r sel || exit 0
  case "$sel" in
    1) cmd_auto ;;
    2) cmd_check ;;
    3) cmd_key ;;
    4) cmd_nokey ;;
    5) cmd_port ;;
    6) cmd_ufw ;;
    7) cmd_rollback ;;
    *) exit 0 ;;
  esac
  done
}

#── 入口 ────────────────────────────────────────────────────────────────────
case "${1:-menu}" in
  menu|-m|"") menu ;;
  auto)       shift; cmd_auto "$@" ;;
  check)      cmd_check ;;
  key)        cmd_key ;;
  nokey)      cmd_nokey ;;
  port)       cmd_port ;;
  ufw)        cmd_ufw ;;
  ufw-open)   shift; cmd_ufw_open "${1:-}" ;;
  rollback)   cmd_rollback ;;
  -h|--help)  sed -n '2,22p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
  *) die "未知参数: $1（see --help）" ;;
esac
