#!/usr/bin/env bash
#=============================================================================
# vps.sh — 专属 VPS 工具箱 · 统一入口（支持 GitHub 一键运行）
#
# 子命令：
#   ./vps.sh            交互菜单
#   ./vps.sh auto       ★一条龙：体检 → 调优 → 安全加固 → 回程 → 到你省份三网
#   ./vps.sh all        一条龙（带确认的开荒流程）
#   ./vps.sh tune       网络调优（BBR/fq/BDP 缓冲/initcwnd，含回滚）
#   ./vps.sh secure     安全加固（一键：更新+防爆破+SSH加固，不锁门）
#   ./vps.sh kernel     可选：安装 BBRv3 内核（需重启）
#   ./vps.sh check      60 秒体检
#   ./vps.sh net        三网延迟矩阵 + 回程线路
#   ./vps.sh home [省]  到你省份的三网延迟（自动识别/手动指定，31 省全支持）
#   ./vps.sh bench      综合测评（融合怪/IP质量/解锁/单线程）
#   ./vps.sh install    装为系统命令 vps
#   ./vps.sh update     更新模块（远程模式）
#
# GitHub 一键运行（curl 管道时自动从仓库补齐其余模块到 ~/.myvps）：
#   bash <(curl -fsSL https://raw.githubusercontent.com/<用户>/<仓库>/main/vps.sh) auto
#=============================================================================
set -uo pipefail

VERSION="1.1.0"

#── 仓库地址：上传 GitHub 后改成你的（公共仓库，main 分支）──────────────────
# 也可不改文件、用环境变量临时指定：export MYVPS_REPO=https://raw.githubusercontent.com/<用户>/<仓库>/main
REPO_BASE="${MYVPS_REPO:-https://raw.githubusercontent.com/jwy87/test/main}"

MODULES="vps.sh tune.sh checkup.sh nettest.sh bench.sh secure.sh"
HOME_DIR="${MYVPS_HOME:-$HOME/.myvps}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
DIR=""

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

#── 下载（GitHub 直连 → spiritlhl CDN 镜像回退）─────────────────────────────
dl(){ # dl <url> <out>
  curl -fsSL --max-time 60 "$1" -o "$2" 2>/dev/null && [ -s "$2" ] && return 0
  curl -fsSL --max-time 60 "https://cdn.spiritlhl.net/$1" -o "$2" 2>/dev/null && [ -s "$2" ] && return 0
  return 1
}

#── 定位模块目录：同目录齐全用本地的；curl 管道运行则从仓库补齐 ─────────────
resolve_dir(){
  local m ok=1
  for m in tune.sh checkup.sh nettest.sh bench.sh secure.sh; do
    [ -f "$SCRIPT_DIR/$m" ] || { ok=0; break; }
  done
  if [ "$ok" = 1 ]; then DIR="$SCRIPT_DIR"; return 0; fi

  # 远程模式：bash <(curl ...) 或 curl | bash，脚本不在真实目录里
  mkdir -p "$HOME_DIR"
  info "远程模式：从仓库补齐模块 → $HOME_DIR"
  local fail=0
  for m in $MODULES; do
    [ -s "$HOME_DIR/$m" ] && { printf '  %s %s（已有）\n' "${C_G}✓${C_0}" "$m"; continue; }
    if dl "$REPO_BASE/$m" "$HOME_DIR/$m"; then
      printf '  %s %s\n' "${C_G}✓${C_0}" "$m"
    else
      printf '  %s %s\n' "${C_R}✗${C_0}" "$m"
      rm -f "$HOME_DIR/$m"; fail=1
    fi
  done
  [ "$fail" = 1 ] && return 1
  DIR="$HOME_DIR"
  return 0
}

run_mod(){ # run_mod <脚本> [参数...]
  local s="$1"; shift
  [ -f "$DIR/$s" ] || die "缺少 $DIR/$s"
  bash "$DIR/$s" "$@"
}

#── 一条龙（全自动）─────────────────────────────────────────────────────────
mode_auto(){
  local with_bench=0
  case "${1:-}" in --bench|bench) with_bench=1;; esac
  echo
  echo "${C_BOLD}═══ 新机一条龙：体检 → 调优 → 安全加固 → 三网(含到你省份) ═══${C_0}"
  if [ "$(id -u)" != 0 ]; then
    warn "非 root：体检/三网照常，调优与安全加固将跳过（之后可: sudo bash $DIR/vps.sh auto）"
  else
    # 带宽探测质量：无 iperf3 时静默补装（失败不影响，探测会退回默认值）
    has iperf3 || has apt-get && apt-get install -y -qq iperf3 >/dev/null 2>&1 || true
  fi
  bash "$DIR/checkup.sh"
  if [ "$(id -u)" = 0 ]; then
    bash "$DIR/tune.sh" apply
    bash "$DIR/secure.sh" auto --yes
  fi
  bash "$DIR/nettest.sh" route
  bash "$DIR/nettest.sh" home || true   # 省份识别失败不影响整体
  if [ "$with_bench" = 1 ]; then
    bash "$DIR/bench.sh" all
  else
    echo
    echo "${C_G}一条龙完成。${C_0}深度测评（4-30 分钟）随时可跑: bash $DIR/bench.sh all"
  fi
}

