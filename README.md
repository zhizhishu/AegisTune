# AegisTune

AegisTune is a menu-driven Linux network tuning assistant built around `zhizhishu-net-opt.sh`.

它的定位很直接：把常见的 BBR / qdisc / sysctl / 扩展模块 / 安全检查 / 快照回滚 收敛进一个脚本里，尽量减少手工拼装和误操作。

## Name

- 推荐 GitHub 仓库名: `aegis-tune`
- 推荐项目名: `AegisTune`
- 当前主脚本: `zhizhishu-net-opt.sh`

## What It Solves

- 一键交互安装 `BBR + FQ` 或 `BBR + CAKE`
- 将 `bpftune` 从基础安装链路中剥离，避免和主安装逻辑冲突
- 集中管理 `bpftune`、`TCP Brutal`、`brutal-nginx`
- 在改动前创建快照，支持列表和回滚
- 检测服务商原生 `sysctl` 参数并重建/恢复基线
- 提供 `DMIT Corona` 两档参数模板
- 调用 Serverspan 自动生成通用 `sysctl`，并在失败时自动回退
- 集中处理 SSH / Fail2ban / 端口 / cron / `authorized_keys` 的安全检查

## Key Features

### 1. Base Install Path Stays Simple

基础安装只有一条主线：

- 选择 `FQ` 或 `CAKE`
- 安装并启用 `BBR`
- 应用基础 `sysctl`
- 校验结果

`bpftune` 不会在 `1) 交互式安装` 中自动安装，也不会在这里弹默认安装提示。  
这部分现在遵循最小化原则，避免和扩展管理重复。

### 2. Extension Management Is Isolated

扩展被统一收进 `5) 扩展管理`：

- 查看扩展状态
- 安装/启用 `bpftune`
- 彻底删除 `bpftune`
- 安装/加载 `TCP Brutal`
- 彻底删除 `TCP Brutal`
- 安装 `brutal-nginx`
- 彻底删除 `brutal-nginx`

这样做的目的是把“基础网络优化”和“额外能力”拆开，减少误触发。

### 3. Snapshot-First Workflow

涉及关键 `sysctl` 变更前，脚本支持：

- 创建快照
- 列出快照
- 从快照回滚

这对以下场景尤其重要：

- Corona 模板切换
- Serverspan 自动调优
- 服务商基线恢复
- 手工清理扩展模块前

### 4. DMIT Corona Profiles

当前脚本内置两档 Corona 参数：

- `dmit corona（默认配置, 40MB）`
- `dmit corona（激进, 67MB）`

理解方式很简单：

- `40MB` 适合默认/缓和使用
- `67MB` 适合更大 TCP 缓冲、偏激进的吞吐取向

### 5. Provider Baseline Detection / Restore

脚本支持识别系统当前已有的 `sysctl` 来源，并给出基线能力：

- 检测服务商原生调优参数
- 搜刮系统配置来源重建基线
- 按服务商基线恢复参数

这个功能不是“猜供应商”，而是尽量从现有系统配置文件、当前生效值和配置来源里重建可回退基线。

### 6. Serverspan Auto-Tuning With Safe Fallback

脚本的 Serverspan 流程现在是：

1. 识别系统、内核、CPU、线程、内存、网卡速率、磁盘类型、磁盘容量
2. 优先请求 Serverspan 网页生成器
3. 网页生成器不可用时，回退到旧 API
4. 旧 API 也失败时，回退到本地硬件模板
5. 先预览候选配置，再由用户确认是否应用
6. 应用前先创建快照

这比直接写入更稳，适合线上机器。

### 7. IPv4 / IPv6 Logic

首页状态卡片已经会展示：

- 当前 IPv4 地址
- IPv6 状态

脚本行为也做了约束：

- `IPv4 优先` 只修改地址选择优先级，不关闭 IPv6
- 只有系统检测到可用 IPv6 时，才会询问是否开启 IPv6 转发
- 如果系统没有可用 IPv6，不会再多问一次 IPv6 转发

### 8. Security Tools Are Grouped Together

安全相关项已经合并成一组，避免菜单分散：

- 开启 SSH root 密码登录
- 禁用 SSH 密码登录（仅密钥）
- 配置/启用 Fail2ban
- 停用/移除 Fail2ban
- 安全摘要检查
- 常用端口检查/修复
- 查看全部监听端口

## Supported Systems

- Debian
- Ubuntu
- Alpine Linux

需要：

- `root` 权限
- 可用的软件包管理器（`apt` / `apk` / 对应 RPM 系工具）
- 能访问外部网络时，脚本可尝试获取在线资源；拿不到时会进入回退链路

## Quick Start

只需要三步：

```bash
git clone https://github.com/zhizhishu/AegisTune.git
cd AegisTune
chmod +x zhizhishu-net-opt.sh
sudo ./zhizhishu-net-opt.sh
```

脚本启动后直接使用交互菜单即可。

如果只想先看当前状态：

```bash
sudo ./zhizhishu-net-opt.sh status
```

## Safety Notes

- `TCP Brutal` 不应该被设成全局默认拥塞控制，脚本里已经做了保护。
- `brutal-nginx` 会依赖当前 `nginx` 版本与兼容编译参数，第三方改版 `nginx` 需要自行确认。
- `Serverspan general` 是偏保守的通用模板，如果你是长 RTT / 高吞吐场景，不要把它和 Corona 大缓冲模板混为一谈。
- 服务商基线恢复依赖系统当前能搜集到的配置来源，不等于百分之百还原“出厂状态”，但足以作为安全回退层。

## Why The Project Name

`Aegis` 表示保护、护盾。这个脚本的核心价值不是“堆参数”，而是：

- 先识别
- 再预览
- 再快照
- 最后应用

所以 `AegisTune` 比单纯的 “BBR Script” 更贴近实际用途。

## License

MIT License. See [LICENSE](./LICENSE).
