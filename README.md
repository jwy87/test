# 专属 VPS 工具箱（搭节点向）

> 调优 · 体检 · 安全加固 · 测评 · 三网 —— 为「稳定 / 高速 / 低延迟」搭节点场景整合
> 所有上游项目与事实结论均于 **2026-10-31** 逐一验证（安全模块 2026-11-01）

---

## 🚀 一键运行（上传 GitHub 后）

**第 1 步：上传**（任选其一）

- GitHub 网页：新建**公共**仓库（如 `myvps`）→ 上传这 6 个 `.sh` 文件（README.md 可选）→ 默认分支用 `main`
- 或命令行：
  ```bash
  cd D:/4/SSH/myvps
  git init -b main && git add . && git commit -m "my vps toolbox"
  git remote add origin https://github.com/<你的用户名>/myvps.git
  git push -u origin main
  ```

**第 2 步：改仓库地址**（上传后必做，一次性）

用编辑器打开 `vps.sh`，找到这一行（约第 27 行）：

```bash
REPO_BASE="${MYVPS_REPO:-https://raw.githubusercontent.com/你的用户名/你的仓库名/main}"
```

把 `你的用户名/你的仓库名` 换成实际值（如 `zhangsan/myvps`），重新 push。**不改的话远程补齐会失败。**

**第 3 步：新 VPS 上一条指令搞定**

```bash
# 一条龙：体检 → 调优 → 三网（全自动，新机首选）
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/myvps/main/vps.sh) auto

# 或菜单交互
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/myvps/main/vps.sh)
```

首次运行会自动把其余模块下载到 `~/.myvps`（GitHub 直连失败自动走 spiritlhl CDN 镜像），之后：

```bash
bash ~/.myvps/vps.sh check     # 秒级体检
bash ~/.myvps/vps.sh auto      # 一条龙
bash ~/.myvps/vps.sh update    # 更新到仓库最新版
bash ~/.myvps/vps.sh install   # 装为系统命令，以后直接敲: vps
```

> GitHub 访问不稳的环境，用镜像前缀：`export MYVPS_REPO=https://cdn.spiritlhl.net/https://raw.githubusercontent.com/<用户名>/<仓库>/main` 再运行。
> 也可完全绕过 GitHub：`scp -r D:/4/SSH/myvps root@VPS:/root/` 后 `bash /root/myvps/vps.sh auto`。

---

## 文件清单

| 文件 | 功能 | 改系统？ | 耗时 |
|---|---|---|---|
| `vps.sh` | 统一入口菜单（也可直接跑下面五个） | - | - |
| `tune.sh` | 网络调优：BBR/fq/BDP 缓冲/initcwnd + 可选 Skyline/BBRv3 内核 | ✅（可回滚） | 1-2 分钟 |
| `secure.sh` | 安全加固：更新/防爆破/SSH 加固，事务式改配置 | ✅（可回滚） | 2-5 分钟 |
| `checkup.sh` | 60 秒体检：系统/IP双栈/BBR/三网延迟/健康 | ❌ 只读 | 30-60 秒 |
| `nettest.sh` | 三网延迟矩阵（京沪穗蓉 v4+v6）+ 回程线路判定 | ❌（装 backtrace 到 /usr/local/bin） | 1-2 分钟 |
| `bench.sh` | 综合测评：融合怪/IP质量/解锁/单线程双栈测速 | ❌（装 goecs） | 按模块 20秒-30分钟 |

## 快速开始（不上传 GitHub 的用法）

```bash
# 整个目录传上去（Windows 本机执行）
scp -r D:/4/SSH/myvps root@你的VPS:/root/

# VPS 上运行
cd /root/myvps
bash vps.sh            # 菜单
bash vps.sh auto       # 一条龙：体检→调优→三网（新机首选）
```

> checkup / nettest / bench / tune / secure 五个模块脚本**相互独立**，单独 scp 上去也能直接跑。

---

## 各模块说明

### 1. tune.sh — 网络调优（核心）

