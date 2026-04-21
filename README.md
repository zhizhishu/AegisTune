# AegisTune

AegisTune 是一个面向 Linux 服务器的交互式网络优化脚本，主文件是 `zhizhishu-net-opt.sh`。

它把常用的网络调优、快照回滚、扩展模块、安全检查，以及常用工具补全收敛到一个终端菜单里，避免手工东拼西凑。

## Quick Start

```bash
git clone https://github.com/zhizhishu/AegisTune.git
cd AegisTune
chmod +x zhizhishu-net-opt.sh
sudo ./zhizhishu-net-opt.sh
```

如果只想先看状态：

```bash
sudo ./zhizhishu-net-opt.sh status
```

## What It Does

- 交互安装 `BBR + FQ` 或 `BBR + CAKE`
- 基础安装默认不带 `bpftune`
- 提供快照创建、列表、回滚
- 独立管理 `bpftune`、`TCP Brutal`、`brutal-nginx`
- 内置 `DMIT Corona` 默认/激进两档参数
- 检测服务商原生 `sysctl` 配置，并支持重建/恢复基线
- 支持 `Serverspan` 自动调优，失败时自动回退到本地模板
- 自动挡会识别 `Serverspan` 过保守的 TCP 缓冲，并按内存/场景做本地修正
- 新增 `智能 BDP 自动调优`：
  - 手动带宽 + 地区估算 RTT
  - `speedtest` 自动测速 + 地区估算 RTT
  - 手动带宽 + RTT 实测
  - `speedtest` 自动测速 + RTT 实测
- 支持 `IPv4 优先` 设置，不强制关闭 IPv6
- 集成 SSH / Fail2ban / 端口 / cron / authorized_keys 安全检查
- 新增常用缺失工具补全：
  - 自动安装 `Docker Compose`
  - 下载并执行 `FRPS` 一键安装/卸载脚本

## Menu Overview

当前主菜单分为三块：

- 网络优化
- 安全检查
- 系统维护

其中“系统维护”里的“快速补全缺失工具”子菜单目前包含：

- Docker Compose 自动安装
- FRPS 一键安装
- FRPS 一键卸载

## Supported Systems

- Debian
- Ubuntu
- Alpine Linux
- Rocky Linux
- AlmaLinux
- CentOS / RHEL 系兼容环境

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

## Serverspan Auto Mode

`Serverspan general/moderate` 当前返回的 TCP 缓冲偏保守，常见会落在 `4-8 MiB` 档。

AegisTune 的自动挡现在会：

- 先保留 `Serverspan` 生成的其余 `sysctl` 参数
- 读取返回的 `net.core.rmem_max`
- 如果低于脚本的自动最低档，则仅覆盖 TCP 缓冲相关项
- 在预览和应用日志中显示“原值 -> 修正值”

这样做的目的，是避免自动挡在 `8GB`、`12GB`、`16GB` 这类机器上仍然落到 `3.9 MiB` 一类明显过小的窗口。

## Smart BDP Mode

除了 `Serverspan` 自动挡，AegisTune 现在还提供 `智能 BDP 自动调优`。

它借鉴了 `vps-tcp-tune` 的思路，但没有直接照搬整套代理专用参数，而是只保留通用且可解释的部分：

- 带宽来源可选：
  - 手动输入上传带宽
  - `speedtest` 自动检测上传带宽
- RTT 来源可选：
  - 按地区使用默认 RTT 估值
  - 对目标域名/IP 做 `ping` 实测 RTT
- 最终根据 `带宽 × RTT` 计算 BDP，再叠加安全系数生成 TCP buffer
- 结果会按机器内存做安全上限限制，避免小内存机器直接冲到不合理窗口

这套模式更适合：

- 跨境线路
- 长 RTT
- 明确知道自己出口带宽
- 不想直接套 `Corona` 固定值，但也不接受 `Serverspan general` 的小窗口

## Safety Notes

- `TCP Brutal` 不应被设为全局默认拥塞控制，脚本里已有保护逻辑
- `brutal-nginx` 依赖当前 `nginx` 版本和兼容编译参数
- `Serverspan general` 是偏保守模板，不等于 Corona 大缓冲档
- 服务商基线恢复依赖当前系统可搜集到的配置来源，不保证百分之百还原“出厂态”
- FRPS 使用第三方一键脚本，建议先确认其行为再在线上机器执行

## Common Commands

```bash
sudo ./zhizhishu-net-opt.sh
sudo ./zhizhishu-net-opt.sh status
sudo ./zhizhishu-net-opt.sh tools
sudo ./zhizhishu-net-opt.sh compose-install
sudo ./zhizhishu-net-opt.sh frps-install
sudo ./zhizhishu-net-opt.sh frps-uninstall
sudo ./zhizhishu-net-opt.sh smart-bdp
sudo ./zhizhishu-net-opt.sh smart-bdp-manual
sudo ./zhizhishu-net-opt.sh smart-bdp-speedtest
sudo ./zhizhishu-net-opt.sh smart-bdp-rtt
sudo ./zhizhishu-net-opt.sh smart-bdp-auto-rtt
```

## License

MIT License. See [LICENSE](./LICENSE).
