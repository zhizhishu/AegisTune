# AegisTune

AegisTune 是一个面向 Linux 服务器的交互式网络优化脚本，主文件是 `aegistune.sh`。

它把常用的 BBR 加速、系统调优、快照回滚、安全防护，以及常用工具补全收敛到一个终端菜单里，避免手工东拼西凑。

## Quick Start

### 一键安装（推荐，**无需 git**）

全新服务器经常没装 `git`，直接 `git clone` 会报 `git: command not found`。用下面这条即可，只要机器有 `curl` 或 `wget`（几乎都自带）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhizhishu/AegisTune/main/aegistune.sh) setup
```

它会自动完成三件事：

- 把脚本落地到品牌家目录 **`/root/AegisTune/aegistune.sh`**（无需 `git clone`，也无需手动建文件夹）
- 安装短命令 `aeg`，之后任意目录输入 `aeg` 即可唤起主菜单（类似 nodeseek 里的 `n`）
- 在交互终端里直接进入主菜单

> 非 root 用户在前面加 `sudo`：`sudo bash <(curl -fsSL https://raw.githubusercontent.com/zhizhishu/AegisTune/main/aegistune.sh) setup`
> 只有 `wget` 没有 `curl`：`bash <(wget -qO- https://raw.githubusercontent.com/zhizhishu/AegisTune/main/aegistune.sh) setup`

装好之后，随手唤起菜单：

```bash
aeg
```

只想先看状态：

```bash
aeg status
```

### 手动下载（不用 git，也不用管道）

如果不想用 `bash <(...)` 管道形式，可以先把脚本下到本地再跑：

```bash
curl -fsSL https://raw.githubusercontent.com/zhizhishu/AegisTune/main/aegistune.sh -o aegistune.sh
chmod +x aegistune.sh
sudo ./aegistune.sh setup     # 落地到 /root/AegisTune + 安装 aeg 短命令
```

或者不装短命令，直接跑一次：

```bash
sudo ./aegistune.sh          # 主菜单
sudo ./aegistune.sh status   # 只看状态
```

### 开发者：git 克隆

需要二次开发或查看提交历史时再用 git（需先自行安装 git，如 `apt install -y git`）：

```bash
git clone https://github.com/zhizhishu/AegisTune.git
cd AegisTune
chmod +x aegistune.sh
sudo ./aegistune.sh setup
```

## 主菜单结构

主菜单是 4 大类一级菜单，逐层细分：

### 1) 🚀 BBR 加速

- 一键 BBR + FQ（推荐，通用低延迟）
- 一键 BBR + CAKE（更强整流，需内核支持）
- 交互安装（自选队列调度器）
- 查看加速状态
- 卸载网络优化

> 装 `FQ` / `CAKE` 时会先问**线路区域（亚洲近距 / 跨太平洋）+ 带宽**，按 **BDP（带宽 × RTT）** 自动算 TCP 缓冲；写出的 `sysctl` 只有 `BBR + 队列调度 + 缓冲`，不再无条件灌 fastopen / mtu_probing 等一堆固定基线。详见下方「BDP 缓冲自动计算」。

### 2) 🎛 系统调优

备份 / 恢复（落点 `/root/AegisTune/backups`）：

- 📦 备份当前配置
- ♻ 一键恢复（从快照回滚）
- 备份 / 快照列表

系统：

- Swap 管理（智能计算大小 + 磁盘余量护栏，防 OOM）

### 3) 🛡 安全防护

Fail2ban：

- 启用 Fail2ban（SSH 暴力破解防护）
- 移除 Fail2ban
- 查看封禁 IP / 状态
- Fail2ban 白名单（加白 / 移除 / 查看，安全写入防挂服务）

SSH / 端口：

- SSH 登录方式管理（密码 / 密钥 / 公钥开关，带锁死护栏）
- 常用端口检查 / 修复（22 / 80 / 443）
- 查看全部监听端口
- 安全摘要检查（SSH / 端口 / cron / authorized_keys）

### 4) 🔧 系统维护

- 工具补全（Docker Compose / FRPS）
- 出站流量守护（到量自动关机）
- 系统重装（DD / 容器 · **高危擦盘**，见下）

## Supported Systems

- Debian
- Ubuntu
- Alpine Linux（OpenRC）
- Rocky Linux
- AlmaLinux
- CentOS / RHEL 系兼容环境

### 跨发行版兼容

已针对非 Debian / 非 systemd 环境做兼容修复：

- Fail2ban：在 RHEL 系（Rocky / Alma / CentOS）会自动启用 EPEL 后再安装
- CAKE：在 RHEL 系走 `kernel-modules-extra` 获取队列模块
- 内核模块开机加载：非 systemd 环境写入 `/etc/modules` 保证重启后仍加载
- 内存读取走 `/proc/meminfo`，不依赖 `procps`（`free`），精简镜像也能正确取值

## Backup & Restore

所有备份快照统一收敛到品牌家目录下：

```text
/root/AegisTune/backups
```

其中 `AEGIS_HOME=/root/AegisTune` 是 AegisTune 的品牌家目录。

- 安装 / 调优前会自动创建快照
- 可在「系统调优」菜单里手动备份当前配置
- 支持「一键恢复」直接从快照回滚
- 支持查看快照列表，逐个比对回滚

## BDP 缓冲自动计算

AegisTune 不再堆一堆重复的「自动调优档」。装 `FQ` / `CAKE` 时只问两件事，按 **BDP（Bandwidth-Delay Product，带宽 × 延迟）** 算 TCP 缓冲：

1. **线路区域**（决定 RTT）：
   - 亚洲近距（RTT ≈ 50ms）
   - 跨太平洋（RTT ≈ 150ms）
   - 或直接输入实测 RTT
2. **端口 / 线路带宽**（Mbps）

计算规则：

- `BDP = 带宽(Mbps) × RTT(ms) × 125`（字节）
- 缓冲取 **2 × BDP**（生产环境推荐系数，覆盖 RTT 抖动 / 突发 / 多连接）
- 夹在 **[8 MiB, 64 MiB]** 之间（BBR 本身不依赖超大缓冲，>64MB 无额外收益还占内存）

举例：跨太平洋 1Gbps → `2 × (1000 × 150 × 125)` ≈ 37.5MB；亚洲近距 1Gbps → 约 12MB。

写出的 `sysctl` 只有 **拥塞控制 + 队列调度 + 按 BDP 算的缓冲**，纯净、可解释：

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = <2×BDP>
net.core.wmem_max = <2×BDP>
net.ipv4.tcp_rmem = 4096 <BDP/4> <2×BDP>
net.ipv4.tcp_wmem = 4096 <BDP/4> <2×BDP>
```

> 非交互运行（管道 / CI）默认按「跨太平洋 + 1000Mbps」取值，也可用环境变量覆盖：`AEGIS_RTT_MS` / `AEGIS_BW_MBPS`。

## Self-Test / Dry-Run

只想验证 BDP 缓冲计算逻辑、不改系统，直接运行：

```bash
./aegistune.sh self-test
./aegistune.sh dry-run
```

它：

- 不要求 root
- 不写 `/etc/sysctl.d`、不创建快照、不执行 `sysctl`
- 打印两档区域（亚洲近距 / 跨太平洋）× 三档带宽（500 / 1000 / 2000 Mbps）算出的缓冲预览表，方便上线前核对

## Swap 智能计算

「系统调优 → Swap 管理 → 创建 Swap」按物理内存分档推荐大小，并带两道护栏防止翻车：

- 分档：`<512MB → 1GB`、`512MB–1GB → 2×内存`、`1–2GB → 1.5×内存`、`2–4GB → 1×内存`、`≥4GB → 封顶 4GB`
- **磁盘余量护栏**：创建前检查根分区剩余空间，不足则中止，避免把小盘撑爆
- **已有 Swap 检测**：先列出现有 Swap，询问替换 / 跳过，不无脑叠加
- `swappiness`：内存 < 2GB 设 20，否则 10
- 内存读取走 `/proc/meminfo`，精简镜像无 `free` 也能算

## Docker Compose Install Logic

脚本会先识别系统，再按发行版选择安装方式：

- 已存在 `docker compose` 或 `docker-compose` 时，会直接识别并跳过安装
- Debian / Ubuntu：
  先尝试系统仓库，缺包时自动接入 Docker 官方仓库，再安装 `docker-compose-plugin`
- Alpine：
  优先安装 `docker-cli-compose`
- RHEL / Rocky / Alma / CentOS：
  先尝试系统仓库，缺包时自动接入 Docker 官方 RPM 仓库
- 如果包管理器安装失败：
  会尝试手动下载 Compose CLI 插件作为兜底

## FRPS Integration

脚本内置了对第三方 `frps-onekey` 的包装调用，实际执行来源为：

```bash
https://raw.githubusercontent.com/MvsCode/frps-onekey/master/install-frps.sh
```

脚本会在运行时下载该文件到临时目录，再执行：

- `install`
- `uninstall`

这意味着 FRPS 这部分属于“第三方安装器集成”，不是 AegisTune 自己重写的安装逻辑。

## Outbound Traffic Guard

出站流量守护用于限制从启用时刻开始计算的新增出站流量。它不会依赖 vnStat、iftop 等额外软件，而是直接读取 Linux 内核暴露的网卡计数：

```bash
/sys/class/net/<interface>/statistics/tx_bytes
```

常用命令：

```bash
sudo ./aegistune.sh traffic-guard
sudo ./aegistune.sh traffic-guard-status
sudo ./aegistune.sh traffic-guard-stop
sudo ./aegistune.sh traffic-guard-remove
```

配置时脚本会：

- 自动推荐默认出口网卡，也允许手动输入网卡名
- 记录当前 `tx_bytes` 作为基线
- 让你输入新增出站流量上限，单位为 GiB
- 安装并启动守护服务
- 支持 Debian / Ubuntu 常见的 systemd，也支持 Alpine 常用的 OpenRC；SysV 环境提供基础兜底

达到阈值后，守护进程会按顺序尝试 `shutdown -h now`、`poweroff`、`halt -p`。这是一个真实关机动作，请只在确认阈值和网卡无误后启用。

## 系统重装 (DD / 容器)

> ⚠️ **高危：会彻底擦除本服务器全部数据并重装系统，不可逆，本地快照救不了。操作前务必把数据备份到机器之外。**

「系统维护 → 系统重装」是对两个**第三方官方一键脚本的跳转封装**（和 FRPS 一样，脚本运行时下载官方脚本执行，**不移植其逻辑**）。菜单会先检测本机虚拟化类型并给出推荐，帮你在互斥的两条路里选对：

| 路径 | 适用架构 | 官方脚本 | 不适用 |
|------|---------|---------|--------|
| **DD 网络重装** | KVM / Xen / 独立服务器 | [leitbogioro `InstallNET.sh`](https://github.com/leitbogioro/Tools) | OpenVZ / LXC 容器 |
| **容器重装** | OpenVZ 7 / LXC 容器 | [LloydAsp `OsMutation.sh`](https://github.com/LloydAsp/OsMutation) | KVM、OpenVZ 6 |

**装错工具跑不动**，所以菜单在检测到类型不匹配时会红字拦截。三种用法：

- **DD 网络重装**（KVM/Xen/独服）：交互选发行版 / 版本 / root 密码 / SSH 端口 → 显示将执行的完整命令 → **需完整输入大写 `REINSTALL` 二次确认**才会下载并执行（随后机器重启进入安装）。
- **容器重装**（OpenVZ7/LXC）：同样二次确认后，下载并启动 OsMutation 自带的交互菜单。
- **只打印命令 / 复制**：只把官方命令按你的选择拼好打印出来，**脚本绝不替你执行**，你自己复制到目标机跑。

CLI：

```bash
sudo aegistune.sh reinstall        # 系统重装菜单
sudo aegistune.sh dd               # 直接进 DD 网络重装 (确认后执行)
sudo aegistune.sh dd-container     # 直接进 容器重装 (确认后执行)
sudo aegistune.sh reinstall-cmd    # 只打印两条官方命令，不执行
```

## Safety Notes

- 系统重装（DD / 容器）会**擦除整机数据并重装系统**，不可逆；仅在交互二次输入 `REINSTALL` 后才执行，且请先把数据备份到机器之外
- 出站流量守护达到阈值后会**真实关机**；启用前请确认监控网卡和流量上限
- FRPS 使用第三方一键脚本，建议先确认其行为再在线上机器执行
- 创建 Swap 前会检查磁盘余量，不足即中止；但仍建议自行确认根分区空间

## Common Commands

```bash
# 主菜单 / 短命令
sudo ./aegistune.sh
sudo ./aegistune.sh link          # 安装 aeg 短命令

# BBR 加速（装时按 BDP 算缓冲）
sudo ./aegistune.sh fq
sudo ./aegistune.sh cake
sudo ./aegistune.sh install
sudo ./aegistune.sh status
sudo ./aegistune.sh uninstall

# 备份 / 恢复
sudo ./aegistune.sh snapshot
sudo ./aegistune.sh rollback
sudo ./aegistune.sh snapshots

# 安全防护
sudo ./aegistune.sh fail2ban
sudo ./aegistune.sh fail2ban-rm
sudo ./aegistune.sh fail2ban-whitelist-add [IP]
sudo ./aegistune.sh fail2ban-whitelist-remove [IP]
sudo ./aegistune.sh fail2ban-whitelist-list
sudo ./aegistune.sh ssh
sudo ./aegistune.sh ssh-off
sudo ./aegistune.sh ssh-pubkey-off

# 系统维护
sudo ./aegistune.sh tools
sudo ./aegistune.sh compose-install
sudo ./aegistune.sh frps-install
sudo ./aegistune.sh frps-uninstall
sudo ./aegistune.sh traffic-guard
sudo ./aegistune.sh traffic-guard-status
sudo ./aegistune.sh traffic-guard-stop
sudo ./aegistune.sh traffic-guard-remove

# 系统重装 (DD / 容器 · 高危擦盘，确认后不可逆)
sudo ./aegistune.sh reinstall        # 重装菜单
sudo ./aegistune.sh dd               # DD 网络重装 (KVM/Xen/独服)
sudo ./aegistune.sh dd-container     # 容器重装 (OpenVZ7/LXC)
sudo ./aegistune.sh reinstall-cmd    # 只打印官方命令，不执行

# 自检（不需 root，不写系统）
./aegistune.sh self-test
./aegistune.sh dry-run
```

## License

MIT License. See [LICENSE](./LICENSE).