```bash
bash tune.sh                    # 菜单
bash tune.sh apply              # 应用调优（默认保守档）
bash tune.sh apply --aggressive # 激进档（缓冲×2，大内存有感）
bash tune.sh apply --bw 500 --rtt 50   # 手动指定带宽/RTT，跳过探测
bash tune.sh status             # 看当前状态
bash tune.sh verify             # 校验参数是否生效
bash tune.sh rollback           # 一键回滚到调优前
bash tune.sh kernel             # 可选：装 BBRv3 内核（见下文）
bash tune.sh skyline            # 可选：Skyline 加速（见下文）
```

**它做了什么**（全部写入 `/etc/sysctl.d/99-myvps-tune.conf`，逐项试写、不支持自动注释）：

| 类别 | 参数 | 依据 |
|---|---|---|
| 拥塞控制 | `bbr` + `fq`（无 bbr 则 cubic+fq_codel 并提示） | 内核 4.13+ BBR 自带 pacing，fq 是代理服务器最佳搭配（Neal Cardwell/bbr-dev） |
| 缓冲区 | rmem/wmem_max = **2×BDP+2MB**，内存 1/32 封顶，绝对上限 256MB，下限 4MB（≥1GB 内存抬到 16MB） | tcpfit v0.5.9 实测调优公式；16MB 为 Hysteria2 官方 UDP/QUIC 要求 |
| tcp_mem | 内存 1/16、1/8、1/4（低/压力/最大） | tcpfit 公式，防小内存机 OOM |
| 低延迟 | slow_start_after_idle=0、mtu_probing=1、fastopen=3、initcwnd/initrwnd=20 | 代理长连接 + 首屏关键项 |
| 并发承载 | somaxconn=8192、syn_backlog=8192、netdev_max_backlog=16384、port_range=1024-65535 | 社区共识（tcpx/kejilion/Eric 脚本一致） |
| conntrack | max=262144、超时收紧（模块已加载才写） | 高并发防表满掉线 |

**刻意不设**（有实测反例）：
- `tcp_notsent_lowat` —— 一派说降延迟、实测派说拖慢长距起步（Eric86777 v5.4.20 因此改回默认）
- `tcp_reordering=300` —— 现代内核走 RACK，调高只推迟快速重传

**带宽/RTT 探测**：RTT 实测你 SSH 来源 IP；带宽用最近公共 iperf3 服务器单流 5 秒粗测。探测不到就按 500Mbps/180ms 假设并明确提示，可用 `--bw --rtt` 覆盖。**BDP 推导的价值**：500M×50ms 香港机只需 8MB 缓冲，1G×180ms 美西机要 44MB（被 1GB 内存封到 32MB）——抄固定值两头都错。

### 2. checkup.sh — 60 秒体检

只读，不装东西不联网上传。输出：系统画像 → IP 双栈出口 → 拥塞控制/BBR 版本 → 大陆三网延迟（京沪穗 ×电信/联通/移动，ICMP）→ 健康检查（内存/磁盘/conntrack/时钟）。

```bash
bash checkup.sh            # 全部
bash checkup.sh --no-ping  # 跳过大陆延迟（离线场景）
```

### 3. nettest.sh — 三网延迟 + 回程 + 到你省份

```bash
bash nettest.sh              # 菜单
bash nettest.sh home         # ★到你省份的三网延迟（自动识别 SSH 来源省份）
bash nettest.sh home 江苏     # 手动指定省份（简称即可：四川/内蒙古/黑龙江…31 省全支持）
bash nettest.sh ping         # 延迟矩阵：京沪穗蓉基准（多台 VPS 横向对比用）
bash nettest.sh route        # 回程线路判定（backtrace：CN2 GIA/GT/CTGNET/163/9929/4837/CMIN2/CMI）
bash nettest.sh trace        # nexttrace 详细逐跳（含 TCP 80 模式）
```

**`home` 模式（个性化，推荐）**：自动识别你 SSH 来源 IP 的省份（ip-api.com），测 VPS → 你省份电信/联通/移动（v4+v6）的真实延迟。节点库来自 spiritLHLS/icmp_targets（社区维护的 31 省实测优选目标，每省三网×双栈）。跳板机场景识别会偏，手动 `home 省份` 指定即可。

