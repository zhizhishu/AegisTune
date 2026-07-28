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
- 进阶扩展模块（`bpftune` / `TCP Brutal` / `brutal-nginx`）

> 基础安装默认不带 `bpftune`，如需启用请进「进阶扩展模块」单独安装。

### 2) 🎛 系统调优

调优：

- 一键自动调优（推荐：统一自动挡 / 智能 BDP / 自检）
- DMIT Corona 预设（默认 / 激进）
- IPv4 优先（不关闭 IPv6）
- Swap 管理
- 检测服务商原生基线

备份 / 恢复（落点 `/root/AegisTune/backups`）：

- 📦 备份当前配置
- ♻ 一键恢复（从快照回滚）
- 备份 / 快照列表
- 重建服务商基线
- 按服务商基线恢复

### 3) 🛡 安全防护

Fail2ban：

- 启用 Fail2ban（SSH 暴力破解防护）
- 移除 Fail2ban
- 查看封禁 IP / 状态

SSH / 端口：

- 开启 SSH root 密码登录
- 禁用 SSH 密码登录（仅密钥）
- 常用端口检查 / 修复（22 / 80 / 443）
- 查看全部监听端口
- 安全摘要检查（SSH / 端口 / cron / authorized_keys）

### 4) 🔧 系统维护

- 工具补全（Docker Compose / FRPS）
- 出站流量守护（到量自动关机）

## Supported Systems

- Debian
- Ubuntu
- Alpine Linux（OpenRC）
- Rocky Linux
- AlmaLinux
- CentOS / RHEL 系兼容环境

### 跨发行版兼容

本轮已针对非 Debian / 非 systemd 环境做兼容修复：

- Fail2ban：在 RHEL 系（Rocky / Alma / CentOS）会自动启用 EPEL 后再安装
- CAKE：在 RHEL 系走 `kernel-modules-extra` 获取队列模块
- bpftune：在缺少 systemd 的环境补齐 SysV 服务脚本
- 内核模块开机加载：非 systemd 环境写入 `/etc/modules` 保证重启后仍加载

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

## Unified Auto Mode

默认推荐使用的是 `统一自动调优`，不是单独的 `Serverspan` 或单独的 `Smart BDP`。

它的决策顺序是：

1. 先读取当前机器可识别的 `原厂/服务商基线`
2. 再生成 `Serverspan` 模板；如果外站不可用，则退回本地硬件模板
3. 最后用 `Smart BDP` 只接管 TCP buffer 相关项
4. 应用前展示决策预览表，明确标出：
   - 最终值
   - 来源
   - 基线值
   - 模板值
   - BDP 候选值

这样做的目的，是避免只信任某一个来源：

- 尽量保留服务商 / 镜像本来的合理参数
- 不丢掉外部模板对通用项的补齐
- 不再盲信 `Serverspan general` 这类过小 TCP buffer

## Serverspan Auto Mode

`Serverspan general/moderate` 当前返回的 TCP 缓冲偏保守，常见会落在 `4-8 MiB` 档。

AegisTune 的自动挡现在会：

- 先保留 `Serverspan` 生成的其余 `sysctl` 参数
- 读取返回的 `net.core.rmem_max`
- 如果低于脚本的自动最低档，则仅覆盖 TCP 缓冲相关项
- 在预览和应用日志中显示“原值 -> 修正值”

这样做的目的，是避免自动挡在 `8GB`、`12GB`、`16GB` 这类机器上仍然落到 `3.9 MiB` 一类明显过小的窗口。

## Smart BDP Mode

除了 `Serverspan` 自动挡，AegisTune 还提供 `智能 BDP 自动调优`。

它借鉴了 `vps-tcp-tune` 的思路，但没有直接照搬整套代理专用参数，而是只保留通用且可解释的部分：

- 带宽来源可选：
  - 手动输入上传带宽
  - `speedtest` 自动检测上传带宽
- RTT 来源可选：
  - 按地区使用默认 RTT 估值
  - 对目标域名 / IP 做 `ping` 实测 RTT