#── 开荒流程（带确认）───────────────────────────────────────────────────────
mode_all(){
  echo
  echo "${C_BOLD}═══ 新机开荒流程（引导式）═══${C_0}"
  echo "  第 1 步: 体检（只读，60 秒）"
  echo "  第 2 步: 调优（会改配置，全程可回滚）"
  echo
  run_mod checkup.sh
  echo
  printf '%s 继续 进入调优? [Y/n] '
  read -r ans || ans=y
  case "${ans:-y}" in
    [Nn]*) echo "已跳过调优（随时运行: ./vps.sh tune）"; exit 0;;
  esac
  run_mod tune.sh
  echo
  echo "${C_G}开荒完成。${C_0}建议: ./vps.sh net 看三网回程 → ./vps.sh bench 留底"
}

#── 装为系统命令 / 更新 ──────────────────────────────────────────────────────
mode_install(){
  [ "$(id -u)" = 0 ] || die "install 需要 root"
  ln -sf "$DIR/vps.sh" /usr/local/bin/vps
  ok "已安装系统命令: vps → $DIR/vps.sh"
  info "以后直接: vps（菜单）  vps auto（一条龙）  vps update（更新）"
}
mode_update(){
  if [ "$DIR" != "$HOME_DIR" ]; then
    info "当前运行于本地目录（$DIR）：更新请 git pull 或重新 scp"
    return 0
  fi
  info "更新模块: $REPO_BASE"
  local m fail=0
  for m in $MODULES; do
    if dl "$REPO_BASE/$m" "$HOME_DIR/$m.new"; then mv -f "$HOME_DIR/$m.new" "$HOME_DIR/$m"
    else rm -f "$HOME_DIR/$m.new"; fail=1; fi
  done
  [ "$fail" = 0 ] && ok "已更新到最新" || warn "部分文件更新失败（网络），已保留旧版"
}

#── 菜单 ─────────────────────────────────────────────────────────────────────
menu(){
  while :; do
  echo
  echo "${C_BOLD}╔════════════════════════════════════════════╗${C_0}"
  echo "${C_BOLD}║        专属 VPS 工具箱  v$VERSION             ║${C_0}"
  echo "${C_BOLD}║     调优 · 体检 · 加固 · 测评 · 三网        ║${C_0}"
  echo "${C_BOLD}╚════════════════════════════════════════════╝${C_0}"
  echo
  echo "  ${C_BOLD}常用${C_0}"
  echo "   1) 一条龙(自动)  体检 → 调优 → 加固 → 三网（新机首选）"
  echo "   2) 网络调优      BBR/fq/BDP缓冲/initcwnd（可回滚）"
  echo "   3) 安全加固      一键：更新+防爆破+SSH加固（不锁门不封端口）★"
  echo "   4) 60 秒体检     系统/IP双栈/BBR/三网延迟"
  echo
  echo "  ${C_BOLD}测评${C_0}"
  echo "   5) 综合测评      融合怪/IP质量/解锁/单线程测速"
  echo "   6) 三网测试      延迟矩阵 + 回程线路判定"
  echo "   7) 到我省份★    自动识别你的省份，测 VPS→你家三网延迟"
  echo
  echo "  ${C_BOLD}进阶${C_0}"
  echo "   8) BBRv3 内核    可选安装（需重启，先看说明）"
  echo "   9) 装为系统命令  vps"
  echo "   0) 退出"
  echo
  printf '选择: '
  read -r sel || exit 0
  case "$sel" in
    1) mode_auto ;;
    2) run_mod tune.sh ;;
    3) run_mod secure.sh ;;
    4) run_mod checkup.sh ;;
    5) run_mod bench.sh ;;
    6) run_mod nettest.sh ;;
    7) run_mod nettest.sh home ;;
    8) run_mod tune.sh kernel ;;
    9) mode_install ;;
    *) exit 0 ;;
  esac
  done
}

#── 入口 ─────────────────────────────────────────────────────────────────────
CMD="${1:-menu}"
case "$CMD" in
  -h|--help|help) sed -n '2,24p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
resolve_dir || die "模块补齐失败：检查 VPS 能否访问 GitHub；或 export MYVPS_REPO=<镜像前缀>；或直接 scp 整个 myvps 目录"
case "$CMD" in
  menu|-m|"") menu ;;
  auto)      mode_auto "${2:-}" ;;
  all)       mode_all ;;
  tune)      run_mod tune.sh "${@:2}" ;;
  secure)    run_mod secure.sh "${@:2}" ;;
  kernel)    run_mod tune.sh kernel ;;
  check)     run_mod checkup.sh "${@:2}" ;;
  net)       run_mod nettest.sh "${@:2}" ;;
  home)      run_mod nettest.sh home "${@:2}" ;;
  bench)     run_mod bench.sh "${@:2}" ;;
  install)   mode_install ;;
  update)    mode_update ;;
  *) die "未知命令: $CMD（see --help）" ;;
esac