**`ping` 模式（通用基准）**：京沪穗蓉 12 目标 + 京沪穗 v6 9 目标（融合怪/backtrace 同款表）。用途是多台 VPS 横向对比——行业惯例用固定城市基准，任何地区的 VPS 都能公平比较。

**回程线路决定协议选择**：GIA/9929/CMIN2 优质线路跑 TCP 类（VLESS）很稳；163/4837 普线高峰丢包大，用 Hysteria2/TUIC（UDP+激进重传）体验更好。

### 4. bench.sh — 综合测评

```bash
bash bench.sh          # 菜单
bash bench.sh all      # 日常组合：IP质量 + 单线程双栈（约4分钟）★推荐
bash bench.sh full     # 融合怪完全体（7-30分钟）
bash bench.sh net      # 仅网络 / ip 仅IP质量 / media 解锁 / hw 硬件 / single 测速
```

| 模块 | 上游 | 状态 |
|---|---|---|
| 融合怪 | oneclickvirt/ecs（**Go 版 goecs**，官方主力，零依赖） | 活跃 2026-10 |
| IP 质量 | xykt/IPQuality（风险评分/原生性/NAT/400+黑名单库） | 活跃 2026-09 |
| 回程 | oneclickvirt/backtrace（融合怪同款） | 活跃 2026-10 |
| 单线程测速 | iperf3 `-P 1` 收/发 ×双栈（Leaseweb/Clouvider 公共服务器，自动选最近+端口轮换） | - |

**隐私设计**：goecs 加 `-upload=false`、IPQuality 加 `-p`（不生成在线报告链接）。对比：NodeQuality（run.NodeQuality.com）会把结果 zip 上传到 api.nodequality.com，介意就别直接跑它本体——本工具箱只调用其内部同款模块且默认隐私模式。

**为什么单线程测速不用 Ookla？** 官方 CLI 没有 `--single-thread` 参数（1.2.0 二进制+手册双重核实）；sivel/speedtest-cli 已归档（2024-07）；HyperSpeed 已死（git.io 关停+仓库删除）。iperf3 单流收发是 NodeQuality 内部 Net.Check.Place 的实际做法，也是社区"单线程压测"的当前标准实现。

### 5. secure.sh — 安全加固（小白友好）

```bash
bash secure.sh              # 菜单
bash secure.sh auto         # ★一键加固（零锁门风险，不封任何端口）
bash secure.sh check        # 安全体检（只读）
bash secure.sh key          # 添加 SSH 公钥（防误粘私钥，自动校验指纹）
bash secure.sh nokey        # 禁用密码登录（三重验证门）
bash secure.sh port         # 修改 SSH 端口（双端口过渡）
bash secure.sh ufw          # 防火墙（先放行 SSH 和在监听端口）
bash secure.sh ufw-open 443 # 装好节点后放行端口（tcp+udp）
bash secure.sh rollback     # 回滚对 SSH 的全部修改
```

**一键加固做了什么**（幂等，重复运行显示"已配置"并跳过）：

| 步骤 | 内容 | 说明 |
|---|---|---|
| 系统更新 | `apt update + upgrade` | 首次可能几分钟 |
| 自动安全补丁 | unattended-upgrades | 每天只装 security 源补丁 |
| 防暴力破解 | fail2ban（错 5 次封 1 小时） | 监听实际 SSH 端口，改端口自动同步 |
| SSH 基础加固 | 禁空密码/限认证 5 次/登录窗口 60s/连接保活 | **不碰**端口/root登录/密码登录 |

**安全设计**（抄自 tansir v10.1.0 的验证模式，2026-11 核对）：