- 最终根据 `带宽 × RTT` 计算 BDP，再叠加安全系数生成 TCP buffer
- 结果会按机器内存做安全上限限制，避免小内存机器直接冲到不合理窗口

这套模式更适合：

- 跨境线路
- 长 RTT
- 明确知道自己出口带宽
- 不想直接套 `Corona` 固定值，但也不接受 `Serverspan general` 的小窗口

## Self-Test / Dry-Run

如果你只想先验证三条自动调优链路能否跑通，而不改系统，可以直接运行：

```bash
./aegistune.sh self-test
./aegistune.sh dry-run
```

这个命令默认：

- 不要求 root
- 不写 `/etc/sysctl.d`
- 不创建快照
- 不执行 `sysctl --system`
- 会依次生成并展示：
  - `Serverspan` dry-run 预览
  - `Smart BDP` dry-run 预览
  - `统一自动挡` dry-run 决策预览

说明：

- `self-test` 用的是探测值和近似值，只用于验证链路是否正常
- 它不是最终推荐参数生成器
- 真正应用参数仍然建议走主菜单里的自动调优

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

## Safety Notes

- 出站流量守护达到阈值后会**真实关机**；启用前请确认监控网卡和流量上限
- FRPS 使用第三方一键脚本，建议先确认其行为再在线上机器执行
- `TCP Brutal` 不应被设为全局默认拥塞控制，脚本里已有保护逻辑
- `brutal-nginx` 依赖当前 `nginx` 版本和兼容编译参数
- `Serverspan general` 是偏保守模板，不等于 Corona 大缓冲档
- 服务商基线恢复依赖当前系统可搜集到的配置来源，不保证百分之百还原“出厂态”

## Common Commands

```bash
# 主菜单 / 短命令
sudo ./aegistune.sh
sudo ./aegistune.sh link          # 安装 aeg 短命令

# BBR 加速
sudo ./aegistune.sh fq
sudo ./aegistune.sh cake
sudo ./aegistune.sh install
sudo ./aegistune.sh status
sudo ./aegistune.sh uninstall
sudo ./aegistune.sh extensions
sudo ./aegistune.sh brutal
sudo ./aegistune.sh brutal-ng
sudo ./aegistune.sh bpftune-rm

# 系统调优
sudo ./aegistune.sh auto-tune
sudo ./aegistune.sh auto-unified-manual
sudo ./aegistune.sh auto-unified-speedtest
sudo ./aegistune.sh auto-unified-rtt
sudo ./aegistune.sh auto-unified-auto-rtt
sudo ./aegistune.sh smart-bdp
sudo ./aegistune.sh smart-bdp-manual
sudo ./aegistune.sh smart-bdp-speedtest
sudo ./aegistune.sh smart-bdp-rtt
sudo ./aegistune.sh smart-bdp-auto-rtt
sudo ./aegistune.sh corona
sudo ./aegistune.sh dmit-corona
sudo ./aegistune.sh an4-corona
sudo ./aegistune.sh api-sysctl
sudo ./aegistune.sh api-general
sudo ./aegistune.sh ipv4-prefer
sudo ./aegistune.sh vendor-check
sudo ./aegistune.sh vendor-rescan
sudo ./aegistune.sh vendor-restore

# 备份 / 恢复
sudo ./aegistune.sh snapshot
sudo ./aegistune.sh rollback
sudo ./aegistune.sh snapshots

# 安全防护
sudo ./aegistune.sh fail2ban
sudo ./aegistune.sh fail2ban-rm
sudo ./aegistune.sh ssh
sudo ./aegistune.sh ssh-off

# 系统维护
sudo ./aegistune.sh tools
sudo ./aegistune.sh compose-install
sudo ./aegistune.sh frps-install
sudo ./aegistune.sh frps-uninstall
sudo ./aegistune.sh traffic-guard
sudo ./aegistune.sh traffic-guard-status
sudo ./aegistune.sh traffic-guard-stop
sudo ./aegistune.sh traffic-guard-remove

# 自检（不需 root，不写系统）
./aegistune.sh self-test
./aegistune.sh dry-run
```

## License

MIT License. See [LICENSE](./LICENSE).