- **绝不锁门**：所有 SSH 修改走「备份 → 写入 → `sshd -t` 语法校验 → reload → 生效校验」，任何一步失败自动还原；备份存 `/var/lib/myvps-secure/`
- **禁密码三重门**：① root 必须已有公钥 ② 必须人工确认"已在新窗口用密钥登录成功" ③ 生效后校验实际配置，不符自动回滚
- **改端口双端口过渡**：新旧端口同时监听 → 你新开窗口验证 → 再回来关旧端口（同时处理 Ubuntu 24.10+ 的 ssh.socket 模式，否则改端口不生效）；改前若 UFW 启用先放行新端口
- **防火墙不弄断节点**：启用前自动放行 SSH 端口 + 所有正在监听的服务端口；装好新节点后 `secure.sh ufw-open 端口` 补放行
- **云安全组提醒**：阿里云/腾讯云等控制台的安全组是另一层，脚本会提示同步

**推荐顺序**：一键加固 → 配密钥（菜单 3）→ 新窗口验证密钥 → 禁密码（菜单 4）→ 装节点 → 防火墙（菜单 6）。

---

## 关于 BBRv3 的实话（重要）

论坛宣传的「零重启 BBRv3 (3.2-Pro)」经一手核实：

1. **"3.2-Pro" 不存在** —— Google 官方只有 v3（`github.com/google/bbr` v3 分支）；"3.2"疑为把 XanMod 包名 `linux-xanmod-x64v3`（x86-64 CPU 指令集等级 v3）误读成 BBR 版本
2. **"零重启"是营销话术** —— 主线内核至今（2026-10）只有 BBRv1；BBRv3 必须换内核，换内核**必须重启**。"零重启"仅指 sysctl 参数热生效部分
3. **v3 对节点的提升有限** —— v3 主要修多瓶颈带宽估计与 RTT 不公平竞争。对单节点场景，sysctl 调优（缓冲区/slow_start_after_idle/initcwnd）的收益通常大于换内核，且零风险

`tune.sh kernel` 提供可选安装（明确提示需重启）：

| 方案 | 适用 | 说明 |
|---|---|---|
| XanMod LTS | Debian 12/13、Ubuntu 24.04、x86_64 | apt 仓库最稳；**实测 22.04/20.04 已 404 不支持** |
| byJoey/Actions-bbr-v3 | Debian 12+、Ubuntu 24.04+、x86_64/arm64 | 跟随 kernel.org stable |
| ~~ELRepo kernel-ml~~ | CentOS/Alma/Rocky | ❌ 是纯主线内核，仍 BBRv1，别被误导 |
| ~~任何方案~~ | OpenVZ/LXC、Alpine | ❌ 共享内核/无包，无法换 |

装完重启后用 `cat /sys/module/tcp_bbr/version` 验证（v3 树会输出 `3`，主线 v1 无输出）。

## Skyline Speeder：高丢包普线的可选加速（2026-11 核实）

**它是什么**：eBPF 拥塞控制（内核 ≥ 6.12），接管 VPS 的 TCP 发送端。专治**随机丢包 10-30%、RTT 100-300ms** 的跨境普线（163/4837 晚高峰）——丢包不降速，按实测带宽发送，真堵了（延迟涨/ECN 标记）才刹车。客户端什么都不用装。上游 [CYBERVERSE-Research/skyline-speeder](https://github.com/CYBERVERSE-Research/skyline-speeder)（GPL-2.0，2026-10 核实活跃，206 star）。

| 和谁比 | 优势 |
|---|---|
| vs BBR | BBR 在 10-20% 随机丢包下速度明显下降；Skyline 丢包不降速（100M 链路 RTT100ms/丢 20%：BBR 3.5M → Skyline 95M，上游实测） |
| vs tcp-brutal | 不用手填带宽（自动估计）；有拥塞自保护；eBPF 加载前过内核检查（brutal 是 DKMS 内核模块） |

**适用判断**（tune.sh skyline 菜单里也有同样的引导）：

- ✅ 回程 163/4837 普线、晚高峰卡（`vps.sh net` 查回程）+ 内核 ≥ 6.12（Debian 13 自带；Debian 12 / Ubuntu 22.04/24.04 都不够）
- ❌ GIA/9929/CMIN2 优质线路——不怎么丢包，BBR 就够
- ❌ 丢包是 VPS 出口自身拥塞（排队溢出）——用了反而更慢

**与本工具箱的配合**（tune.sh 已内置，无需操心）：Skyline 启用时接管 CC/qdisc 并守住设置；tune.sh 检测到 `ACCELERATING` 状态会自动跳过 CC/qdisc 项（缓冲区 BDP 推导、initcwnd 等其余调优照常叠加），verify 也不误报。一键卸载后重跑 `tune.sh apply --force` 即恢复 bbr+fq。装完只对新连接生效，测试记得重连。

## 回滚

```bash
bash tune.sh rollback   # 恢复全部 sysctl 快照 + initcwnd 默认 + 删配置文件
```

- 快照保存在 `/var/lib/myvps-tune/pre-tune.snapshot`（第一次调优前的原始值）
- 建议回滚后重启一次让 tcp_mem 彻底还原
- BBRv3 内核回退：`apt remove linux-xanmod-lts-x64v3 && reboot`（旧内核仍在 grub）

## 常见问题

- **OpenVZ/LXC 鸡场**：tune.sh 自动降级为"仅 sysctl 尽力而为"（逐项试写，宿主拒绝的自动跳过）；换内核直接拒绝。UDP 缓冲（rmem_max≥16MB）对 Hysteria2 依然有效
- **小内存机（≤1GB）**：缓冲被内存/32 封顶防 OOM；无 swap 会提醒（TCP 缓冲高水位时代理进程可能被 OOM 杀）
- **GitHub 连不上**：所有下载自动回退 spiritlhl CDN 镜像（`cdn.spiritlhl.net` / `cdn0.spiritlhl.top`），均已实测可用
- **中国大陆内 VPS**：同样可用，镜像回退会自动生效
- **报错 "需要 root"**：`sudo bash xxx.sh` 或直接 root 登录

## 已知限制

- `checkup.sh` 的 ping 部分在 Windows Git Bash 下不可用（Windows ping 不认 `-c`）——脚本目标是 Linux VPS，此为预期行为
- iperf3 公共服务器无中国大陆节点（现状如此，Net.Check.Place 也没有），"单线程测速"测的是到全球就近点的单流吞吐；**到大陆的真实体验看 nettest.sh 的延迟+回程线路**
- tune.sh 的 initcwnd 重启后失效（DHCP 重装路由），重跑一次 `apply` 即可；sysctl 部分重启持久

## 上游项目致谢

- [tcpfit](https://github.com/Kylin010/tcpfit)（Kylin010）— BDP 推导与逐项校验算法（本工具箱剔除其遥测与推广）
- [oneclickvirt/ecs](https://github.com/oneclickvirt/ecs)（spiritLHLS）goecs 融合怪
- [oneclickvirt/backtrace](https://github.com/oneclickvirt/backtrace) — 三网回程判定与目标 IP 表
- [xykt/IPQuality](https://github.com/xykt/IPQuality) — IP 质量体检
- [nxtrace/NTrace-core](https://github.com/nxtrace/NTrace-core) — NextTrace
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)、[XanMod](https://xanmod.org/) — BBRv3 内核
- [CYBERVERSE-Research/skyline-speeder](https://github.com/CYBERVERSE-Research/skyline-speeder) — eBPF 拥塞控制（高丢包普线加速，2026-10 核实活跃）
- [lmc999/RegionRestrictionCheck](https://github.com/lmc999/RegionRestrictionCheck) — 流媒体解锁
- [tansir-1/vps-security-bootstrap](https://github.com/tansir-1/vps-security-bootstrap) v10.1.0 — SSH 事务备份/校验/回滚与验证门模式（SHA256 核对后源码级参考）
- [gnafehefang/VPS-QuickSetup](https://github.com/gnafehefang/VPS-QuickSetup) — 双端口过渡、新窗口验证流程
- [Lynthar/CloudServer-Audit](https://github.com/Lynthar/CloudServer-Audit) — 审计项清单参考（其 20 模块框架对个人 VPS 过重，未采用）
- pyxia.org/secure.sh — 已无法访问（DNS 失效），未能参考
- 参考过的 NodeQuality / SpeedQuality（其结果上传行为已在本工具箱中规避）
