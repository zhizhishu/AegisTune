#!/bin/bash

# =========================================================
# AegisTune 网络优化助手（BBR + BDP 缓冲 + 快照）
# 支持: Ubuntu / Debian / Alpine Linux
# 功能: 环境检测 + BBR + CAKE/FQ 安装(按 BDP 算缓冲) + 快照回滚 + 安全检查
# 备注: AegisTune 开发整合
# =========================================================

# 注意：交互式菜单脚本刻意不启用 `set -e`。菜单里大量函数会走 `return 1`
# 错误分支、或以返回非零的命令收尾（grep 无匹配、探测失败等），若开 set -e
# 任何一步非零都会把整个脚本踹回 shell、直接退出菜单。本脚本各处已用
# `|| true` / 显式 return / log_error 自行处理错误，不依赖 set -e。
set +e

# ============ 通用工具 ============

get_ssh_port() {
    local port
    port=$(grep -E "^Port" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
    [[ -z "$port" ]] && port=22
    echo "$port"
}

# 避坑：防止将 brutal 设为全局拥塞控制（只检测警告，不写系统）
ensure_brutal_not_default() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$cc" == "brutal" ]]; then
        log_warn "检测到 brutal 为全局拥塞控制，建议改回 bbr，可重新安装或手动执行：sysctl -w net.ipv4.tcp_congestion_control=bbr"
    fi
}

warn_brutal_usage() {
    if lsmod | grep -q "^brutal" 2>/dev/null; then
        log_warn "已加载 brutal 模块：请勿将其设为全局拥塞控制，仅在支持的应用中按需启用（如 sing-box/mihomo 的 brutal、brutal-nginx）。"
    fi
}

change_ssh_port() {
    local target_port="$1"
    [[ -z "$target_port" ]] && return 1
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    local BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"
    [[ -f "$SSHD_CONFIG" ]] && cp "$SSHD_CONFIG" "$BACKUP_FILE"
    if grep -qE "^Port" "$SSHD_CONFIG"; then
        sed -i "s/^Port.*/Port $target_port/" "$SSHD_CONFIG"
    else
        echo "Port $target_port" >> "$SSHD_CONFIG"
    fi
    log_info "SSH 端口已改为 $target_port，备份: $BACKUP_FILE"
    if sshd -t 2>/dev/null; then
        if service_action_any restart sshd ssh; then
            log_success "SSH 已重启"
        else
            log_warn "SSH 重启失败，请手动检查服务管理器"
        fi
    else
        log_warn "sshd 配置语法检测失败，已保留备份 $BACKUP_FILE"
    fi
}

check_common_ports() {
    log_section "端口检查"
    local ssh_port current22 current80 current443
    ssh_port=$(get_ssh_port)
    current22=$(ss -tln 2>/dev/null | awk '$4 ~ /:22$/ {print $4}' | head -1)
    current80=$(ss -tln 2>/dev/null | awk '$4 ~ /:80$/ {print $4}' | head -1)
    current443=$(ss -tln 2>/dev/null | awk '$4 ~ /:443$/ {print $4}' | head -1)

    echo -e "${CYAN}当前 SSH 端口: ${ssh_port}${NC}"
    if [[ -z "$current22" ]]; then
        echo -e "${YELLOW}提示:${NC} 未发现 22 监听"
    else
        echo -e "${GREEN}22 监听正常${NC}"
    fi
    if [[ -z "$current80" ]]; then
        echo -e "${YELLOW}提示:${NC} 未发现 80 监听"
    else
        echo -e "${GREEN}80 监听正常${NC}"
    fi
    if [[ -z "$current443" ]]; then
        echo -e "${YELLOW}提示:${NC} 未发现 443 监听"
    else
        echo -e "${GREEN}443 监听正常${NC}"
    fi

    # 仅提供将 SSH 端口改回 22 的选项，其它端口需自行启动对应服务
    read -p "是否将 SSH 端口改为(默认 22，回车跳过): " fix_ssh_port
    if [[ -n "$fix_ssh_port" ]]; then
        change_ssh_port "$fix_ssh_port"
    fi

    read -p "是否在防火墙放行 22/80/443 (iptables/ip6tables)? [y/N]: " allow_fw
    if [[ "$allow_fw" =~ ^[Yy]$ ]]; then
        for p in 22 80 443; do
            if command -v iptables >/dev/null; then iptables -I INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || true; fi
            if command -v ip6tables >/dev/null; then ip6tables -I INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || true; fi
        done
        log_success "已尝试放行 22/80/443 (iptables/ip6tables)，如使用 nft/云防火墙需另行配置。"
    fi

    log_info "若需开放 80/443，请确保有 Web 服务监听；如使用 nft/云防火墙，请同步配置。"
}

list_all_listening_ports() {
    log_section "全部监听端口 (tcp/udp)"
    ss -tunlp 2>/dev/null || netstat -tunlp 2>/dev/null || echo "无法获取端口信息"
    echo ""
    echo -e "${CYAN}iptables/nftables 状态 (概览):${NC}"
    if command -v nft >/dev/null; then
        nft list ruleset 2>/dev/null | head -n 50 || true
    elif command -v iptables >/dev/null; then
        iptables -L -n 2>/dev/null | head -n 50 || true
    else
        echo "未检测到 nft/iptables"
    fi
}

# ============ 安全快速检查 (后门入口扫查) ============
security_quick_check() {
    log_section "安全快速检查 (SSH/端口/定时任务/keys)"

    # SSH 配置
    local ssh_port
    ssh_port=$(get_ssh_port)
    local root_login=$(grep -E "^#?PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | tail -1 || echo "未设置")
    local pass_auth=$(grep -E "^#?PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | tail -1 || echo "未设置")
    echo -e "${CYAN}SSH:${NC} 端口=$ssh_port, PermitRootLogin=$root_login, PasswordAuthentication=$pass_auth"

    # authorized_keys 摘要
    if [[ -f /root/.ssh/authorized_keys ]]; then
        local key_count
        key_count=$(wc -l < /root/.ssh/authorized_keys)
        echo -e "${CYAN}authorized_keys:${NC} 存在 (${key_count} 行)"
        tail -n 3 /root/.ssh/authorized_keys | sed 's/^/  tail: /'
    else
        echo -e "${CYAN}authorized_keys:${NC} 未找到 /root/.ssh/authorized_keys"
    fi

    # 监听端口（前 10 行）
    echo -e "${CYAN}监听端口(前10行):${NC}"
    ss -tunlp 2>/dev/null | head -n 10

    # 定时任务摘要
    echo -e "${CYAN}定时任务:${NC}"
    echo "  root crontab:"
    crontab -l 2>/dev/null | sed 's/^/    /' || echo "    (无)"
    echo "  /etc/cron.d:"
    ls -1 /etc/cron.d 2>/dev/null | sed 's/^/    /' || echo "    (无)"
    echo "  /etc/rc.local:"
    if [[ -f /etc/rc.local ]]; then
        tail -n 5 /etc/rc.local | sed 's/^/    /'
    else
        echo "    未找到 /etc/rc.local"
    fi

    log_info "如需进一步排查，请手工检查上述文件及服务。"
}

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BLUE='\033[34m'
MAGENTA='\033[35m'
NC='\033[0m'

# 全局变量
OS_TYPE=""
OS_VERSION=""
PKG_MANAGER=""
INIT_SYSTEM=""
KERNEL_VERSION=""
QDISC_CHOICE="fq"  # 默认使用 fq
BBR_AVAILABLE=0
CAKE_AVAILABLE=0
FQ_AVAILABLE=0
AEGIS_HOME="/root/AegisTune"
SNAPSHOT_ROOT="${AEGIS_HOME}/backups"
# 一键安装(setup)用：远端原始脚本地址 + 持久化后的本地路径
AEGIS_RAW_URL="https://raw.githubusercontent.com/zhizhishu/AegisTune/main/aegistune.sh"
PERSISTED_SELF_PATH=""
# 系统重装(DD/容器)跳转用：第三方官方脚本地址(不移植逻辑，仅下载执行)
INSTALLNET_URL="https://raw.githubusercontent.com/leitbogioro/Tools/master/Linux_reinstall/InstallNET.sh"
OSMUTATION_URL="https://raw.githubusercontent.com/LloydAsp/OsMutation/main/OsMutation.sh"
STATUS_CACHE_ROOT="/tmp/aegistune"
PUBLIC_IPV4_CACHE="${STATUS_CACHE_ROOT}/public_ipv4.cache"
PUBLIC_IPV6_CACHE="${STATUS_CACHE_ROOT}/public_ipv6.cache"
TRAFFIC_GUARD_SERVICE="aegistune-traffic-guard"
TRAFFIC_GUARD_CONFIG="/etc/aegistune-traffic-guard.conf"
TRAFFIC_GUARD_RUNNER="/usr/local/sbin/aegistune-traffic-guard"
TRAFFIC_GUARD_LOG="/var/log/aegistune-traffic-guard.log"

# ============ 工具函数 ============

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

has_live_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -d /run/systemd/system ]] || return 1
    systemctl list-unit-files >/dev/null 2>&1
}

get_service_manager() {
    if [[ -n "${INIT_SYSTEM:-}" ]] && [[ "$INIT_SYSTEM" != "unknown" ]]; then
        echo "$INIT_SYSTEM"
        return 0
    fi

    if has_live_systemd; then
        echo "systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        echo "openrc"
    elif command -v service >/dev/null 2>&1; then
        echo "sysv"
    else
        echo "unknown"
    fi
}

service_action_any() {
    local action="$1"
    shift
    local manager
    manager="$(get_service_manager)"
    local svc

    case "$manager" in
        systemd)
            for svc in "$@"; do
                systemctl "$action" "$svc" 2>/dev/null && return 0
            done
            ;;
        openrc)
            for svc in "$@"; do
                rc-service "$svc" "$action" 2>/dev/null && return 0
            done
            ;;
        sysv)
            for svc in "$@"; do
                service "$svc" "$action" 2>/dev/null && return 0
            done
            ;;
    esac

    return 1
}

service_enable_any() {
    local manager
    manager="$(get_service_manager)"
    local svc

    case "$manager" in
        systemd)
            for svc in "$@"; do
                systemctl enable "$svc" 2>/dev/null && return 0
            done
            ;;
        openrc)
            for svc in "$@"; do
                rc-update add "$svc" default 2>/dev/null && return 0
            done
            ;;
        sysv)
            return 0
            ;;
    esac

    return 1
}

service_disable_any() {
    local manager
    manager="$(get_service_manager)"
    local svc

    case "$manager" in
        systemd)
            for svc in "$@"; do
                systemctl disable "$svc" 2>/dev/null && return 0
            done
            ;;
        openrc)
            for svc in "$@"; do
                rc-update del "$svc" default 2>/dev/null && return 0
            done
            ;;
        sysv)
            return 0
            ;;
    esac

    return 1
}

service_is_active_any() {
    local manager
    manager="$(get_service_manager)"
    local svc

    case "$manager" in
        systemd)
            for svc in "$@"; do
                systemctl is-active --quiet "$svc" 2>/dev/null && return 0
            done
            ;;
        openrc)
            for svc in "$@"; do
                rc-service "$svc" status >/dev/null 2>&1 && return 0
            done
            ;;
        sysv)
            for svc in "$@"; do
                service "$svc" status >/dev/null 2>&1 && return 0
            done
            ;;
    esac

    return 1
}

service_daemon_reload() {
    [[ "$(get_service_manager)" == "systemd" ]] || return 0
    systemctl daemon-reload 2>/dev/null || true
}


pause_return_main_menu() {
    echo ""
    read -r -p "按回车返回主菜单..." _
}

log_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本！"
        echo "使用方法: sudo bash $0"
        exit 1
    fi
}

# ============ 系统检测 ============

detect_os() {
    log_section "系统环境检测"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_TYPE="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"
        OS_VERSION=$(cat /etc/alpine-release)
    else
        log_error "无法识别的操作系统"
        exit 1
    fi
    
    case "$OS_TYPE" in
        ubuntu|debian|alpine|rocky|almalinux|centos|rhel) ;;
        linuxmint|pop) OS_TYPE="ubuntu" ;;
        *)
            log_warn "未经测试的发行版: $OS_TYPE，尝试按 Debian 系处理"
            OS_TYPE="debian"
            ;;
    esac
    
    log_success "操作系统: $OS_TYPE $OS_VERSION"
}

detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    else
        log_error "未找到支持的包管理器"
        exit 1
    fi
    log_success "包管理器: $PKG_MANAGER"
}

detect_init_system() {
    if has_live_systemd; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &> /dev/null; then
        INIT_SYSTEM="openrc"
    elif command -v service &> /dev/null; then
        INIT_SYSTEM="sysv"
    else
        INIT_SYSTEM="unknown"
    fi
    log_success "Init 系统: $INIT_SYSTEM"
}

detect_kernel() {
    KERNEL_VERSION=$(uname -r)
    log_success "内核版本: $KERNEL_VERSION"
}

# ============ 功能检测 ============

check_bbr_support() {
    log_section "BBR 拥塞控制检测"
    
    # 尝试加载模块
    modprobe tcp_bbr 2>/dev/null || true
    
    if lsmod | grep -q tcp_bbr || sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        BBR_AVAILABLE=1
        log_success "BBR 模块可用 ✓"
        log_info "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    else
        log_warn "BBR 模块不可用，可能需要升级内核"
    fi
}

check_qdisc_support() {
    log_section "队列调度器检测"
    
    # 检测 FQ
    modprobe sch_fq 2>/dev/null || true
    if lsmod | grep -q sch_fq || modprobe -n sch_fq 2>/dev/null; then
        FQ_AVAILABLE=1
        log_success "FQ (Fair Queue) 可用 ✓"
    else
        log_warn "FQ 不可用"
    fi
    
    # 检测 CAKE
    modprobe sch_cake 2>/dev/null || true
    if lsmod | grep -q sch_cake || modprobe -n sch_cake 2>/dev/null; then
        CAKE_AVAILABLE=1
        log_success "CAKE (Common Applications Kept Enhanced) 可用 ✓"
    else
        log_info "CAKE 不可用 (需要内核 4.19+ 或额外模块)"
    fi
    
    log_info "当前队列调度: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
}

# ============ 用户选择菜单 ============

show_qdisc_menu() {
    log_section "队列调度器选择"
    
    echo ""
    echo -e "${MAGENTA}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${MAGENTA}│            请选择队列调度算法 (搭配 BBR 使用)               │${NC}"
    echo -e "${MAGENTA}├─────────────────────────────────────────────────────────────┤${NC}"
    
    if [[ $FQ_AVAILABLE -eq 1 ]]; then
        echo -e "${MAGENTA}│${NC}  ${GREEN}1)${NC} fq   - Fair Queue (推荐，BBR 官方搭档)               ${MAGENTA}│${NC}"
        echo -e "${MAGENTA}│${NC}           轻量高效，专为 BBR 优化                         ${MAGENTA}│${NC}"
    else
        echo -e "${MAGENTA}│${NC}  ${RED}1)${NC} fq   - 不可用                                        ${MAGENTA}│${NC}"
    fi
    
    echo -e "${MAGENTA}│${NC}                                                             ${MAGENTA}│${NC}"
    
    if [[ $CAKE_AVAILABLE -eq 1 ]]; then
        echo -e "${MAGENTA}│${NC}  ${GREEN}2)${NC} cake - CAKE (高级，智能 QoS)                         ${MAGENTA}│${NC}"
        echo -e "${MAGENTA}│${NC}           自动优化延迟、带宽分配，适合多用户场景           ${MAGENTA}│${NC}"
    else
        echo -e "${MAGENTA}│${NC}  ${YELLOW}2)${NC} cake - 不可用 (需要安装额外模块)                     ${MAGENTA}│${NC}"
    fi
    echo -e "${MAGENTA}│${NC}                                                             ${MAGENTA}│${NC}"
    echo -e "${MAGENTA}│${NC}  ${CYAN}0)${NC} 返回上层菜单                                           ${MAGENTA}│${NC}"
    
    echo -e "${MAGENTA}└─────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    while true; do
        read -p "请输入选择 [1/2/0] (默认: 1): " choice
        choice=${choice:-1}
        
        case $choice in
            1)
                if [[ $FQ_AVAILABLE -eq 1 ]]; then
                    QDISC_CHOICE="fq"
                    log_success "已选择: BBR + FQ"
                    break
                else
                    log_error "FQ 不可用，请选择其他选项"
                fi
                ;;
            2)
                if [[ $CAKE_AVAILABLE -eq 1 ]]; then
                    QDISC_CHOICE="cake"
                    log_success "已选择: BBR + CAKE"
                    break
                else
                    log_warn "CAKE 不可用"
                    read -p "是否尝试安装 CAKE 模块? [y/N]: " install_cake
                    if [[ "$install_cake" =~ ^[Yy]$ ]]; then
                        install_cake_module
                        if [[ $CAKE_AVAILABLE -eq 1 ]]; then
                            QDISC_CHOICE="cake"
                            log_success "已选择: BBR + CAKE"
                            break
                        fi
                    fi
                fi
                ;;
            0)
                log_info "已取消交互式安装，返回上层菜单"
                return 1
                ;;
            *)
                log_error "无效选择，请输入 1、2 或 0"
                ;;
        esac
    done
}

install_cake_module() {
    log_info "尝试安装 CAKE 模块..."
    
    case $PKG_MANAGER in
        apt)
            apt-get update -qq
            # 尝试安装内核额外模块
            apt-get install -y -qq linux-modules-extra-$(uname -r) 2>/dev/null || \
            apt-get install -y -qq linux-image-extra-$(uname -r) 2>/dev/null || true
            
            modprobe sch_cake 2>/dev/null || true
            ;;
        apk)
            # Alpine 需要特殊处理
            apk add --quiet iproute2 2>/dev/null || true
            modprobe sch_cake 2>/dev/null || true
            ;;
        dnf|yum)
            # RHEL/Rocky/Alma/CentOS: sch_cake 位于 kernel-modules-extra
            $PKG_MANAGER install -y kernel-modules-extra 2>/dev/null || true
            $PKG_MANAGER install -y iproute-tc 2>/dev/null || true
            modprobe sch_cake 2>/dev/null || true
            ;;
    esac

    if lsmod | grep -q sch_cake; then
        CAKE_AVAILABLE=1
        log_success "CAKE 模块安装成功"
    else
        log_warn "CAKE 模块安装失败，将使用 FQ 作为替代"
        QDISC_CHOICE="fq"
    fi
}

# ============ 安装函数 ============

update_pkg_cache() {
    log_info "更新软件包缓存..."
    case $PKG_MANAGER in
        apt) apt-get update -qq ;;
        apk) apk update -q ;;
        dnf) dnf makecache -q ;;
        yum) yum makecache -q ;;
    esac
}

install_dependencies() {
    log_section "安装依赖项"
    
    case $PKG_MANAGER in
        apt)
            apt-get install -y -qq curl wget ca-certificates gnupg
            ;;
        apk)
            apk add --quiet curl wget ca-certificates
            ;;
        dnf|yum)
            $PKG_MANAGER install -y -q curl wget ca-certificates gnupg
            ;;
    esac
    
    log_success "依赖安装完成"
}

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
        return $?
    fi

    return 1
}

install_kernel_modules() {
    log_section "配置内核模块"
    
    # 创建模块加载配置
    cat > /etc/modules-load.d/network-tuning.conf <<EOF
# 网络调优模块 - 自动加载
tcp_bbr
sch_fq
EOF

    # 如果选择了 CAKE，添加到模块列表
    if [[ "$QDISC_CHOICE" == "cake" ]]; then
        echo "sch_cake" >> /etc/modules-load.d/network-tuning.conf
    fi

    # 非 systemd 环境: systemd-modules-load 不生效，改用经典 /etc/modules (OpenRC/SysV 开机读取)
    if [[ "$INIT_SYSTEM" != "systemd" ]]; then
        touch /etc/modules 2>/dev/null || true
        local _mods="tcp_bbr sch_fq"
        [[ "$QDISC_CHOICE" == "cake" ]] && _mods="$_mods sch_cake"
        for _m in $_mods; do
            grep -qxF "$_m" /etc/modules 2>/dev/null || echo "$_m" >> /etc/modules
        done
        # Alpine/OpenRC: 确保 modules 服务在 boot 运行级加载模块
        if [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-update >/dev/null 2>&1; then
            rc-update add modules boot 2>/dev/null || true
        fi
    fi

    # 立即加载模块
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    [[ "$QDISC_CHOICE" == "cake" ]] && modprobe sch_cake 2>/dev/null || true
    
    log_success "内核模块配置完成"
}

# ===== BDP 缓冲计算：按「区域 RTT × 带宽」算 2×BDP，取代旧的按内存瞎算 =====
# 区域 RTT 预设（ms）——证据实测：跨太平洋 100~170ms、亚洲区域内更低
_BDP_RTT_ASIA=50
_BDP_RTT_TRANSPAC=150
_BDP_FLOOR=$((8 * 1024 * 1024))     # 缓冲下限 8MB
_BDP_CEIL=$((64 * 1024 * 1024))     # 缓冲上限 64MB（研究结论：别盲目 >64MB）

# 取区域 RTT → BDP_RTT_MS。环境变量 AEGIS_RTT_MS 可覆盖；非交互默认跨太平洋
_bdp_prompt_region_rtt() {
    if [[ -n "${AEGIS_RTT_MS:-}" ]]; then
        if [[ "$AEGIS_RTT_MS" =~ ^[0-9]+$ ]] && (( AEGIS_RTT_MS > 0 )); then
            BDP_RTT_MS="$AEGIS_RTT_MS"; return 0
        else
            log_warn "AEGIS_RTT_MS='$AEGIS_RTT_MS' 非正整数，回退默认值 ${_BDP_RTT_TRANSPAC}ms"
            BDP_RTT_MS="$_BDP_RTT_TRANSPAC"; return 0
        fi
    fi
    if [[ ! -t 0 ]]; then BDP_RTT_MS="$_BDP_RTT_TRANSPAC"; return 0; fi
    echo ""
    echo "线路区域（决定 RTT，用于按 BDP 算 TCP 缓冲）:"
    echo "  1) 亚洲近距    (RTT≈${_BDP_RTT_ASIA}ms)"
    echo "  2) 跨太平洋    (RTT≈${_BDP_RTT_TRANSPAC}ms)"
    echo "  3) 自定义实测 RTT"
    read -p "请选择 [1/2/3] (默认 2): " _r
    case "${_r:-2}" in
        1) BDP_RTT_MS="$_BDP_RTT_ASIA" ;;
        2) BDP_RTT_MS="$_BDP_RTT_TRANSPAC" ;;
        3) read -p "输入实测 RTT(ms): " BDP_RTT_MS ;;
        *) BDP_RTT_MS="$_BDP_RTT_TRANSPAC" ;;
    esac
    [[ "$BDP_RTT_MS" =~ ^[0-9]+$ ]] || BDP_RTT_MS="$_BDP_RTT_TRANSPAC"
}

# 取带宽 Mbps → BDP_BW_MBPS。环境变量 AEGIS_BW_MBPS 可覆盖；非交互默认 1000
_bdp_prompt_bandwidth() {
    if [[ -n "${AEGIS_BW_MBPS:-}" ]]; then
        if [[ "$AEGIS_BW_MBPS" =~ ^[0-9]+$ ]] && (( AEGIS_BW_MBPS > 0 )); then
            BDP_BW_MBPS="$AEGIS_BW_MBPS"; return 0
        else
            log_warn "AEGIS_BW_MBPS='$AEGIS_BW_MBPS' 非正整数，回退默认值 1000 Mbps"
            BDP_BW_MBPS=1000; return 0
        fi
    fi
    if [[ ! -t 0 ]]; then BDP_BW_MBPS=1000; return 0; fi
    read -p "端口/线路带宽 (Mbps，默认 1000): " BDP_BW_MBPS
    BDP_BW_MBPS="${BDP_BW_MBPS:-1000}"
    [[ "$BDP_BW_MBPS" =~ ^[0-9]+$ ]] || BDP_BW_MBPS=1000
}

# BDP(bytes)=带宽Mbps×RTTms×125；缓冲=2×BDP，夹 [_BDP_FLOOR, _BDP_CEIL]。回显字节
_bdp_buffer_bytes() {
    local bw="$1" rtt="$2" buf
    buf=$(( bw * rtt * 125 * 2 ))
    (( buf < _BDP_FLOOR )) && buf=$_BDP_FLOOR
    (( buf > _BDP_CEIL )) && buf=$_BDP_CEIL
    echo "$buf"
}

configure_sysctl() {
    _bdp_prompt_region_rtt
    _bdp_prompt_bandwidth
    local _buf _mid _def _buf_mib
    _buf=$(_bdp_buffer_bytes "$BDP_BW_MBPS" "$BDP_RTT_MS")
    _mid=$(( _buf / 4 )); (( _mid < 262144 )) && _mid=262144
    _def=$(( _buf / 8 )); (( _def < 131072 )) && _def=131072
    _buf_mib=$(awk -v v="$_buf" 'BEGIN{printf "%.1f", v/1048576}')
    log_section "配置 BBR + $QDISC_CHOICE  (缓冲=2×BDP: ${BDP_BW_MBPS}Mbps × ${BDP_RTT_MS}ms ≈ ${_buf_mib} MiB)"

    local CONFIG_CONTENT="# ================================================
# AegisTune  BBR + ${QDISC_CHOICE^^}   (纯 BBR + qdisc + BDP 缓冲)
# 生成时间: $(date)
# 缓冲 = 2×BDP (${BDP_BW_MBPS}Mbps × ${BDP_RTT_MS}ms) ≈ ${_buf_mib} MiB
# ================================================
net.core.default_qdisc = $QDISC_CHOICE
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $_buf
net.core.wmem_max = $_buf
net.core.rmem_default = $_def
net.core.wmem_default = $_def
net.ipv4.tcp_rmem = 4096 $_mid $_buf
net.ipv4.tcp_wmem = 4096 $_mid $_buf"

    # 写入 sysctl.d 目录
    mkdir -p /etc/sysctl.d
    echo "$CONFIG_CONTENT" > /etc/sysctl.d/99-bbr-tuning.conf
    
    # Alpine 兼容：同时写入主配置文件（幂等：先删旧标记块再追加新块）
    if [[ "$OS_TYPE" == "alpine" ]]; then
        # 备份原配置
        [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf /etc/sysctl.conf.backup 2>/dev/null || true
        # 删除旧标记块（如存在），保证幂等
        sed -i '/^# === AegisTune BBR BEGIN ===/,/^# === AegisTune BBR END ===/d' /etc/sysctl.conf 2>/dev/null || true
        {
            printf '\n# === AegisTune BBR BEGIN ===\n'
            echo "$CONFIG_CONTENT"
            printf '# === AegisTune BBR END ===\n'
        } >> /etc/sysctl.conf
    fi
    
    # 应用配置 (兼容多种系统)
    sysctl -p /etc/sysctl.d/99-bbr-tuning.conf 2>/dev/null || \
    sysctl -p /etc/sysctl.conf 2>/dev/null || \
    sysctl --system 2>/dev/null || true

    # 强制立即应用两个核心参数：防止 sysctl -p 静默失败导致"写了但没生效"
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.core.default_qdisc="$QDISC_CHOICE" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    # 回读校验：只有内核真正接受 bbr 才报成功，否则给出明确原因
    verify_bbr_effective
}

# 回读内核实际状态，判定 BBR 是否"真正生效"（不是写了文件就算数）
verify_bbr_effective() {
    local cur_cc cur_qdisc avail
    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")

    log_section "BBR 生效校验"
    if [[ "$cur_cc" == "bbr" ]]; then
        log_success "BBR 已真正生效 ✓  (当前拥塞控制: bbr)"
    else
        log_error "BBR 未生效 ✗  当前仍为: ${cur_cc:-未知}"
        if [[ "$avail" != *bbr* ]]; then
            log_warn "内核未提供 BBR (available: ${avail:-未知})。需 Linux ≥ 4.9 且启用 CONFIG_TCP_CONG_BBR，请升级内核后重装。"
        else
            log_warn "内核支持 BBR 但未应用：多为容器/受限环境无内核写权限，或需重启复核。可手动执行 sysctl -w net.ipv4.tcp_congestion_control=bbr。"
        fi
    fi

    if [[ "$cur_qdisc" == "$QDISC_CHOICE" ]]; then
        log_success "队列调度已生效 ✓  (default_qdisc: $cur_qdisc)"
    else
        log_warn "队列调度当前为 ${cur_qdisc:-未知}(期望 $QDISC_CHOICE)。default_qdisc 仅对新建网卡队列生效，已存在网卡需重启或 tc 重挂后切换，非报错。"
    fi
}


# ============ Fail2ban 管理 (SSH 防暴力) ============

# 服务没起来时，别用"状态未知"含糊带过——把真实日志和根因/修复建议摆出来。
fail2ban_report_failure() {
    log_info "服务未 active，诊断信息（最近日志）："
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u fail2ban --no-pager -n 15 2>/dev/null | sed 's/^/    /' || true
    fi
    if [[ -f /var/log/fail2ban.log ]]; then
        tail -n 15 /var/log/fail2ban.log 2>/dev/null | sed 's/^/    /' || true
    fi
    log_info "常见根因与修复："
    log_info "  1) systemd 后端报 'No module named systemd' → 缺 python3-systemd（提供 systemd 模块），装上后 restart：apt/dnf install -y python3-systemd。"
    log_info "  2) 本脚本优先文件后端并确保 rsyslog 产出 /var/log/auth.log；仅纯 journald 无 auth.log 才退 systemd 后端。"
    log_info "  3) fail2ban.service 设了 RestartPreventExitStatus=255，首启失败不自愈 → 修好配置后手动 restart。"
    log_info "  4) 手动排查具体报错: fail2ban-client -x start"
}

# systemd 后端依赖 python3-systemd 提供的 `systemd` 模块；Debian/RHEL 只把它列为 Recommends，
# 精简/cloud 镜像常没装 → fail2ban 报 "No module named 'systemd'"、sshd jail 初始化失败、服务 255 崩。
# 用 systemd 后端前必须补上并真正验证可 import；不可用则由调用方回退文件后端。
ensure_python3_systemd() {
    # 已能导入就不折腾（python3 缺失/导入失败均视为不可用，交调用方回退）
    if python3 -c 'import systemd.journal' >/dev/null 2>&1; then
        return 0
    fi
    case $PKG_MANAGER in
        apt)
            apt-get install -y -qq python3-systemd >/dev/null 2>&1 || true
            ;;
        dnf|yum)
            $PKG_MANAGER install -y python3-systemd >/dev/null 2>&1 || true
            ;;
        *)
            : # 其余(Alpine/OpenRC 等)非 systemd，不该走到这
            ;;
    esac
    python3 -c 'import systemd.journal' >/dev/null 2>&1
}

install_fail2ban_basic() {
    log_section "配置 Fail2ban (SSH 防护)"
    detect_os
    detect_pkg_manager
    local ssh_port
    ssh_port=$(get_ssh_port)

    case $PKG_MANAGER in
        apt)
            apt-get update -qq
            apt-get install -y -qq fail2ban rsyslog 2>/dev/null || true
            ;;
        apk)
            apk add --quiet --no-cache fail2ban rsyslog 2>/dev/null || true
            ;;
        dnf|yum)
            # RHEL/Rocky/Alma/CentOS: fail2ban 在 EPEL 仓库，先确保 EPEL 可用
            if ! rpm -q epel-release >/dev/null 2>&1; then
                $PKG_MANAGER install -y epel-release 2>/dev/null || true
            fi
            $PKG_MANAGER install -y fail2ban 2>/dev/null || true
            $PKG_MANAGER install -y rsyslog 2>/dev/null || true
            ;;
        *)
            log_warn "未识别的包管理器 ($PKG_MANAGER)，请手动安装 fail2ban"
            ;;
    esac

    # 安装未成功则不硬写配置（原逻辑在 RHEL 系装不上却仍写 jail.local，注定失败）
    if [[ ! -d /etc/fail2ban ]]; then
        log_error "Fail2ban 未安装成功（/etc/fail2ban 不存在），已跳过配置。RHEL 系请确认 EPEL 已启用。"
        return 1
    fi

    # 后端自适应：systemd 主机读 journald——cloud/精简镜像用 systemd-journald 且没装 rsyslog，
    # 根本没有 /var/log/auth.log，文件后端会报 "Have not found any log file for sshd jail" 启动失败。
    # 非 systemd（Alpine/OpenRC 等）保持 auto + 文件后端，交给 fail2ban 包内 paths 默认值。
    # 后端选择（文件后端优先·根治"反复踩 systemd 依赖"坑）：
    # 文件后端(读 /var/log/auth.log)零 python 依赖、最稳；脚本已装 rsyslog，绝大多数机器都能产出 auth.log。
    # 只有纯 journald、真没有也产不出 auth.log 的精简云镜像，才退到 systemd 后端(并确保 python3-systemd)。
    # 教训：旧逻辑对 systemd 主机无脑写 backend=systemd → 缺 python3-systemd 就崩，是本坑反复复发的病根。
    local f2b_backend
    local host_mgr
    host_mgr="$(get_service_manager)"
    if [[ "$host_mgr" != "systemd" ]]; then
        # 非 systemd（Alpine/OpenRC 等）：沿用文件后端 + 包内默认 paths（已验证，不动）
        f2b_backend="auto"
    else
        # systemd 主机：先把 rsyslog 拉起来产出 auth.log；有 auth.log/rsyslog 就用零依赖的文件后端
        service_action_any restart rsyslog >/dev/null 2>&1 || service_action_any start rsyslog >/dev/null 2>&1 || true
        # 判「文件后端可用」以 auth.log 已在 / rsyslog 真在跑为准；只有 rsyslogd 二进制存在不算——
        # 装了没跑=文件永远空，fail2ban 能启动却静默零防护(监控一个永不增长的空文件)，比启动失败更坏。
        if [[ -f /var/log/auth.log ]] || service_is_active_any rsyslog; then
            f2b_backend="auto"
            # 仅当 rsyslog 确实活着时才兜底建空 auth.log（它会被喂日志）；否则留空文件会让下次运行误判 + 静默空转。
            if [[ ! -f /var/log/auth.log ]] && service_is_active_any rsyslog; then
                : > /var/log/auth.log 2>/dev/null || true
            fi
        elif ensure_python3_systemd; then
            # 纯 journald、无 auth.log/rsyslog：退到 systemd 后端读 journald
            f2b_backend="systemd"
        else
            # 两条路都不通：仍尽力用文件后端 + 建空 auth.log（比无脑 systemd 更不易崩）
            f2b_backend="auto"
            : > /var/log/auth.log 2>/dev/null || true
            log_warn "无 rsyslog/auth.log 且 python3-systemd 装不上，已尽力用文件后端；若启动失败请手动检查日志来源"
        fi
    fi
    log_info "fail2ban 后端选择: $f2b_backend（文件后端零 python 依赖优先，仅纯 journald 才退 systemd）"

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 30d
findtime = 7d
maxretry = 3
backend = $f2b_backend

[sshd]
enabled = true
port = $ssh_port,22
mode = aggressive
backend = $f2b_backend
EOF

    # 只有文件后端才需要 rsyslog 产出 auth.log；systemd 后端直接读 journald，无需 rsyslog。
    if [[ "$f2b_backend" != "systemd" ]]; then
        service_action_any restart rsyslog || true
        # 回退到文件后端的 systemd 主机：auth.log 可能尚不存在，兜底建空文件，
        # 否则 fail2ban 文件后端会因 "Have not found any log file for sshd jail" 启动失败。
        if [[ "$host_mgr" == "systemd" && ! -f /var/log/auth.log ]]; then
            : > /var/log/auth.log 2>/dev/null || true
        fi
    fi
    service_enable_any fail2ban || true
    service_action_any restart fail2ban || service_action_any start fail2ban || true

    # 落地验证：真查服务是否 active，失败给可诊断原因，不再"状态未知"含糊带过。
    if service_is_active_any fail2ban; then
        if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
            log_success "Fail2ban 已启用并加载 sshd jail (SSH 端口: $ssh_port，后端: $f2b_backend)"
        else
            log_success "Fail2ban 服务已运行 (SSH 端口: $ssh_port，后端: $f2b_backend)"
        fi
    else
        log_error "Fail2ban 启动失败（服务未 active，后端: $f2b_backend）"
        fail2ban_report_failure
        return 1
    fi
}

remove_fail2ban_basic() {
    log_section "停用/移除 Fail2ban"
    service_action_any stop fail2ban || true
    service_disable_any fail2ban || true
    rm -f /etc/fail2ban/jail.local
    log_success "Fail2ban 已停用并移除自定义配置"
}

# ============ Fail2ban 白名单 (ignoreip) 安全管理 ============

# 严格校验 IPv4/IPv6/CIDR；通过 return 0，非法 return 1
fail2ban_validate_ip() {
    local raw="$1"
    local addr prefix

    case "$raw" in
        ""|*" "*|*$'\t'*|*$'\n'*) return 1 ;;
    esac

    if [[ "$raw" == */* ]]; then
        addr="${raw%/*}"
        prefix="${raw#*/}"
        case "$prefix" in
            ""|*[!0-9]*) return 1 ;;
        esac
        # 拒绝前导零以外的异常（纯数字即可，范围稍后判）
        if [[ "$prefix" != "$raw" ]] && [[ "$raw" != */*/* ]]; then
            :
        else
            # 多于一个 /
            [[ "$raw" == */*/* ]] && return 1
        fi
        # 恰好一个 /
        local slash_rest="${raw#*/}"
        [[ "$slash_rest" == */* ]] && return 1
    else
        addr="$raw"
        prefix=""
    fi

    [[ -n "$addr" ]] || return 1

    # IPv4
    if [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local a="${BASH_REMATCH[1]}"
        local b="${BASH_REMATCH[2]}"
        local c="${BASH_REMATCH[3]}"
        local d="${BASH_REMATCH[4]}"
        if (( 10#$a > 255 || 10#$b > 255 || 10#$c > 255 || 10#$d > 255 )); then
            return 1
        fi
        if [[ -n "$prefix" ]] && (( 10#$prefix > 32 )); then
            return 1
        fi
        return 0
    fi

    # IPv6：仅允许 hex 与冒号，且至少一个冒号
    case "$addr" in
        *[!0-9A-Fa-f:]* ) return 1 ;;
    esac
    [[ "$addr" == *:* ]] || return 1
    # 三个及以上连续冒号是畸形 IPv6，直接拒
    case "$addr" in *:::*) return 1 ;; esac

    # 至多一处 ::
    local dc=0
    local rest="$addr"
    while [[ "$rest" == *::* ]]; do
        dc=$((dc + 1))
        rest="${rest#*::}"
    done
    if (( dc > 1 )); then
        return 1
    fi

    local parts
    IFS=':' read -ra parts <<< "$addr"
    local p groups=0
    for p in "${parts[@]}"; do
        if [[ -z "$p" ]]; then
            continue
        fi
        case "$p" in
            [0-9A-Fa-f]|\
            [0-9A-Fa-f][0-9A-Fa-f]|\
            [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]|\
            [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
                groups=$((groups + 1))
                ;;
            *)
                return 1
                ;;
        esac
    done

    if (( dc == 0 )); then
        # 无压缩：必须恰好 8 组且均非空
        if (( ${#parts[@]} != 8 )); then
            return 1
        fi
        for p in "${parts[@]}"; do
            [[ -n "$p" ]] || return 1
        done
    else
        # 有 ::：非空组至多 7
        if (( groups > 7 )); then
            return 1
        fi
    fi

    if [[ -n "$prefix" ]] && (( 10#$prefix > 128 )); then
        return 1
    fi
    return 0
}

# 读取 jail.local [DEFAULT] 段中 ignoreip 的值部分（可能为空）
fail2ban_read_ignoreip() {
    local f="${1:-/etc/fail2ban/jail.local}"
    [[ -f "$f" ]] || { echo ""; return 0; }
    awk '
        /^\[DEFAULT\]/ { in_def=1; next }
        /^\[/ { in_def=0 }
        in_def && /^[[:space:]]*ignoreip[[:space:]]*=/ {
            sub(/^[[:space:]]*ignoreip[[:space:]]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$f"
}

# 判断 token 是否已在忽略列表中（精确匹配）
fail2ban_ignoreip_has() {
    local needle="$1"
    local hay="$2"
    local tok
    for tok in $hay; do
        [[ "$tok" == "$needle" ]] && return 0
    done
    return 1
}

# 备份 jail.local，成功时把路径 echo 到 stdout（调用方用 $() 捕获；失败勿在此 log，避免污染 stdout）
fail2ban_backup_jail_local() {
    local src="/etc/fail2ban/jail.local"
    local bak="/etc/fail2ban/jail.local.bak.$(date +%s)"
    cp "$src" "$bak" || return 1
    echo "$bak"
}

# 清理多余 .bak，仅保留最新 1 个（本功能前缀）
fail2ban_cleanup_jail_backups() {
    local f
    # shellcheck disable=SC2012
    ls -1t /etc/fail2ban/jail.local.bak.* 2>/dev/null | tail -n +2 | while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f" 2>/dev/null || true
    done || true
}

# 用 awk 安全重写 [DEFAULT] 唯一 ignoreip 行：action=add|remove，target=IP
# 绝不新增第二行 ignoreip
fail2ban_rewrite_ignoreip() {
    local action="$1"
    local target="$2"
    local src="/etc/fail2ban/jail.local"
    local tmp

    tmp=$(mktemp 2>/dev/null || echo "/tmp/jail.local.$$")
    if ! awk -v action="$action" -v target="$target" '
        BEGIN { in_def=0; done_line=0 }
        /^\[DEFAULT\]/ {
            in_def=1
            print
            next
        }
        /^\[/ {
            if (in_def && !done_line) {
                if (action == "add") {
                    print "ignoreip = 127.0.0.1/8 ::1 " target
                }
                done_line=1
            }
            in_def=0
            print
            next
        }
        in_def && /^[[:space:]]*ignoreip[[:space:]]*=/ {
            line=$0
            sub(/^[[:space:]]*ignoreip[[:space:]]*=[[:space:]]*/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            n=split(line, arr, /[[:space:]]+/)
            out=""
            if (action == "add") {
                out=line
                if (out != "") out=out " "
                out=out target
                print "ignoreip = " out
            } else {
                # remove: 重建，跳过 target
                for (i=1; i<=n; i++) {
                    if (arr[i] == "" || arr[i] == target) continue
                    if (out != "") out=out " "
                    out=out arr[i]
                }
                if (out == "") out="127.0.0.1/8 ::1"
                print "ignoreip = " out
            }
            done_line=1
            next
        }
        { print }
        END {
            if (in_def && !done_line) {
                if (action == "add") {
                    print "ignoreip = 127.0.0.1/8 ::1 " target
                }
            }
        }
    ' "$src" > "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "重写 jail.local ignoreip 失败"
        return 1
    fi

    if ! mv -f "$tmp" "$src"; then
        rm -f "$tmp" 2>/dev/null || true
        log_error "原子替换 jail.local 失败"
        return 1
    fi
    return 0
}

fail2ban_whitelist_view() {
    log_section "Fail2ban 白名单 (ignoreip)"
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        log_warn "未找到 /etc/fail2ban/jail.local，请先用安全菜单第 1 项启用 Fail2ban"
        return 0
    fi

    local conf_val
    conf_val=$(fail2ban_read_ignoreip)
    echo -e "${CYAN}--- 配置文件 jail.local [DEFAULT] ignoreip ---${NC}"
    if [[ -z "$conf_val" ]]; then
        echo "  (无 ignoreip 行)"
    else
        local tok i=0
        for tok in $conf_val; do
            i=$((i + 1))
            echo "  $i) $tok"
        done
        echo -e "${CYAN}当前条目数: ${i}${NC}"
    fi

    echo ""
    echo -e "${CYAN}--- 运行期 fail2ban-client get sshd ignoreip ---${NC}"
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client get sshd ignoreip 2>/dev/null || log_warn "无法获取运行期 ignoreip（服务未运行或 jail 未加载）"
    else
        log_warn "未检测到 fail2ban-client"
    fi
}

fail2ban_whitelist_add() {
    log_section "Fail2ban 加白名单 (ignoreip)"
    local ip="${1:-}"

    if ! command -v fail2ban-client >/dev/null 2>&1 || [[ ! -f /etc/fail2ban/jail.local ]]; then
        log_warn "请先用安全菜单第 1 项启用 Fail2ban"
        return 1
    fi

    if [[ -z "$ip" ]]; then
        read -p "请输入要加入白名单的 IP/CIDR: " ip
    fi
    ip=$(echo "$ip" | awk '{print $1}')
    if ! fail2ban_validate_ip "$ip"; then
        log_error "非法 IP/CIDR: ${ip:-<空>}（仅接受 IPv4/IPv6，可带 /前缀）"
        return 1
    fi

    local current
    current=$(fail2ban_read_ignoreip)
    if fail2ban_ignoreip_has "$ip" "$current"; then
        log_info "IP 已在白名单中，无需重复添加: $ip"
        return 0
    fi

    local bak
    if ! bak=$(fail2ban_backup_jail_local); then
        log_error "备份 jail.local 失败"
        return 1
    fi
    log_info "已备份: $bak"

    if ! fail2ban_rewrite_ignoreip add "$ip"; then
        log_error "写入 ignoreip 失败，原配置未改动（备份: $bak）"
        return 1
    fi

    # 配置校验：失败则回滚，绝不让坏配置进服务
    if ! fail2ban-client -t >/dev/null 2>&1; then
        if cp "$bak" /etc/fail2ban/jail.local 2>/dev/null; then
            log_error "配置校验失败已回滚，服务未受影响（fail2ban-client -t 未通过）"
        else
            log_error "配置校验失败且回滚复制失败，请手动恢复: $bak"
        fi
        return 1
    fi

    # 运行期生效：优先 live set，避开 RestartPreventExitStatus=255 焊死陷阱
    if service_is_active_any fail2ban; then
        fail2ban-client set sshd addignoreip "$ip" >/dev/null 2>&1 || \
            service_action_any reload fail2ban || service_action_any restart fail2ban || true
    else
        service_action_any reload fail2ban || service_action_any restart fail2ban || true
    fi

    local new_val ok=1
    new_val=$(fail2ban_read_ignoreip)
    if ! fail2ban_ignoreip_has "$ip" "$new_val"; then
        ok=0
    fi
    if ! service_is_active_any fail2ban; then
        ok=0
    fi

    if (( ok == 1 )); then
        log_success "已加入白名单: $ip"
        log_info "当前白名单: $new_val"
        fail2ban_cleanup_jail_backups
        return 0
    fi

    log_error "落地验证失败，请检查: fail2ban-client -t 与 service 状态"
    log_info "备份仍在: $bak"
    return 1
}

fail2ban_whitelist_remove() {
    log_section "Fail2ban 移除白名单 (ignoreip)"
    local ip="${1:-}"

    if ! command -v fail2ban-client >/dev/null 2>&1 || [[ ! -f /etc/fail2ban/jail.local ]]; then
        log_warn "请先用安全菜单第 1 项启用 Fail2ban"
        return 1
    fi

    local current
    current=$(fail2ban_read_ignoreip)
    if [[ -z "$current" ]]; then
        log_warn "当前无 ignoreip 条目"
        return 0
    fi

    echo -e "${CYAN}当前白名单:${NC}"
    local tok i=0
    for tok in $current; do
        i=$((i + 1))
        echo "  $i) $tok"
    done

    if [[ -z "$ip" ]]; then
        read -p "请输入要移除的 IP/CIDR（或序号）: " ip
    fi
    ip=$(echo "$ip" | awk '{print $1}')

    # 支持按序号选择
    if [[ "$ip" =~ ^[0-9]+$ ]]; then
        local idx=0 pick=""
        for tok in $current; do
            idx=$((idx + 1))
            if (( idx == 10#$ip )); then
                pick="$tok"
                break
            fi
        done
        if [[ -z "$pick" ]]; then
            log_error "无效序号: $ip"
            return 1
        fi
        ip="$pick"
    fi

    if ! fail2ban_validate_ip "$ip"; then
        log_error "非法 IP/CIDR: ${ip:-<空>}"
        return 1
    fi

    # 内置回环禁止删除
    if [[ "$ip" == "127.0.0.1/8" || "$ip" == "::1" || "$ip" == "127.0.0.1" ]]; then
        log_warn "禁止移除内置回环地址 ($ip)，否则本机可能被自己封禁"
        return 1
    fi

    if ! fail2ban_ignoreip_has "$ip" "$current"; then
        log_info "白名单中不存在: $ip"
        return 0
    fi

    local bak
    if ! bak=$(fail2ban_backup_jail_local); then
        log_error "备份 jail.local 失败"
        return 1
    fi
    log_info "已备份: $bak"

    if ! fail2ban_rewrite_ignoreip remove "$ip"; then
        log_error "写入 ignoreip 失败，原配置未改动（备份: $bak）"
        return 1
    fi

    if ! fail2ban-client -t >/dev/null 2>&1; then
        if cp "$bak" /etc/fail2ban/jail.local 2>/dev/null; then
            log_error "配置校验失败已回滚，服务未受影响（fail2ban-client -t 未通过）"
        else
            log_error "配置校验失败且回滚复制失败，请手动恢复: $bak"
        fi
        return 1
    fi

    if service_is_active_any fail2ban; then
        fail2ban-client set sshd delignoreip "$ip" >/dev/null 2>&1 || \
            service_action_any reload fail2ban || service_action_any restart fail2ban || true
    else
        service_action_any reload fail2ban || service_action_any restart fail2ban || true
    fi

    local new_val ok=1
    new_val=$(fail2ban_read_ignoreip)
    if fail2ban_ignoreip_has "$ip" "$new_val"; then
        ok=0
    fi

    if (( ok == 1 )); then
        log_success "已移除白名单: $ip"
        log_info "当前白名单: $new_val"
        fail2ban_cleanup_jail_backups
        return 0
    fi

    log_error "落地验证失败，请检查: fail2ban-client -t 与 service 状态"
    log_info "备份仍在: $bak"
    return 1
}

fail2ban_whitelist_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${CYAN}║       Fail2ban 白名单 (ignoreip)             ║${NC}"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}  1) 查看白名单${NC}"
        echo -e "  2) 加白名单"
        echo -e "  3) 移除白名单"
        echo -e "  0) 返回"
        echo ""
        read -p "请输入选择 [0-3]: " wl_choice
        case "$wl_choice" in
            1) fail2ban_whitelist_view; pause_return_main_menu ;;
            2) fail2ban_whitelist_add; pause_return_main_menu ;;
            3) fail2ban_whitelist_remove; pause_return_main_menu ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============ Swap 管理 ============

smart_swap_size_mb() {
    local mem_mb disk_free_mb rec cap
    mem_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [[ "$mem_mb" =~ ^[0-9]+$ ]] || mem_mb=1024
    if   (( mem_mb < 512 ));  then rec=1024
    elif (( mem_mb < 1024 )); then rec=$(( mem_mb * 2 ))
    elif (( mem_mb < 2048 )); then rec=$(( mem_mb * 3 / 2 ))
    elif (( mem_mb < 4096 )); then rec=$mem_mb
    else rec=4096; fi
    disk_free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$disk_free_mb" =~ ^[0-9]+$ ]] || disk_free_mb=0
    cap=$(( disk_free_mb / 2 ))           # swap 不超过可用磁盘的 50%（防撑盘）
    (( cap > 0 && rec > cap )) && rec=$cap
    (( rec < 256 )) && rec=256
    echo "$rec"
}

swap_create() {
    log_section "创建 Swap"

    # 检测已有 swap（读 /proc/swaps，兼容 busybox/Alpine，避免 swapon --show 不可用）
    local existing_swap
    existing_swap=$(grep -v '^Filename' /proc/swaps 2>/dev/null)
    if [[ -n "$existing_swap" ]]; then
        log_info "检测到已有 Swap:"
        echo "$existing_swap"
        echo ""
        # 检查是否含非 /swapfile 的 swap（如分区 swap）
        local non_swapfile
        non_swapfile=$(echo "$existing_swap" | awk '{print $1}' | grep -v '^/swapfile$' || true)
        if [[ -n "$non_swapfile" ]]; then
            log_warn "注意: 检测到本工具不管理的 swap 项（如分区 swap）:"
            echo "$non_swapfile"
            log_warn "本工具只管理 /swapfile，上述 swap 将保持不动，不会被替换。"
            echo ""
        fi
        read -r -p "是否替换 /swapfile？[y/N]: " replace_choice
        if [[ "${replace_choice,,}" != "y" ]]; then
            log_info "已跳过 Swap 创建"
            return 0
        fi
    fi

    # 推荐大小，输入校验（非法重试，最多 3 次；回车使用推荐值）
    local rec_mb swap_size
    rec_mb=$(smart_swap_size_mb)
    log_info "推荐 Swap 大小: ${rec_mb}MB（基于内存和磁盘余量）"
    local input_attempts=0
    while true; do
        read -r -p "请输入 Swap 大小 (MB，回车使用推荐值 ${rec_mb}): " swap_size
        [[ -z "$swap_size" ]] && swap_size=$rec_mb
        if [[ "$swap_size" =~ ^[0-9]+$ ]] && (( swap_size >= 256 )); then
            break
        fi
        input_attempts=$(( input_attempts + 1 ))
        if (( input_attempts >= 3 )); then
            log_error "输入无效次数过多，已中止"
            return 1
        fi
        log_error "无效大小: ${swap_size}，最小 256MB，请重新输入"
    done

    # 磁盘余量护栏
    local disk_free_mb
    disk_free_mb=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
    [[ "$disk_free_mb" =~ ^[0-9]+$ ]] || disk_free_mb=0
    local needed=$(( swap_size + 64 ))
    if (( disk_free_mb < needed )); then
        log_error "磁盘剩余 ${disk_free_mb}MB 不足（需要 ${needed}MB），中止创建"
        return 1
    fi

    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile

    if ! fallocate -l ${swap_size}M /swapfile 2>/dev/null; then
        log_info "fallocate 不可用，回退到 dd..."
        if ! dd if=/dev/zero of=/swapfile bs=1M count=${swap_size} 2>/dev/null; then
            log_error "Swap 文件创建失败"
            rm -f /swapfile
            return 1
        fi
    fi
    chmod 600 /swapfile
    if ! mkswap /swapfile; then
        log_error "mkswap 失败，Swap 创建中止"
        rm -f /swapfile
        return 1
    fi
    if ! swapon /swapfile; then
        log_error "swapon 失败，Swap 创建中止"
        rm -f /swapfile
        return 1
    fi

    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi

    # 设置 swappiness
    local mem_mb
    mem_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [[ "$mem_mb" =~ ^[0-9]+$ ]] || mem_mb=2048
    local swappiness=10
    (( mem_mb < 2048 )) && swappiness=20
    sysctl -w vm.swappiness=$swappiness >/dev/null 2>&1 || true
    if grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^vm.swappiness.*/vm.swappiness = $swappiness/" /etc/sysctl.conf
    else
        echo "vm.swappiness = $swappiness" >> /etc/sysctl.conf
    fi

    log_success "Swap 已创建并启用: ${swap_size}MB (swappiness=${swappiness})"
}

swap_delete() {
    log_section "删除 Swap"
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '/\/swapfile/d' /etc/fstab
    log_success "Swap 已删除"
}

swap_set_swappiness() {
    log_section "调整 vm.swappiness"
    local new_val input_attempts=0
    while true; do
        read -p "请输入 swappiness (0-100，回车使用默认值 60): " new_val
        [[ -z "$new_val" ]] && new_val=60
        if [[ "$new_val" =~ ^[0-9]+$ ]] && (( new_val >= 0 && new_val <= 100 )); then
            break
        fi
        input_attempts=$(( input_attempts + 1 ))
        if (( input_attempts >= 3 )); then
            log_error "输入无效次数过多，已中止"
            return 1
        fi
        log_error "无效值: ${new_val}，请输入 0-100 之间的整数"
    done
    sysctl -w vm.swappiness=$new_val >/dev/null
    if grep -q "vm.swappiness" /etc/sysctl.conf; then
        sed -i "s/^vm.swappiness.*/vm.swappiness = $new_val/" /etc/sysctl.conf
    else
        echo "vm.swappiness = $new_val" >> /etc/sysctl.conf
    fi
    log_success "已设置 vm.swappiness=$new_val"
}

swap_menu() {
    log_section "Swap 管理"
    echo "1) 创建/重建 Swap"
    echo "2) 删除 Swap"
    echo "3) 设置 swappiness"
    echo "0) 返回上层菜单"
    read -p "请选择 [1-3/0]: " swap_choice
    case $swap_choice in
        1) swap_create ;;
        2) swap_delete ;;
        3) swap_set_swappiness ;;
        0) return 0 ;;
        *) log_warn "无效选择" ;;
    esac
}

has_docker_compose_plugin() {
    docker compose version >/dev/null 2>&1
}

has_docker_compose_legacy() {
    command -v docker-compose >/dev/null 2>&1
}

get_docker_compose_status_text() {
    local version_text=""
    if has_docker_compose_plugin; then
        version_text=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null | head -1)
        echo "Docker Compose: 已安装 (plugin ${version_text:-ok})"
    elif has_docker_compose_legacy; then
        version_text=$(docker-compose version --short 2>/dev/null || docker-compose version 2>/dev/null | head -1)
        echo "Docker Compose: 已安装 (legacy ${version_text:-ok})"
    else
        echo "Docker Compose: 未安装"
    fi
}

is_frps_installed() {
    command -v frps >/dev/null 2>&1 || \
    [[ -x /usr/local/bin/frps ]] || \
    [[ -x /usr/bin/frps ]] || \
    [[ -f /etc/systemd/system/frps.service ]] || \
    [[ -f /lib/systemd/system/frps.service ]] || \
    [[ -f /etc/init.d/frps ]]
}

is_frps_running() {
    service_is_active_any frps || pgrep -x frps >/dev/null 2>&1
}

get_frps_status_text() {
    if is_frps_installed; then
        if is_frps_running; then
            echo "FRPS: 已安装并运行中"
        else
            echo "FRPS: 已安装但未运行"
        fi
    else
        echo "FRPS: 未安装"
    fi
}

ensure_docker_compose_repo_apt() {
    local repo_os codename arch
    repo_os="$OS_TYPE"
    [[ "$repo_os" == "debian" || "$repo_os" == "ubuntu" ]] || repo_os="debian"

    arch=$(dpkg --print-architecture 2>/dev/null || echo "")
    codename=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    [[ -n "$codename" ]] || codename=$(lsb_release -cs 2>/dev/null || echo "")

    if [[ -z "$arch" || -z "$codename" ]]; then
        log_error "无法识别 Debian/Ubuntu 架构或发行代号，无法配置 Docker 仓库"
        return 1
    fi

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        download_file "https://download.docker.com/linux/${repo_os}/gpg" "/etc/apt/keyrings/docker.asc" || return 1
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_os} ${codename} stable
EOF
    apt-get update -qq
}

ensure_docker_compose_repo_rpm() {
    cat > /etc/yum.repos.d/docker-ce.repo <<'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF

    case $PKG_MANAGER in
        dnf) dnf makecache -q ;;
        yum) yum makecache -q ;;
    esac
}

get_compose_plugin_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv7) echo "armv7" ;;
        armv6l|armv6) echo "armv6" ;;
        ppc64le) echo "ppc64le" ;;
        s390x) echo "s390x" ;;
        *)
            return 1
            ;;
    esac
}

install_docker_compose_manual_fallback() {
    local arch plugin_dir plugin_path
    arch=$(get_compose_plugin_arch) || {
        log_error "未支持的架构: $(uname -m)"
        return 1
    }

    if ! command -v docker >/dev/null 2>&1; then
        log_error "缺少 docker CLI，无法使用手动插件兜底安装"
        return 1
    fi

    plugin_dir="/usr/local/lib/docker/cli-plugins"
    plugin_path="${plugin_dir}/docker-compose"
    mkdir -p "$plugin_dir"

    if ! download_file "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" "$plugin_path"; then
        log_error "手动下载 Docker Compose 插件失败"
        rm -f "$plugin_path"
        return 1
    fi

    chmod +x "$plugin_path"
}

# 裸机可能根本没有 docker 本体；Compose 是 docker 的子命令/插件，没有 docker 无从谈起。
# 现代 docker 官方一键脚本(get.docker.com)自带 compose 插件，一步到位。
ensure_docker_installed() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi

    log_warn "未检测到 Docker 本体，Compose 依赖 Docker，先安装 Docker"

    case $PKG_MANAGER in
        apk)
            # get.docker.com 不支持 Alpine，走官方仓库包（docker-cli-compose 即 compose 插件）
            apk add --quiet --no-cache docker docker-cli docker-cli-compose >/dev/null 2>&1 || \
            apk add --quiet --no-cache docker docker-compose >/dev/null 2>&1 || true
            ;;
        apt|dnf|yum)
            local get_docker="/tmp/get-docker.sh"
            log_warn "即将执行 Docker 官方安装脚本: https://get.docker.com"
            if download_file "https://get.docker.com" "$get_docker"; then
                sh "$get_docker" >/dev/null 2>&1 || sh "$get_docker" || true
                rm -f "$get_docker"
            else
                log_warn "下载 Docker 官方脚本失败，尝试包管理器直装"
                case $PKG_MANAGER in
                    apt)  apt-get install -y -qq docker.io >/dev/null 2>&1 || true ;;
                    dnf|yum)
                        $PKG_MANAGER install -y -q docker >/dev/null 2>&1 || \
                        $PKG_MANAGER install -y -q docker-ce >/dev/null 2>&1 || true
                        ;;
                esac
            fi
            ;;
        *)
            log_error "未识别的包管理器 ($PKG_MANAGER)，无法自动安装 Docker，请先手动安装 Docker 再重试"
            return 1
            ;;
    esac

    # 装完把 docker 守护进程拉起来（compose 运行需要 daemon）
    service_enable_any docker >/dev/null 2>&1 || true
    service_action_any start docker >/dev/null 2>&1 || true

    if command -v docker >/dev/null 2>&1; then
        log_success "Docker 已安装 ($(docker --version 2>/dev/null || echo ok))"
        return 0
    fi

    log_error "Docker 自动安装失败，请手动安装后重试（参考 https://get.docker.com）"
    return 1
}

install_docker_compose_tool() {
    log_section "快速补全缺失工具: Docker Compose"
    detect_os
    detect_pkg_manager

    if has_docker_compose_plugin || has_docker_compose_legacy; then
        log_success "$(get_docker_compose_status_text)"
        return 0
    fi

    # 裸机无 docker：先装 docker 本体（官方脚本通常已带 compose 插件，装完直接复检）
    if ! command -v docker >/dev/null 2>&1; then
        ensure_docker_installed || return 1
        if has_docker_compose_plugin || has_docker_compose_legacy; then
            log_success "$(get_docker_compose_status_text)"
            return 0
        fi
    fi

    update_pkg_cache
    install_dependencies

    case $PKG_MANAGER in
        apt)
            if ! apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1; then
                log_info "当前仓库未提供 docker-compose-plugin，尝试接入 Docker 官方仓库"
                ensure_docker_compose_repo_apt || true
                apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || \
                apt-get install -y -qq docker-ce-cli docker-compose-plugin >/dev/null 2>&1 || true
            fi
            ;;
        apk)
            apk add --quiet docker-cli docker-cli-compose >/dev/null 2>&1 || \
            apk add --quiet docker-compose >/dev/null 2>&1 || true
            ;;
        dnf|yum)
            if ! $PKG_MANAGER install -y -q docker-compose-plugin >/dev/null 2>&1; then
                log_info "当前仓库未提供 docker-compose-plugin，尝试接入 Docker 官方仓库"
                ensure_docker_compose_repo_rpm || true
                $PKG_MANAGER install -y -q docker-compose-plugin >/dev/null 2>&1 || \
                $PKG_MANAGER install -y -q docker-ce-cli docker-compose-plugin >/dev/null 2>&1 || true
            fi
            ;;
    esac

    if ! has_docker_compose_plugin; then
        log_warn "包管理器安装未成功，尝试手动插件兜底"
        install_docker_compose_manual_fallback || true
    fi

    if has_docker_compose_plugin; then
        log_success "$(get_docker_compose_status_text)"
    else
        log_error "Docker Compose 安装失败"
        return 1
    fi
}

run_frps_helper() {
    local action="$1"
    local helper_script="/tmp/install-frps.sh"
    local helper_url="https://raw.githubusercontent.com/MvsCode/frps-onekey/master/install-frps.sh"

    detect_os
    detect_pkg_manager
    update_pkg_cache
    install_dependencies

    log_warn "即将执行第三方脚本: ${helper_url}"
    if ! download_file "$helper_url" "$helper_script"; then
        log_error "下载 FRPS 一键脚本失败"
        return 1
    fi

    chmod 700 "$helper_script"
    bash "$helper_script" "$action"
    local rc=$?
    rm -f "$helper_script"
    return $rc
}

install_frps_onekey() {
    log_section "快速补全缺失工具: FRPS"

    if is_frps_installed; then
        log_info "$(get_frps_status_text)"
        read -p "FRPS 已存在，是否继续执行第三方安装脚本覆盖/修复? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    fi

    run_frps_helper install || {
        log_error "FRPS 安装脚本执行失败"
        return 1
    }

    if is_frps_installed; then
        log_success "$(get_frps_status_text)"
    else
        log_warn "FRPS 脚本已执行，请根据输出确认安装结果"
    fi
}

uninstall_frps_onekey() {
    log_section "卸载 FRPS"
    run_frps_helper uninstall || {
        log_error "FRPS 卸载脚本执行失败"
        return 1
    }

    if is_frps_installed; then
        log_warn "FRPS 可能仍有残留，请手动检查"
    else
        log_success "FRPS 卸载完成"
    fi
}

show_tools_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
        printf "%b\n" "${CYAN}║        快速补全缺失工具 (Docker Compose / FRPS)             ║"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}$(get_docker_compose_status_text)${NC}"
        echo -e "${CYAN}$(get_frps_status_text)${NC}"
        echo ""
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
        printf "%b\n" "${CYAN}║     1) 查看工具状态                                          ║"
        printf "%b\n" "${CYAN}║     2) 安装 Docker Compose                                   ║"
        printf "%b\n" "${CYAN}║     3) 安装 FRPS 一键脚本                                    ║"
        printf "%b\n" "${CYAN}║     4) 卸载 FRPS                                             ║"
        printf "%b\n" "${CYAN}║     0) 返回主菜单                                            ║"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

        read -p "请输入选择 [0-4]: " tools_choice
        case $tools_choice in
            1)
                pause_return_main_menu
                return 0
                ;;
            2)
                install_docker_compose_tool
                pause_return_main_menu
                return 0
                ;;
            3)
                install_frps_onekey
                pause_return_main_menu
                return 0
                ;;
            4)
                uninstall_frps_onekey
                pause_return_main_menu
                return 0
                ;;
            0)
                return 0
                ;;
            *)
                log_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ============ 系统重装 (DD / 容器) — 第三方官方脚本跳转，不移植逻辑 ============
# DD 网络重装(KVM/Xen/独服): leitbogioro InstallNET.sh —— 不支持 OpenVZ/LXC
# 容器重装(OpenVZ7/LXC):     LloydAsp OsMutation.sh   —— 不支持 KVM、不支持 OpenVZ6
# 两者互斥，菜单帮用户按虚拟化类型分流。

VIRT_TYPE="unknown"
VIRT_IS_CONTAINER=0

detect_virt() {
    VIRT_TYPE="unknown"; VIRT_IS_CONTAINER=0
    local v=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt 2>/dev/null || true)
    fi
    case "$v" in
        openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|rkt|wsl|proot|pouch|container-other)
            VIRT_TYPE="$v"; VIRT_IS_CONTAINER=1 ;;
        kvm|qemu|xen|vmware|microsoft|oracle|parallels|bochs|bhyve|amazon|zvm|uml|apple)
            VIRT_TYPE="$v"; VIRT_IS_CONTAINER=0 ;;
        none|"")
            VIRT_TYPE="none"; VIRT_IS_CONTAINER=0 ;;
        *container*)
            VIRT_TYPE="$v"; VIRT_IS_CONTAINER=1 ;;
        *)
            VIRT_TYPE="$v"; VIRT_IS_CONTAINER=0 ;;
    esac
    # 兜底：systemd-detect-virt 缺失或报 none 时，靠内核暴露面二次判容器
    if [[ $VIRT_IS_CONTAINER -eq 0 ]]; then
        if [[ -f /proc/user_beancounters ]]; then
            VIRT_TYPE="openvz"; VIRT_IS_CONTAINER=1
        elif grep -qaE '[:/](lxc|docker)' /proc/1/cgroup 2>/dev/null; then
            VIRT_TYPE="lxc/container"; VIRT_IS_CONTAINER=1
        fi
    fi
}

reinstall_recommend_line() {
    detect_virt
    if [[ $VIRT_IS_CONTAINER -eq 1 ]]; then
        echo -e "  本机虚拟化: ${YELLOW}${VIRT_TYPE}${NC} (容器) → 推荐【容器重装 OsMutation】，InstallNET 不支持容器"
    elif [[ "$VIRT_TYPE" == "none" ]]; then
        echo -e "  本机虚拟化: ${YELLOW}物理机/未识别${NC} → 一般走【DD 网络重装】，请自行确认架构"
    else
        echo -e "  本机虚拟化: ${GREEN}${VIRT_TYPE}${NC} (非容器) → 推荐【DD 网络重装 InstallNET】"
    fi
}

reinstall_danger_banner() {
    echo ""
    printf "%b\n" "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${RED}║  ⚠ 高危：系统重装会彻底擦除本服务器全部数据并重装系统！     ║${NC}"
    printf "%b\n" "${RED}║  ⚠ 不可逆、本地快照救不了。务必先把数据备份到机器之外。      ║${NC}"
    printf "%b\n" "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

reinstall_typed_confirm() {
    local ans
    echo -e "${RED}若确认重装，请完整输入大写 REINSTALL 继续（其它任何输入都会取消）：${NC}"
    read -p "> " ans
    [[ "$ans" == "REINSTALL" ]]
}

# 交互收集 InstallNET 参数：结果写全局 DD_ARGS(数组) + DD_CMD_PREVIEW(预览串)
DD_ARGS=()
DD_CMD_PREVIEW=""
dd_collect_params() {
    DD_ARGS=(); DD_CMD_PREVIEW=""
    echo ""
    echo "选择要重装成的系统："
    echo "  1) Debian 12        2) Debian 11"
    echo "  3) Ubuntu 22.04     4) Ubuntu 20.04"
    echo "  5) CentOS 9         6) Rocky Linux 9"
    echo "  7) AlmaLinux 9      8) Alpine (edge)"
    echo "  9) 自定义 InstallNET 参数（高级，自己负责）"
    read -p "请输入选择 [1-9]: " os_c
    local distro=()
    case "$os_c" in
        1) distro=(-debian 12) ;;
        2) distro=(-debian 11) ;;
        3) distro=(-ubuntu jammy) ;;
        4) distro=(-ubuntu focal) ;;
        5) distro=(-centos 9) ;;
        6) distro=(-rockylinux 9) ;;
        7) distro=(-almalinux 9) ;;
        8) distro=(-alpine) ;;
        9)
            local custom
            read -p "输入完整 InstallNET 参数(如 -debian 12 -pwd xxx -port 22): " custom
            [[ -z "$custom" ]] && { log_error "参数为空，取消"; return 1; }
            # shellcheck disable=SC2206
            DD_ARGS=($custom)
            DD_CMD_PREVIEW="bash InstallNET.sh $custom"
            return 0
            ;;
        *) log_error "无效选择"; return 1 ;;
    esac

    local pwd_in port_in
    read -p "设置重装后 root 密码 (留空用脚本默认 LeitboGi0ro): " pwd_in
    read -p "设置 SSH 端口 (留空默认 22): " port_in

    DD_ARGS=("${distro[@]}")
    local preview="bash InstallNET.sh ${distro[*]}"
    if [[ -n "$pwd_in" ]]; then
        DD_ARGS+=(-pwd "$pwd_in"); preview+=" -pwd '${pwd_in}'"
    fi
    if [[ -n "$port_in" ]]; then
        DD_ARGS+=(-port "$port_in"); preview+=" -port ${port_in}"
    fi
    DD_CMD_PREVIEW="$preview"
    return 0
}

# mode = exec | print
run_dd_reinstall() {
    local mode="${1:-exec}"
    log_section "DD 网络重装 (KVM/Xen/独服 · InstallNET.sh)"
    echo -e "  第三方官方脚本来源: ${CYAN}${INSTALLNET_URL}${NC}"
    reinstall_recommend_line
    if [[ $VIRT_IS_CONTAINER -eq 1 ]]; then
        log_error "检测到本机是容器(${VIRT_TYPE})，InstallNET 官方声明【不支持 OpenVZ/LXC】，装了也跑不动。"
        if [[ "$mode" != "print" ]]; then
            local f
            read -p "仍要强行继续 DD? 容器请改用【容器重装】 [y/N]: " f
            [[ "$f" =~ ^[Yy]$ ]] || return 0
        fi
    fi

    dd_collect_params || return 1

    echo ""
    echo -e "将执行的命令："
    echo -e "  ${GREEN}${DD_CMD_PREVIEW}${NC}"

    if [[ "$mode" == "print" ]]; then
        echo ""
        echo -e "${YELLOW}[只打印模式] 已按你的选择拼好官方命令，复制到目标机执行即可（脚本不会替你按下执行）。${NC}"
        echo -e "获取+执行一条龙："
        echo -e "  ${CYAN}wget --no-check-certificate -qO InstallNET.sh '${INSTALLNET_URL}' && chmod a+x InstallNET.sh && ${DD_CMD_PREVIEW}${NC}"
        return 0
    fi

    reinstall_danger_banner
    reinstall_typed_confirm || { log_info "已取消，未做任何改动。"; return 0; }

    local script="/tmp/InstallNET.sh"
    log_warn "正在下载官方 InstallNET.sh ..."
    if ! download_file "$INSTALLNET_URL" "$script"; then
        log_error "下载失败。可手动执行："
        echo "  wget --no-check-certificate -qO InstallNET.sh '${INSTALLNET_URL}' && chmod a+x InstallNET.sh && ${DD_CMD_PREVIEW}"
        return 1
    fi
    chmod a+x "$script"
    log_warn "开始执行重装（机器随后会重启进入安装，请勿断电/关机）..."
    bash "$script" "${DD_ARGS[@]}"
}

# mode = exec | print
run_container_reinstall() {
    local mode="${1:-exec}"
    log_section "容器重装 (OpenVZ7/LXC · OsMutation.sh)"
    echo -e "  第三方官方脚本来源: ${CYAN}${OSMUTATION_URL}${NC}"
    echo -e "  说明: 支持 OpenVZ7 / LXC 容器互转 Debian/CentOS/Alpine 等；${RED}不支持 KVM、不支持 OpenVZ6${NC}"
    reinstall_recommend_line
    if [[ $VIRT_IS_CONTAINER -eq 0 && "$VIRT_TYPE" != "none" ]]; then
        log_error "检测到本机是 ${VIRT_TYPE}(非容器)，OsMutation 仅适用于容器，KVM 请改用【DD 网络重装】。"
        if [[ "$mode" != "print" ]]; then
            local f
            read -p "仍要强行继续? [y/N]: " f
            [[ "$f" =~ ^[Yy]$ ]] || return 0
        fi
    fi

    local getrun="wget -qO OsMutation.sh ${OSMUTATION_URL} && chmod u+x OsMutation.sh && ./OsMutation.sh"
    echo ""
    echo -e "将执行的命令(脚本自带交互菜单)："
    echo -e "  ${GREEN}${getrun}${NC}"

    if [[ "$mode" == "print" ]]; then
        echo ""
        echo -e "${YELLOW}[只打印模式] 复制上面命令到目标容器执行即可（脚本不会替你按下执行）。${NC}"
        return 0
    fi

    reinstall_danger_banner
    reinstall_typed_confirm || { log_info "已取消，未做任何改动。"; return 0; }

    local script="/tmp/OsMutation.sh"
    log_warn "正在下载官方 OsMutation.sh ..."
    if ! download_file "$OSMUTATION_URL" "$script"; then
        log_error "下载失败。可手动执行： ${getrun}"
        return 1
    fi
    chmod u+x "$script"
    log_warn "启动 OsMutation 交互菜单（后续按其提示操作）..."
    bash "$script"
}

reinstall_show_commands() {
    log_section "系统重装 · 官方命令一览（只看不执行）"
    reinstall_recommend_line
    echo ""
    echo -e "${GREEN}① DD 网络重装 (KVM/Xen/独服) — leitbogioro InstallNET${NC}"
    echo -e "   ${CYAN}wget --no-check-certificate -qO InstallNET.sh '${INSTALLNET_URL}' && chmod a+x InstallNET.sh && bash InstallNET.sh -debian 12 -pwd '你的密码'${NC}"
    echo -e "   支持: debian/ubuntu/centos/rockylinux/almalinux/alpine/fedora/kali/windows ；${RED}不支持 OpenVZ/LXC${NC}"
    echo ""
    echo -e "${GREEN}② 容器重装 (OpenVZ7/LXC) — LloydAsp OsMutation${NC}"
    echo -e "   ${CYAN}wget -qO OsMutation.sh ${OSMUTATION_URL} && chmod u+x OsMutation.sh && ./OsMutation.sh${NC}"
    echo -e "   支持: OpenVZ7 / LXC ；${RED}不支持 KVM、不支持 OpenVZ6${NC}"
}

show_reinstall_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${CYAN}║        🖥  系统重装 (DD / 容器)               ║${NC}"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        reinstall_recommend_line
        echo ""
        echo -e "${RED}  ⚠ 会擦除全部数据并重装系统，不可逆！先把数据备份到机器外。${NC}"
        echo ""
        echo -e "  1) DD 网络重装        (KVM/Xen/独服 · InstallNET) — 确认后直接执行"
        echo -e "  2) 容器重装          (OpenVZ7/LXC · OsMutation)  — 确认后直接执行"
        echo -e "  3) 只打印命令 / 复制  (拼好官方命令，不执行)"
        echo -e "  0) 返回上级菜单"
        echo ""
        local rc pc
        read -p "请输入选择 [0-3]: " rc
        case "$rc" in
            1) run_dd_reinstall exec; pause_return_main_menu; return 0 ;;
            2) run_container_reinstall exec; pause_return_main_menu; return 0 ;;
            3)
                echo "只打印哪个的命令? 1) DD  2) 容器  3) 两个官方命令一览"
                read -p "请输入选择 [1-3]: " pc
                case "$pc" in
                    1) run_dd_reinstall print ;;
                    2) run_container_reinstall print ;;
                    3) reinstall_show_commands ;;
                    *) log_error "无效选择"; sleep 1; continue ;;
                esac
                pause_return_main_menu; return 0
                ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============ 出站流量守护 (到量自动关机) ============

traffic_guard_detect_default_iface() {
    local iface=""

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
        [[ -z "$iface" ]] && iface=$(ip -o route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    fi

    if [[ -z "$iface" ]] && command -v route >/dev/null 2>&1; then
        iface=$(route -n 2>/dev/null | awk '$1=="0.0.0.0" {print $8; exit}')
    fi

    if [[ -z "$iface" ]]; then
        local path
        for path in /sys/class/net/*; do
            [[ -e "$path" ]] || continue
            iface="${path##*/}"
            [[ "$iface" == "lo" ]] && continue
            [[ -r "$path/statistics/tx_bytes" ]] && break
            iface=""
        done
    fi

    echo "$iface"
}

traffic_guard_list_interfaces() {
    local path iface tx_bytes

    echo -e "${CYAN}可监控网卡:${NC}"
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        iface="${path##*/}"
        [[ "$iface" == "lo" ]] && continue
        if [[ -r "$path/statistics/tx_bytes" ]]; then
            tx_bytes=$(cat "$path/statistics/tx_bytes" 2>/dev/null || echo 0)
            echo "  - $iface  当前出站累计: $(traffic_guard_format_bytes "$tx_bytes")"
        fi
    done
}

traffic_guard_validate_iface() {
    local iface="$1"
    [[ -n "$iface" ]] || return 1
    [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 1
    [[ -r "/sys/class/net/$iface/statistics/tx_bytes" ]]
}

traffic_guard_read_tx_bytes() {
    local iface="$1"
    traffic_guard_validate_iface "$iface" || return 1
    cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null
}

traffic_guard_format_bytes() {
    local bytes="${1:-0}"
    awk -v bytes="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", unit, " ");
        value = bytes + 0;
        idx = 1;
        while (value >= 1024 && idx < 6) {
            value = value / 1024;
            idx++;
        }
        printf "%.2f %s", value, unit[idx];
    }'
}

traffic_guard_gb_to_bytes() {
    local gb="$1"
    [[ "$gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v gb="$gb" 'BEGIN {
        if (gb <= 0) exit 1;
        printf "%.0f\n", gb * 1024 * 1024 * 1024;
    }'
}

traffic_guard_service_state() {
    if service_is_active_any "$TRAFFIC_GUARD_SERVICE"; then
        echo "运行中"
    else
        echo "未运行"
    fi
}

traffic_guard_write_config() {
    local iface="$1"
    local baseline="$2"
    local limit_bytes="$3"
    local limit_gb="$4"
    local interval="$5"

    cat > "$TRAFFIC_GUARD_CONFIG" <<EOF
# AegisTune outbound traffic shutdown guard
# Generated by AegisTune (aegistune.sh)
INTERFACE="$iface"
BASELINE_BYTES="$baseline"
LIMIT_BYTES="$limit_bytes"
LIMIT_GB="$limit_gb"
INTERVAL_SECONDS="$interval"
LOG_FILE="$TRAFFIC_GUARD_LOG"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF
    chmod 600 "$TRAFFIC_GUARD_CONFIG"
}

traffic_guard_install_runner() {
    mkdir -p "$(dirname "$TRAFFIC_GUARD_RUNNER")"
    cat > "$TRAFFIC_GUARD_RUNNER" <<'EOF'
#!/bin/sh
set -eu

CONFIG_FILE="/etc/aegistune-traffic-guard.conf"
DEFAULT_LOG_FILE="/var/log/aegistune-traffic-guard.log"

log_msg() {
    log_file="${LOG_FILE:-$DEFAULT_LOG_FILE}"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$log_file" 2>/dev/null || true
}

read_tx_bytes() {
    iface="$1"
    file="/sys/class/net/$iface/statistics/tx_bytes"
    [ -r "$file" ] || return 1
    cat "$file"
}

format_bytes() {
    awk -v bytes="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", unit, " ");
        value = bytes + 0;
        idx = 1;
        while (value >= 1024 && idx < 6) {
            value = value / 1024;
            idx++;
        }
        printf "%.2f %s", value, unit[idx];
    }'
}

shutdown_host() {
    reason="AegisTune outbound traffic limit reached on ${INTERFACE:-unknown}"
    log_msg "$reason"
    sync || true
    if command -v shutdown >/dev/null 2>&1; then
        shutdown -h now "$reason" || true
    fi
    if command -v poweroff >/dev/null 2>&1; then
        poweroff || true
    fi
    if command -v halt >/dev/null 2>&1; then
        halt -p || true
    fi
    exit 0
}

[ -r "$CONFIG_FILE" ] || {
    log_msg "config not found: $CONFIG_FILE"
    exit 1
}

# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${INTERFACE:?missing INTERFACE}"
: "${BASELINE_BYTES:?missing BASELINE_BYTES}"
: "${LIMIT_BYTES:?missing LIMIT_BYTES}"
: "${INTERVAL_SECONDS:=60}"
: "${LOG_FILE:=$DEFAULT_LOG_FILE}"

log_msg "started: iface=$INTERFACE baseline=$BASELINE_BYTES limit=$LIMIT_BYTES interval=${INTERVAL_SECONDS}s"

while :; do
    current="$(read_tx_bytes "$INTERFACE" 2>/dev/null || echo "")"
    case "$current" in
        ''|*[!0-9]*)
            log_msg "cannot read tx_bytes for $INTERFACE, retry after ${INTERVAL_SECONDS}s"
            sleep "$INTERVAL_SECONDS"
            continue
            ;;
    esac

    if [ "$current" -lt "$BASELINE_BYTES" ]; then
        log_msg "tx counter reset on $INTERFACE, adjust in-memory baseline from $BASELINE_BYTES to $current"
        BASELINE_BYTES="$current"
    fi

    used=$((current - BASELINE_BYTES))
    if [ "$used" -ge "$LIMIT_BYTES" ]; then
        log_msg "limit reached: used=$(format_bytes "$used"), limit=$(format_bytes "$LIMIT_BYTES")"
        shutdown_host
    fi

    sleep "$INTERVAL_SECONDS"
done
EOF

    chmod 755 "$TRAFFIC_GUARD_RUNNER"
}

traffic_guard_install_service_file() {
    local manager
    manager="$(get_service_manager)"

    case "$manager" in
        systemd)
            cat > "/etc/systemd/system/${TRAFFIC_GUARD_SERVICE}.service" <<EOF
[Unit]
Description=AegisTune outbound traffic shutdown guard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TRAFFIC_GUARD_RUNNER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            service_daemon_reload
            ;;
        openrc)
            cat > "/etc/init.d/${TRAFFIC_GUARD_SERVICE}" <<EOF
#!/sbin/openrc-run
name="AegisTune outbound traffic shutdown guard"
description="Shutdown host when outbound traffic reaches configured limit"
command="${TRAFFIC_GUARD_RUNNER}"
command_background="yes"
pidfile="/run/${TRAFFIC_GUARD_SERVICE}.pid"

depend() {
    need net
    after firewall
}
EOF
            chmod 755 "/etc/init.d/${TRAFFIC_GUARD_SERVICE}"
            ;;
        sysv)
            cat > "/etc/init.d/${TRAFFIC_GUARD_SERVICE}" <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${TRAFFIC_GUARD_SERVICE}
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: AegisTune outbound traffic shutdown guard
### END INIT INFO

PIDFILE="/run/${TRAFFIC_GUARD_SERVICE}.pid"
RUNNER="${TRAFFIC_GUARD_RUNNER}"

start_service() {
    if command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon --start --background --make-pidfile --pidfile "\$PIDFILE" --exec "\$RUNNER"
    else
        nohup "\$RUNNER" >/dev/null 2>&1 &
        echo \$! > "\$PIDFILE"
    fi
}

stop_service() {
    if command -v start-stop-daemon >/dev/null 2>&1; then
        start-stop-daemon --stop --pidfile "\$PIDFILE" --retry 5 || true
    elif [ -f "\$PIDFILE" ]; then
        kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
    fi
    rm -f "\$PIDFILE"
}

case "\$1" in
    start) start_service ;;
    stop) stop_service ;;
    restart) stop_service; start_service ;;
    status)
        [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null && exit 0
        exit 3
        ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
            chmod 755 "/etc/init.d/${TRAFFIC_GUARD_SERVICE}"
            ;;
        *)
            log_error "未识别到 systemd/OpenRC/SysV，无法安装守护服务。"
            return 1
            ;;
    esac
}

traffic_guard_enable_and_start() {
    traffic_guard_install_runner
    traffic_guard_install_service_file

    if service_enable_any "$TRAFFIC_GUARD_SERVICE"; then
        log_success "已设置开机自启: $TRAFFIC_GUARD_SERVICE"
    else
        log_warn "设置开机自启失败，请手动检查服务管理器。"
    fi

    if service_action_any restart "$TRAFFIC_GUARD_SERVICE"; then
        log_success "出站流量守护已启动"
    else
        log_error "守护服务启动失败，请查看 $TRAFFIC_GUARD_LOG"
        return 1
    fi
}

traffic_guard_print_status() {
    log_section "出站流量守护状态"

    if [[ ! -f "$TRAFFIC_GUARD_CONFIG" ]]; then
        log_warn "尚未配置出站流量守护"
        return 0
    fi

    # shellcheck disable=SC1090
    source "$TRAFFIC_GUARD_CONFIG"

    local current used remain
    current=$(traffic_guard_read_tx_bytes "$INTERFACE" 2>/dev/null || echo "")

    echo -e "${CYAN}服务状态:${NC} $(traffic_guard_service_state)"
    echo -e "${CYAN}监控网卡:${NC} $INTERFACE"
    echo -e "${CYAN}阈值:${NC} ${LIMIT_GB:-?} GiB ($(traffic_guard_format_bytes "$LIMIT_BYTES"))"
    echo -e "${CYAN}轮询间隔:${NC} ${INTERVAL_SECONDS:-60}s"
    echo -e "${CYAN}配置文件:${NC} $TRAFFIC_GUARD_CONFIG"
    echo -e "${CYAN}日志文件:${NC} ${LOG_FILE:-$TRAFFIC_GUARD_LOG}"

    if [[ "$current" =~ ^[0-9]+$ ]]; then
        if (( current < BASELINE_BYTES )); then
            log_warn "当前网卡计数小于基线，可能发生过重启或网卡重置；守护进程会自动以当前计数重新作为运行期基线。"
            used=0
        else
            used=$((current - BASELINE_BYTES))
        fi
        remain=$((LIMIT_BYTES - used))
        (( remain < 0 )) && remain=0
        echo -e "${CYAN}已统计出站:${NC} $(traffic_guard_format_bytes "$used")"
        echo -e "${CYAN}剩余额度:${NC} $(traffic_guard_format_bytes "$remain")"
    else
        log_warn "无法读取 $INTERFACE 的 tx_bytes"
    fi
}

traffic_guard_setup_interactive() {
    log_section "配置出站流量到量关机"

    local default_iface iface baseline limit_gb limit_bytes interval confirm
    default_iface=$(traffic_guard_detect_default_iface)
    traffic_guard_list_interfaces
    echo ""

    read -r -p "请输入要监控的网卡 [默认: ${default_iface:-手动输入}]: " iface
    iface="${iface:-$default_iface}"

    if ! traffic_guard_validate_iface "$iface"; then
        log_error "网卡无效或无法读取 tx_bytes: $iface"
        return 1
    fi

    baseline=$(traffic_guard_read_tx_bytes "$iface")

    while true; do
        read -r -p "请输入出站流量上限 GiB (例如 500 或 1.5): " limit_gb
        limit_bytes=$(traffic_guard_gb_to_bytes "$limit_gb" 2>/dev/null || true)
        if [[ -n "$limit_bytes" && "$limit_bytes" =~ ^[0-9]+$ && "$limit_bytes" -gt 0 ]]; then
            break
        fi
        log_error "请输入大于 0 的数字，例如 100、500、1.5"
    done

    read -r -p "检测间隔秒数 [默认: 60]: " interval
    interval="${interval:-60}"
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 5 ]]; then
        log_warn "检测间隔无效，已使用默认 60 秒。"
        interval=60
    fi

    echo ""
    echo -e "${YELLOW}即将启用到量关机:${NC}"
    echo "  网卡: $iface"
    echo "  当前出站计数基线: $(traffic_guard_format_bytes "$baseline")"
    echo "  新增出站上限: ${limit_gb} GiB ($(traffic_guard_format_bytes "$limit_bytes"))"
    echo "  检测间隔: ${interval}s"
    echo "  到量动作: 立即关机"
    echo ""
    read -r -p "确认安装并启动守护服务？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "已取消配置。"
        return 0
    fi

    traffic_guard_write_config "$iface" "$baseline" "$limit_bytes" "$limit_gb" "$interval"
    traffic_guard_enable_and_start
    traffic_guard_print_status
}

traffic_guard_stop_service() {
    if service_action_any stop "$TRAFFIC_GUARD_SERVICE"; then
        log_success "出站流量守护已停止"
    else
        log_warn "停止服务失败或服务未运行"
    fi
}

traffic_guard_remove() {
    log_section "移除出站流量守护"
    traffic_guard_stop_service
    service_disable_any "$TRAFFIC_GUARD_SERVICE" >/dev/null 2>&1 || true

    rm -f "/etc/systemd/system/${TRAFFIC_GUARD_SERVICE}.service"
    rm -f "/etc/init.d/${TRAFFIC_GUARD_SERVICE}"
    rm -f "$TRAFFIC_GUARD_RUNNER"
    rm -f "$TRAFFIC_GUARD_CONFIG"
    service_daemon_reload

    log_success "已移除守护服务、运行器和配置文件；日志保留在 $TRAFFIC_GUARD_LOG"
}

show_traffic_guard_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
        printf "%b\n" "${CYAN}║        出站流量守护 (到量自动关机)                          ║"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        traffic_guard_print_status
        echo ""
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
        printf "%b\n" "${CYAN}║     1) 配置/重置出站流量上限                                ║"
        printf "%b\n" "${CYAN}║     2) 查看当前状态                                          ║"
        printf "%b\n" "${CYAN}║     3) 停止守护服务                                          ║"
        printf "%b\n" "${CYAN}║     4) 移除守护服务和配置                                    ║"
        printf "%b\n" "${CYAN}║     0) 返回主菜单                                            ║"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

        read -r -p "请输入选择 [0-4]: " traffic_choice
        case $traffic_choice in
            1)
                detect_init_system
                traffic_guard_setup_interactive
                pause_return_main_menu
                ;;
            2)
                traffic_guard_print_status
                pause_return_main_menu
                ;;
            3)
                traffic_guard_stop_service
                pause_return_main_menu
                ;;
            4)
                traffic_guard_remove
                pause_return_main_menu
                ;;
            0)
                return 0
                ;;
            *)
                log_error "无效选择"
                sleep 1
                ;;
        esac
    done
}

snapshot_tracked_files() {
    cat <<'EOF'
/etc/sysctl.conf
/etc/sysctl.d/99-bbr-tuning.conf
/etc/sysctl.d/99-bbr-aggressive.conf
/etc/sysctl.d/99-cc.conf
/etc/sysctl.d/99-aegistune-serverspan.conf
/etc/sysctl.d/99-aegistune-smart-bdp.conf
/etc/sysctl.d/99-aegistune-auto-merged.conf
/etc/sysctl.d/99-aegistune-forwarding.conf
/etc/sysctl.d/99-aegistune-provider-baseline-restore.conf
/etc/modules-load.d/network-tuning.conf
/etc/systemd/system/bpftune.service
/lib/systemd/system/bpftune.service
/etc/init.d/bpftune
/etc/gai.conf
EOF
}


create_config_snapshot() {
    local reason="$1"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local snap_dir="${SNAPSHOT_ROOT}/snapshot-${ts}"
    mkdir -p "${snap_dir}/files"
    : > "${snap_dir}/state.list"

    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        if [[ -e "$target" ]]; then
            mkdir -p "${snap_dir}/files$(dirname "$target")"
            cp -a "$target" "${snap_dir}/files${target}"
            echo "${target}|present" >> "${snap_dir}/state.list"
        else
            echo "${target}|absent" >> "${snap_dir}/state.list"
        fi
    done < <(snapshot_tracked_files)

    {
        echo "created_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "reason=${reason:-manual}"
        echo "kernel=$(uname -r)"
        echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
        echo "qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
    } > "${snap_dir}/meta.env"

    log_success "快照已创建: ${snap_dir}"
}

list_config_snapshots() {
    log_section "配置快照列表"
    mkdir -p "$SNAPSHOT_ROOT"

    local snapshots=()
    while IFS= read -r line; do
        snapshots+=("$line")
    done < <(ls -1dt "${SNAPSHOT_ROOT}"/snapshot-* 2>/dev/null || true)

    if [[ ${#snapshots[@]} -eq 0 ]]; then
        log_info "暂无快照"
        return 0
    fi

    local idx=1
    local snap
    for snap in "${snapshots[@]}"; do
        local created reason
        created=$(grep '^created_at=' "${snap}/meta.env" 2>/dev/null | cut -d= -f2-)
        reason=$(grep '^reason=' "${snap}/meta.env" 2>/dev/null | cut -d= -f2-)
        [[ -z "$created" ]] && created="unknown"
        [[ -z "$reason" ]] && reason="unknown"
        printf "%2d) %s | %s | reason=%s\n" "$idx" "$(basename "$snap")" "$created" "$reason"
        idx=$((idx + 1))
    done
}

restore_config_snapshot() {
    log_section "从快照回滚配置"
    mkdir -p "$SNAPSHOT_ROOT"

    local snapshots=()
    while IFS= read -r line; do
        snapshots+=("$line")
    done < <(ls -1dt "${SNAPSHOT_ROOT}"/snapshot-* 2>/dev/null || true)

    if [[ ${#snapshots[@]} -eq 0 ]]; then
        log_warn "暂无可回滚快照"
        return 1
    fi

    local idx=1
    local snap
    for snap in "${snapshots[@]}"; do
        local created reason
        created=$(grep '^created_at=' "${snap}/meta.env" 2>/dev/null | cut -d= -f2-)
        reason=$(grep '^reason=' "${snap}/meta.env" 2>/dev/null | cut -d= -f2-)
        [[ -z "$created" ]] && created="unknown"
        [[ -z "$reason" ]] && reason="unknown"
        printf "%2d) %s | %s | reason=%s\n" "$idx" "$(basename "$snap")" "$created" "$reason"
        idx=$((idx + 1))
    done

    echo " 0) 返回上层菜单"
    read -p "请选择要回滚的快照编号: " choose
    if [[ "$choose" == "0" ]]; then
        log_info "已取消快照回滚"
        return 0
    fi
    if ! [[ "$choose" =~ ^[0-9]+$ ]] || (( choose < 1 || choose > ${#snapshots[@]} )); then
        log_error "无效编号"
        return 1
    fi

    local target_snap="${snapshots[$((choose - 1))]}"
    local safety_reason="before_restore_$(basename "$target_snap")"
    create_config_snapshot "$safety_reason"

    if [[ ! -f "${target_snap}/state.list" ]]; then
        log_error "快照缺少 state.list，无法回滚"
        return 1
    fi

    while IFS='|' read -r target state; do
        [[ -z "$target" ]] && continue
        if [[ "$state" == "present" && -e "${target_snap}/files${target}" ]]; then
            mkdir -p "$(dirname "$target")"
            rm -rf "$target"
            cp -a "${target_snap}/files${target}" "$target"
        elif [[ "$state" == "absent" ]]; then
            rm -rf "$target"
        fi
    done < "${target_snap}/state.list"

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

    if [[ -f /etc/modules-load.d/network-tuning.conf ]]; then
        while IFS= read -r module; do
            [[ -z "$module" ]] && continue
            [[ "$module" =~ ^[[:space:]]*# ]] && continue
            modprobe "$module" 2>/dev/null || true
        done < /etc/modules-load.d/network-tuning.conf
    fi

    log_success "已回滚至快照: $(basename "$target_snap")"
}

print_system_status_card() {
    echo -e "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│              📊 系统状态面板                     │${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────┤${NC}"

    local cc cc_cell qdisc qdisc_cell
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    if [[ "$cc" == "bbr" ]]; then
        cc_cell="${GREEN}BBR ✓${NC}"
    else
        cc_cell="${YELLOW}${cc}${NC}"
    fi

    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    if [[ "$qdisc" == "fq" || "$qdisc" == "cake" ]]; then
        qdisc_cell="${GREEN}${qdisc^^} ✓${NC}"
    else
        qdisc_cell="${YELLOW}${qdisc}${NC}"
    fi
    render_status_card_line "拥塞控制:     " "$cc_cell"
    render_status_card_line "队列调度:     " "$qdisc_cell"

    local ipv4_addr ipv4_public ipv4_forward ipv6_addr ipv6_public ipv6_forward
    ipv4_addr=$(get_primary_ipv4)
    ipv4_public=$(get_public_ipv4 2>/dev/null || true)
    ipv4_forward=$(get_ipv4_forwarding_status)
    ipv6_addr=$(get_primary_ipv6)
    ipv6_public=$(get_public_ipv6 2>/dev/null || true)
    ipv6_forward=$(get_ipv6_forwarding_status)

    local ipv4_public_cell ipv4_forward_cell ipv6_public_cell ipv6_forward_cell
    local ipv4_local_cell ipv6_local_cell
    if [[ -n "$ipv4_public" ]]; then
        ipv4_public_cell="${GREEN}${ipv4_public}${NC}"
    else
        ipv4_public_cell="${YELLOW}未获取${NC}"
    fi
    if [[ "$ipv4_forward" == "已启用" ]]; then
        ipv4_forward_cell="${GREEN}开 ✓${NC}"
    else
        ipv4_forward_cell="${YELLOW}关${NC}"
    fi
    render_status_card_line "IPv4公网:      " "$ipv4_public_cell"
    render_status_card_line "IPv4转发:      " "$ipv4_forward_cell"

    if [[ -n "$ipv4_addr" ]]; then
        if is_private_ipv4 "$ipv4_addr"; then
            ipv4_local_cell="${YELLOW}${ipv4_addr}${NC}"
        else
            ipv4_local_cell="${GREEN}${ipv4_addr}${NC}"
        fi
    else
        ipv4_local_cell="${YELLOW}未检测到${NC}"
    fi
    render_status_card_line "IPv4本机:      " "$ipv4_local_cell"

    if [[ -n "$ipv6_public" ]]; then
        ipv6_public_cell="${GREEN}${ipv6_public}${NC}"
    else
        ipv6_public_cell="${YELLOW}未获取${NC}"
    fi
    if [[ "$ipv6_forward" == "已启用" ]]; then
        ipv6_forward_cell="${GREEN}开 ✓${NC}"
    elif [[ "$ipv6_forward" == "未检测到" ]]; then
        ipv6_forward_cell="${YELLOW}未检测到${NC}"
    else
        ipv6_forward_cell="${YELLOW}关${NC}"
    fi
    render_status_card_line "IPv6公网:      " "$ipv6_public_cell"
    render_status_card_line "IPv6转发:      " "$ipv6_forward_cell"

    if [[ -n "$ipv6_addr" ]]; then
        if is_global_ipv6 "$ipv6_addr"; then
            ipv6_local_cell="${GREEN}${ipv6_addr}${NC}"
        else
            ipv6_local_cell="${YELLOW}${ipv6_addr}${NC}"
        fi
    else
        ipv6_local_cell="${YELLOW}未检测到${NC}"
    fi
    render_status_card_line "IPv6本机:      " "$ipv6_local_cell"
    echo -e "${CYAN}├──────────────────────────────────────────────────┤${NC}"

    local tcp_buffer_cell
    local rmem_max
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
    if [[ -n "$rmem_max" && "$rmem_max" =~ ^[0-9]+$ ]]; then
        local rmem_mib
        rmem_mib=$(awk -v v="$rmem_max" 'BEGIN {printf "%.1f", v/1024/1024}')
        tcp_buffer_cell="${GREEN}${rmem_mib} MiB${NC}"
    else
        tcp_buffer_cell="${YELLOW}未知${NC}"
    fi
    render_status_card_line "TCP 缓冲区:    " "$tcp_buffer_cell"
    echo -e "${CYAN}└──────────────────────────────────────────────────┘${NC}"
}

# ============ 验证 ============

verify_installation() {
    log_section "安装验证"
    ensure_brutal_not_default
    
    echo ""
    print_system_status_card

    warn_brutal_usage
    
    echo ""
}

show_final_message() {
    
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    ✅ 安装完成！                             ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    echo "║  🚀 已配置: BBR + ${QDISC_CHOICE^^}                                        ║"
    echo "║                                                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  配置文件:                                                   ║"
    echo "║    • /etc/sysctl.d/99-bbr-tuning.conf                       ║"
    echo "║    • /etc/modules-load.d/network-tuning.conf                ║"
    echo "║                                                              ║"
    echo "║  卸载命令:                                                   ║"
    echo "║    sudo bash $0 uninstall                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============ 卸载 ============

uninstall() {
    log_section "卸载配置"

    create_config_snapshot "before_uninstall_network_tuning"
    detect_pkg_manager
    
    # 删除配置文件
    rm -f /etc/sysctl.d/99-bbr-tuning.conf
    rm -f /etc/sysctl.d/99-bbr-aggressive.conf
    rm -f /etc/sysctl.d/99-aegistune-serverspan.conf
    rm -f /etc/sysctl.d/99-aegistune-smart-bdp.conf
    rm -f /etc/sysctl.d/99-aegistune-auto-merged.conf
    rm -f /etc/sysctl.d/99-aegistune-forwarding.conf
    rm -f /etc/modules-load.d/network-tuning.conf

    # 清理 Alpine: 删除 /etc/sysctl.conf 里的 AegisTune 标记块
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/^# === AegisTune BBR BEGIN ===/,/^# === AegisTune BBR END ===/d' /etc/sysctl.conf 2>/dev/null || true
    fi

    # 清理非 systemd 下写入 /etc/modules 的模块行（只删这三行，不清空文件）
    if [[ -f /etc/modules ]]; then
        sed -i '/^tcp_bbr$/d;/^sch_fq$/d;/^sch_cake$/d' /etc/modules 2>/dev/null || true
    fi

    sysctl --system > /dev/null 2>&1

    log_success "配置已删除"
    log_info "注意: BBR 和队列调度将在重启后恢复默认值"
}

system_has_ipv6() {
    if [[ ! -r /proc/net/if_inet6 ]]; then
        return 1
    fi

    local disabled
    disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "")
    if [[ "$disabled" == "1" ]]; then
        return 1
    fi

    if command -v ip >/dev/null 2>&1; then
        if ip -6 route show default 2>/dev/null | grep -q .; then
            return 0
        fi
        if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
            return 0
        fi
    fi

    return 1
}

get_primary_ipv4() {
    local ipv4_addr=""
    if command -v ip >/dev/null 2>&1; then
        ipv4_addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [[ -z "$ipv4_addr" ]]; then
        ipv4_addr=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')
    fi
    echo "$ipv4_addr"
}

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
    [[ "$ip" =~ ^0\. ]] && return 0
    [[ "$ip" =~ ^255\. ]] && return 0
    return 1
}

is_public_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    is_private_ipv4 "$ip" && return 1
    return 0
}

get_primary_ipv6() {
    local ipv6_addr=""
    if command -v ip >/dev/null 2>&1; then
        ipv6_addr=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
        if [[ -z "$ipv6_addr" ]]; then
            ipv6_addr=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {sub(/\/.*/, "", $2); print $2; exit}')
        fi
    fi
    echo "$ipv6_addr"
}

is_global_ipv6() {
    local ip="${1,,}"
    [[ -n "$ip" && "$ip" == *:* ]] || return 1
    [[ "$ip" == "::1" ]] && return 1
    [[ "$ip" == fe80:* ]] && return 1
    [[ "$ip" == fc* || "$ip" == fd* ]] && return 1
    [[ "$ip" == 2001:db8:* ]] && return 1
    return 0
}

read_cached_status_value() {
    local cache_file="$1"
    local ttl="${2:-60}"

    [[ -f "$cache_file" ]] || return 1

    local timestamp value now
    timestamp=$(sed -n '1p' "$cache_file" 2>/dev/null)
    value=$(sed -n '2p' "$cache_file" 2>/dev/null)
    now=$(date +%s)

    [[ "$timestamp" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$value" ]] || return 1
    (( now - timestamp <= ttl )) || return 1

    printf '%s\n' "$value"
}

write_cached_status_value() {
    local cache_file="$1"
    local value="$2"

    mkdir -p "$STATUS_CACHE_ROOT"
    {
        date +%s
        printf '%s\n' "$value"
    } > "$cache_file"
}

get_public_ipv4() {
    local cached value
    cached=$(read_cached_status_value "$PUBLIC_IPV4_CACHE" 60 2>/dev/null || true)
    if [[ -n "$cached" ]]; then
        printf '%s\n' "$cached"
        return 0
    fi

    command -v curl >/dev/null 2>&1 || return 1

    for url in "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
        value=$(curl -4 -fsS --connect-timeout 1 --max-time 2 "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        if is_public_ipv4 "$value"; then
            write_cached_status_value "$PUBLIC_IPV4_CACHE" "$value"
            printf '%s\n' "$value"
            return 0
        fi
    done

    return 1
}

get_public_ipv6() {
    local cached value
    cached=$(read_cached_status_value "$PUBLIC_IPV6_CACHE" 60 2>/dev/null || true)
    if [[ -n "$cached" ]]; then
        printf '%s\n' "$cached"
        return 0
    fi

    system_has_ipv6 || return 1
    command -v curl >/dev/null 2>&1 || return 1

    for url in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
        value=$(curl -6 -fsS --connect-timeout 1 --max-time 3 "$url" 2>/dev/null | tr -d '\r\n[:space:]')
        if is_global_ipv6 "$value"; then
            write_cached_status_value "$PUBLIC_IPV6_CACHE" "$value"
            printf '%s\n' "$value"
            return 0
        fi
    done

    return 1
}

truncate_status_value() {
    local value="$1"
    local limit="${2:-20}"
    local value_len=${#value}

    if (( value_len <= limit )); then
        echo "$value"
    else
        echo "${value:0:limit-3}..."
    fi
}

render_status_card_line() {
    local label="$1"
    local value="$2"
    printf "%b\n" "${CYAN}│${NC}  ${label} ${value}"
}

get_ipv4_forwarding_status() {
    local state
    state=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "")
    if [[ "$state" == "1" ]]; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

get_ipv6_forwarding_status() {
    if ! system_has_ipv6; then
        echo "未检测到"
        return 0
    fi

    local state
    state=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "")
    if [[ "$state" == "1" ]]; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

run_self_test_dry_run() {
    log_section "Self-Test / Dry-Run (预览 BDP 缓冲，不写系统)"
    detect_os; detect_kernel
    log_info "本模式不写 /etc/sysctl.d、不拍快照、不执行 sysctl。"
    local qc="${QDISC_CHOICE:-fq}"
    log_info "qdisc=${qc}, 拥塞控制=bbr"
    local pair name rtt bw b mib
    for pair in "亚洲近距:${_BDP_RTT_ASIA}" "跨太平洋:${_BDP_RTT_TRANSPAC}"; do
        name="${pair%%:*}"; rtt="${pair##*:}"
        for bw in 500 1000 2000; do
            b=$(_bdp_buffer_bytes "$bw" "$rtt")
            mib=$(awk -v v="$b" 'BEGIN{printf "%.1f", v/1048576}')
            log_info "  ${name} (RTT ${rtt}ms) × ${bw}Mbps → 缓冲 ${mib} MiB (2×BDP, 夹[8,64])"
        done
    done
    log_success "Self-Test 通过：BDP 缓冲计算逻辑正常（未改动系统）。"
}

# ============ SSH 配置 ============

# ============ SSH 登录方式管理（密码 / 密钥 / 公钥） ============
#
# 核心教训：sshd 是"首次匹配生效"，且 Debian/Ubuntu/cloud 镜像的
# `Include /etc/ssh/sshd_config.d/*.conf` 排在主配置很靠前——所以
# sshd_config.d/50-cloud-init.conf 的 PasswordAuthentication no 会压过
# 主配置和 99-*.conf。要真正改登录方式，必须：①写进排最前的 drop-in
# (00-aegistune.conf) 抢首匹配 + 主配置全局值(前置插入，避开 Match 作用域) ②写完用
# `sshd -T` 回读确认"真正生效"、校验不过就回滚，而非"写了文件就报成功"。
#
# ⚠️ 边界（对抗审计记档，未强解、以护栏+提示兜底）：
#   - sshd -T 无 -C，读的是全局值；Match User/Address 作用域的覆盖看不到 → 有 Match 时警告用户手动核对。
#   - AllowUsers/DenyUsers/自定义 `sshd -f 别的配置`/账户策略等语义未逐一判 → 靠"关键动作前先另开会话用密码登录验证"兜底。

# 定位 sshd 可执行文件（有些系统 /usr/sbin 不在 PATH）
_sshd_bin() {
    command -v sshd 2>/dev/null && return 0
    [[ -x /usr/sbin/sshd ]] && { echo /usr/sbin/sshd; return 0; }
    return 1
}

# 主配置是否 active 引入 sshd_config.d（决定 drop-in 能否抢首匹配）
_ssh_include_active() {
    grep -qiE '^[[:space:]]*Include[[:space:]]+[^#]*sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null
}

# 配置里是否有 Match 块（我们只改全局值，Match 作用域需人工核对）
_ssh_has_match_block() {
    local f
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        grep -qiE '^[[:space:]]*Match[[:space:]]' "$f" 2>/dev/null && return 0
    done
    return 1
}

# 把某文件里某指令的【全局】现存行注释掉，并把权威值【前置插入】到文件最前（主配置用）。
# 前置(而非末尾追加)是为了：①首匹配生效 ②绝不落进末尾的 Match 作用域里。
# Match 作用域内的同名指令【保留不动】，避免破坏 Match User/Address 的有意例外。
# busybox awk 安全：大小写不敏感匹配首 token。
_ssh_comment_and_append() {
    local file="$1" directive="$2" value="$3" tmp="$1.aegistmp.$$"
    awk -v d="$directive" -v v="$value" '
        BEGIN { dl=tolower(d); print d " " v; inmatch=0 }
        {
            line=$0; t=line
            sub(/^[ \t]+/, "", t); sub(/^#+[ \t]*/, "", t)
            n=split(t, a, /[ \t]+/)
            if (n>0 && tolower(a[1])=="match") { inmatch=1; print line; next }
            if (inmatch==0 && n>0 && tolower(a[1])==dl) {
                if (line ~ /^[ \t]*#/) print line; else print "#" line
                next
            }
            print line
        }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
}

# 我们自己拥有的 drop-in：删旧行 + 追加新行（不留注释残余）
_ssh_set_dropin() {
    local file="$1" directive="$2" value="$3" tmp="$1.aegistmp.$$"
    if [[ ! -f "$file" ]]; then
        printf '# AegisTune SSH overrides —— 排最前抢 sshd_config.d 首匹配，勿手改\n' > "$file"
    fi
    awk -v d="$directive" '
        BEGIN { dl=tolower(d) }
        {
            t=$0; sub(/^[ \t]+/, "", t); sub(/^#+[ \t]*/, "", t)
            n=split(t, a, /[ \t]+/)
            if (n>0 && tolower(a[1])==dl) next
            print
        }
    ' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
    printf '%s %s\n' "$directive" "$value" >> "$file"
}

# 读某指令的"真正生效值"（sshd -T 回读，键名全小写）
_ssh_effective() {
    local directive_lc; directive_lc="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    local sshd; sshd="$(_sshd_bin)" || return 1
    "$sshd" -T 2>/dev/null | awk -v k="$directive_lc" '$1==k {print $2; exit}'
}

# 指令生效值等价判断：PermitRootLogin 的 prohibit-password 与 without-password 同义
# （不同 OpenSSH 版本 sshd -T 打印名不同，精确比较会误判"未生效"）
_ssh_value_equiv() {
    local directive="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] && return 0
    local dl; dl="$(printf '%s' "$directive" | tr 'A-Z' 'a-z')"
    if [[ "$dl" == "permitrootlogin" ]]; then
        case "$got|$want" in
            "prohibit-password|without-password"|"without-password|prohibit-password") return 0 ;;
        esac
    fi
    return 1
}

# root 无可用密码时开了密码登录也进不来——仅提醒（用于"开密码登录"这类开通路，不阻断）
_ssh_warn_if_root_has_no_password() {
    local st
    st="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    case "$st" in
        NP|L)
            log_warn "检测到 root 账户当前无可用密码（状态: $st）——即便开了密码登录，没设密码也进不去！"
            log_warn "强烈建议现在就设置 root 密码。"
            ;;
    esac
}

# 关公钥前的终极护栏（fail-closed）：确认 root 有可用密码，否则关了公钥必锁死。
# 返回 0=确认可用/已设好；1=不可用且未能补救/用户放弃 → 调用方必须中止关公钥。
_ssh_require_usable_password() {
    local st
    st="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    case "$st" in
        P)
            return 0 ;;
        NP|L)
            log_warn "root 当前无可用密码（状态: $st）——不设密码就关公钥必锁死。"
            read -p "现在设置 root 密码? [Y/n]: " sp
            if [[ "$sp" =~ ^[Nn]$ ]]; then
                log_error "未设置 root 密码 + 关公钥 = 锁死，已中止。"
                return 1
            fi
            if ! passwd root; then
                log_error "设置 root 密码失败（passwd 返回非零），为避免锁死已中止。"
                return 1
            fi
            st="$(passwd -S root 2>/dev/null | awk '{print $2}')"
            if [[ "$st" == "NP" || "$st" == "L" ]]; then
                log_error "设完密码复检仍显示无可用密码（$st），为避免锁死已中止。"
                return 1
            fi
            return 0 ;;
        *)
            # 空/未知（busybox passwd -S 不支持等）——无法确认，fail-closed
            log_warn "无法确认 root 是否有可用密码（passwd -S 不支持或输出异常，状态: '${st:-空}'）。"
            log_warn "关公钥后只能用密码登录；若 root 没有可用密码将被锁死。"
            read -p "你确认 root 有可用密码、并已在另一个会话用密码登录验证过? 输入大写 YES 继续、其它取消: " oc
            if [[ "$oc" != "YES" ]]; then
                log_error "未确认 root 密码可用，已中止关闭公钥。"
                return 1
            fi
            return 0 ;;
    esac
}

# 应用一组 SSH 指令并"真正生效"：备份 → 权威 drop-in + 主配置全局值 →
# sshd -t 语法 → 重启 → sshd -T 逐条回读确认（同义值等价）。
# 入参形如 "PasswordAuthentication=yes"。
# 返回：0=全生效且重启成功；1=语法错(已回滚)；2=生效校验未过(已回滚)；3=生效已写盘但服务重启失败(未回滚,需手动 restart)。
ssh_apply_directives_effective() {
    local main="/etc/ssh/sshd_config"
    local dropdir="/etc/ssh/sshd_config.d"
    local dropfile="$dropdir/00-aegistune.conf"
    local ts backup dropbak="" use_dropin=0 sshd
    ts="$(date +%Y%m%d%H%M%S)"
    # 同一秒连调两次（如"先开密码再关公钥"）也不撞备份名：加 PID + 自增序号
    _SSH_APPLY_SEQ=$(( ${_SSH_APPLY_SEQ:-0} + 1 ))

    [[ -f "$main" ]] || { log_error "SSH 配置不存在: $main"; return 1; }
    sshd="$(_sshd_bin)" || { log_error "找不到 sshd 可执行文件，拒绝盲改配置"; return 1; }

    backup="${main}.backup.aegistune.${ts}.$$.${_SSH_APPLY_SEQ}"
    cp "$main" "$backup" || { log_error "备份 $main 失败"; return 1; }
    log_info "已备份 SSH 主配置 → $backup"

    # 清掉历史遗留的 99-allow-root-password.conf（老逻辑失败产物，排在 50-cloud-init 之后无效）
    rm -f "$dropdir/99-allow-root-password.conf" 2>/dev/null || true

    if [[ -d "$dropdir" ]] && _ssh_include_active; then
        use_dropin=1
        if [[ -f "$dropfile" ]]; then
            dropbak="${dropfile}.backup.aegistune.${ts}.$$.${_SSH_APPLY_SEQ}"
            cp "$dropfile" "$dropbak" 2>/dev/null || true
        fi
    fi

    local pair d v
    for pair in "$@"; do
        d="${pair%%=*}"; v="${pair#*=}"
        _ssh_comment_and_append "$main" "$d" "$v"
        [[ $use_dropin -eq 1 ]] && _ssh_set_dropin "$dropfile" "$d" "$v"
    done

    # 回滚闭包：主配置 + drop-in 都还原到改动前
    _ssh_rollback() {
        cp "$backup" "$main" 2>/dev/null || true
        if [[ $use_dropin -eq 1 ]]; then
            if [[ -n "$dropbak" ]]; then cp "$dropbak" "$dropfile" 2>/dev/null || true
            else rm -f "$dropfile" 2>/dev/null || true; fi
        fi
    }

    if ! "$sshd" -t 2>/dev/null; then
        log_error "sshd 配置语法检查未通过，正在回滚..."
        _ssh_rollback
        return 1
    fi

    local restart_ok=1
    if ! service_action_any restart sshd ssh; then
        restart_ok=0
        log_warn "SSH 服务重启可能失败——磁盘配置已改，但运行中的 sshd 可能仍用旧配置。"
    fi

    # 生效校验（同义值等价）
    local all_ok=1 el
    for pair in "$@"; do
        d="${pair%%=*}"; v="${pair#*=}"
        el="$(_ssh_effective "$d")"
        if _ssh_value_equiv "$d" "$el" "$v"; then
            log_success "生效确认：$d = ${el:-$v}"
        else
            log_error "生效校验未过：$d 期望=$v 实际=${el:-未知}（可能被更前的 drop-in 或 Match 块压制）"
            all_ok=0
        fi
    done

    if [[ $all_ok -ne 1 ]]; then
        log_warn "生效校验未通过，回滚到改动前配置，避免留下半生效的危险状态..."
        _ssh_rollback
        service_action_any restart sshd ssh >/dev/null 2>&1 || true
        return 2
    fi

    [[ $restart_ok -eq 1 ]] && return 0 || return 3
}

configure_ssh_root_login() {
    log_section "开启 SSH Root 密码登录"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    [[ -f "$SSHD_CONFIG" ]] || { log_error "SSH 配置文件不存在: $SSHD_CONFIG"; return 1; }

    echo ""
    echo -e "${CYAN}当前生效状态（sshd -T 回读）:${NC}"
    echo "  PermitRootLogin:        $(_ssh_effective PermitRootLogin || echo 未知)"
    echo "  PasswordAuthentication: $(_ssh_effective PasswordAuthentication || echo 未知)"
    echo ""
    echo -e "${YELLOW}⚠️  警告: 开启 root 密码登录会降低安全性！建议配合强密码 + fail2ban。${NC}"
    _ssh_has_match_block && log_warn "配置含 Match 块：本工具只改全局设置，Match User/Address 作用域请手动核对。"
    echo ""
    read -p "确认要开启 SSH root 密码登录? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消操作"; return 0; }

    ssh_apply_directives_effective PermitRootLogin=yes PasswordAuthentication=yes
    local rc=$?
    if [[ $rc -eq 0 || $rc -eq 3 ]]; then
        log_success "SSH root 密码登录配置已写入并确认生效"
        [[ $rc -eq 3 ]] && log_warn "但 SSH 服务重启失败，请手动 systemctl restart sshd（或 service ssh restart）使其生效。"
        _ssh_warn_if_root_has_no_password
        echo ""
        read -p "是否现在设置/修改 root 密码? [y/N]: " set_pw
        [[ "$set_pw" =~ ^[Yy]$ ]] && passwd root
    elif [[ $rc -eq 1 ]]; then
        log_error "配置语法错误已回滚，未改动生效配置"
        return 1
    else
        log_error "配置未回读到预期值、已回滚（可能有更前的 drop-in/Match 压制），请手动 sshd -T 检查"
        return 1
    fi
}

disable_ssh_password_login() {
    log_section "禁用 SSH 密码登录 (仅密钥)"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    [[ -f "$SSHD_CONFIG" ]] || { log_error "SSH 配置文件不存在: $SSHD_CONFIG"; return 1; }

    echo -e "${YELLOW}⚠️  警告: 禁用密码登录后，只能用 SSH 密钥访问！${NC}"
    # 护栏：确认公钥登录真的开着，否则禁密码=锁死
    local pk; pk="$(_ssh_effective PubkeyAuthentication)"
    if [[ "$pk" != "yes" ]]; then
        log_error "当前公钥登录未生效（PubkeyAuthentication=${pk:-未知}）——禁用密码会把你锁死在门外，已中止。"
        log_info "请先确保密钥登录可用（PubkeyAuthentication yes + 已配置 authorized_keys）再来禁用密码。"
        return 1
    fi
    if [[ ! -s /root/.ssh/authorized_keys && ! -s "${HOME}/.ssh/authorized_keys" ]]; then
        log_warn "未发现非空的 authorized_keys（/root/.ssh/ 或 $HOME/.ssh/）——确认你的密钥确实能登录再继续！"
    fi
    _ssh_has_match_block && log_warn "配置含 Match 块：本工具只改全局设置，Match 作用域可能另有登录方式，请手动核对。"
    echo -e "${YELLOW}强烈建议：先另开一个新终端用密钥登录验证能进，再断开当前会话。${NC}"
    echo ""
    read -p "确认要禁用 SSH 密码登录? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消操作"; return 0; }

    ssh_apply_directives_effective PasswordAuthentication=no PermitRootLogin=prohibit-password
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_success "SSH 密码登录已禁用（仅密钥），并确认生效"
    elif [[ $rc -eq 3 ]]; then
        log_success "SSH 密码登录配置已写入（仅密钥）"
        log_warn "但 SSH 服务重启失败，请手动 systemctl restart sshd 使其生效。"
    else
        log_error "禁用未生效已回滚（rc=$rc），请 sshd -T 手动核对"
        return 1
    fi
}

# 新功能：一键关闭公钥登录（改用密码），带"锁死护栏"——多发行版首匹配生效。
disable_ssh_pubkey_login() {
    log_section "关闭 SSH 公钥登录 (仅密码)"
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    [[ -f "$SSHD_CONFIG" ]] || { log_error "SSH 配置文件不存在: $SSHD_CONFIG"; return 1; }

    echo ""
    echo -e "${CYAN}当前生效状态（sshd -T 回读）:${NC}"
    local pa pk prl
    pa="$(_ssh_effective PasswordAuthentication)"
    pk="$(_ssh_effective PubkeyAuthentication)"
    prl="$(_ssh_effective PermitRootLogin)"
    echo "  PubkeyAuthentication:   ${pk:-未知}"
    echo "  PasswordAuthentication: ${pa:-未知}"
    echo "  PermitRootLogin:        ${prl:-未知}"
    echo ""
    _ssh_has_match_block && log_warn "配置含 Match 块：sshd -T 读的是全局值，Match User/Address 里对密码/公钥的单独设置本工具看不到、也可能覆盖，请务必手动核对。"

    # 护栏一：关公钥后唯一入口是密码。密码开关必须生效；root 场景 PermitRootLogin 必须 yes（prohibit-password 连密码也挡）。
    local lockout=0
    [[ "$pa" != "yes" ]] && lockout=1
    if [[ "$(id -u)" == "0" ]]; then
        case "$prl" in yes) ;; *) lockout=1 ;; esac
    fi

    if [[ $lockout -eq 1 ]]; then
        echo -e "${RED}⚠️  危险：关闭公钥后只能靠密码登录——但当前密码登录不可用：${NC}"
        [[ "$pa" != "yes" ]] && echo -e "${RED}    · PasswordAuthentication = ${pa:-未知}（需为 yes）${NC}"
        if [[ "$(id -u)" == "0" ]]; then
            case "$prl" in yes) ;; *) echo -e "${RED}    · PermitRootLogin = ${prl:-未知}（root 需为 yes 才能用密码）${NC}" ;; esac
        fi
        echo -e "${RED}    现在直接关公钥 = 把自己锁死在门外。${NC}"
        echo ""
        echo "  1) 我先帮你开好密码登录（PermitRootLogin yes + PasswordAuthentication yes，回读确认），再关公钥"
        echo "  2) 取消"
        echo ""
        read -p "请选择 [1/2]: " ga
        case "$ga" in
            1)
                log_info "先开启密码登录..."
                ssh_apply_directives_effective PermitRootLogin=yes PasswordAuthentication=yes
                if [[ $? -ne 0 ]]; then
                    log_error "密码登录未能确认生效（或服务未重启），为避免锁死已中止关闭公钥。"
                    return 1
                fi
                ;;
            *)
                log_info "已取消，未改动任何配置。"
                return 0
                ;;
        esac
    fi

    # 护栏二（fail-closed·无论上面 lockout 与否都必过）：确认 root 真有可用密码，否则关公钥必锁死。
    if ! _ssh_require_usable_password; then
        return 1
    fi

    echo ""
    echo -e "${YELLOW}即将关闭公钥登录（PubkeyAuthentication no）。${RED}强烈建议：先另开一个新终端用密码登录验证能进，再断开当前会话！${NC}"
    read -p "确认关闭 SSH 公钥登录? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消操作"; return 0; }

    ssh_apply_directives_effective PubkeyAuthentication=no
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_success "SSH 公钥登录已关闭，仅允许密码登录（已回读确认生效）"
        echo -e "${CYAN}如需恢复：把 /etc/ssh/sshd_config.backup.aegistune.* 覆盖回去，或编辑 /etc/ssh/sshd_config.d/00-aegistune.conf 删掉 PubkeyAuthentication no，再 systemctl restart sshd${NC}"
    elif [[ $rc -eq 3 ]]; then
        log_success "SSH 公钥登录配置已写入（仅密码）"
        log_warn "但 SSH 服务重启失败，请手动 systemctl restart sshd 使其生效；生效前请勿断开当前会话。"
    else
        log_error "关闭公钥未生效已回滚（rc=$rc），请 sshd -T 手动核对"
        return 1
    fi
}

# SSH 登录方式子菜单（集中三个开关 + 顶部显示当前生效状态，防误锁）
ssh_login_method_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}── SSH 登录方式管理 ──${NC}"
        echo ""
        echo -e "${CYAN}当前生效（sshd -T）:${NC} 公钥=$(_ssh_effective PubkeyAuthentication || echo ?)  密码=$(_ssh_effective PasswordAuthentication || echo ?)  Root=$(_ssh_effective PermitRootLogin || echo ?)"
        echo ""
        echo -e "${GREEN}  1) 开启 SSH root 密码登录${NC}"
        echo -e "  2) 禁用 SSH 密码登录    (仅密钥)"
        echo -e "  3) 关闭 SSH 公钥登录    (仅密码，带锁死护栏)"
        echo -e "  0) 返回"
        echo ""
        read -p "请输入选择 [0-3]: " m
        case "$m" in
            1) detect_os && detect_init_system; configure_ssh_root_login; pause_return_main_menu ;;
            2) detect_os && detect_init_system; disable_ssh_password_login; pause_return_main_menu ;;
            3) detect_os && detect_init_system; disable_ssh_pubkey_login; pause_return_main_menu ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============ 帮助 ============

show_help() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║      AegisTune 网络优化助手 (BBR + BDP 缓冲 + 快照)          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  用法: sudo bash $0 [命令]                                   ║"
    echo "║  注: help / self-test / dry-run 可非 root 运行               ║"
    echo "║                                                              ║"
    echo "║  一键安装 / 快捷:                                            ║"
    echo "║    setup     - 一键安装(无需 git): 落地 /root/AegisTune      ║"
    echo "║    link      - 创建 aeg 短命令 (软链 /usr/local/bin/aeg)     ║"
    echo "║                                                              ║"
    echo "║  网络优化命令:                                               ║"
    echo "║    install   - 交互式安装 (FQ/CAKE，按 BDP 算缓冲)           ║"
    echo "║    uninstall - 卸载网络优化配置                              ║"
    echo "║    status    - 查看当前状态                                  ║"
    echo "║    snapshot  - 创建配置快照                                  ║"
    echo "║    rollback  - 从快照回滚                                    ║"
    echo "║    fq / cake - 快速装 BBR+FQ / BBR+CAKE (按 BDP 算缓冲)      ║"
    echo "║    self-test/dry-run - 预览 BDP 缓冲，不改系统               ║"
    echo "║    tools      - 快速补全 Docker Compose / FRPS               ║"
    echo "║    compose-install - 自动安装 Docker Compose                 ║"
    echo "║    frps-install - 下载并执行 FRPS 一键安装脚本               ║"
    echo "║    frps-uninstall - 下载并执行 FRPS 卸载脚本                 ║"
    echo "║    traffic-guard - 配置出站流量到量自动关机                  ║"
    echo "║    traffic-guard-status - 查看出站流量守护状态               ║"
    echo "║    traffic-guard-stop - 停止出站流量守护服务                 ║"
    echo "║    traffic-guard-remove - 移除出站流量守护服务和配置         ║"
    echo "║    reinstall  - 系统重装菜单 (DD/容器·高危擦盘不可逆)        ║"
    echo "║    dd / dd-container - 直接进 DD / 容器重装 (确认后执行)     ║"
    echo "║    reinstall-cmd - 只打印官方重装命令 (不执行)              ║"
    echo "║                                                              ║"
    echo "║  安全检查命令:                                               ║"
    echo "║    ssh        - 开启 SSH root 密码登录                       ║"
    echo "║    ssh-off    - 禁用 SSH 密码登录 (仅密钥)                   ║"
    echo "║    ssh-pubkey-off - 关闭 SSH 公钥登录 (仅密码·带护栏)        ║"
    echo "║    fail2ban   - 配置/启用 Fail2ban                           ║"
    echo "║    fail2ban-rm - 停用/移除 Fail2ban                          ║"
    echo "║    fail2ban-whitelist-add [IP] - 安全加入 ignoreip 白名单    ║"
    echo "║    fail2ban-whitelist-remove [IP] - 安全移除白名单条目       ║"
    echo "║    fail2ban-whitelist-list - 查看配置与运行期 ignoreip       ║"
    echo "║                                                              ║"
    echo "║    help       - 显示此帮助                                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============ 交互式菜单 ============

fail2ban_status_view() {
    log_section "Fail2ban 状态 / 封禁 IP"
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_warn "未检测到 fail2ban-client，Fail2ban 可能尚未安装（可用本菜单第 1 项安装）"
        return 0
    fi
    if service_is_active_any fail2ban; then
        log_success "fail2ban 服务运行中"
    else
        log_warn "fail2ban 服务未在运行"
    fi
    echo ""
    echo -e "${CYAN}--- fail2ban-client status ---${NC}"
    fail2ban-client status 2>/dev/null || log_warn "无法获取 Fail2ban 总览"
    echo ""
    local jails
    jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')
    if [[ -n "$jails" ]]; then
        for j in $jails; do
            [[ -z "$j" ]] && continue
            echo -e "${CYAN}--- jail: ${j} ---${NC}"
            fail2ban-client status "$j" 2>/dev/null
            echo ""
        done
    fi
}

# ============ 一级分类菜单 ============

show_bbr_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${CYAN}║            🚀  BBR 加速                       ║${NC}"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        print_system_status_card
        echo ""
        echo -e "${GREEN}  1) 一键 BBR + FQ        (推荐，通用低延迟)${NC}"
        echo -e "${GREEN}  2) 一键 BBR + CAKE      (更强整流，需内核支持)${NC}"
        echo -e "  3) 交互安装             (自选队列调度器)"
        echo -e "  4) 查看加速状态"
        echo -e "  5) 卸载网络优化"
        echo -e "  0) 返回主菜单"
        echo ""
        read -p "请输入选择 [0-5]: " bbr_choice
        case "$bbr_choice" in
            1) run_fq_install; pause_return_main_menu ;;
            2) run_cake_install; pause_return_main_menu ;;
            3) run_interactive_install; pause_return_main_menu ;;
            4) run_status_check; pause_return_main_menu ;;
            5) uninstall; pause_return_main_menu ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

show_tuning_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${CYAN}║            🎛   系统调优                       ║${NC}"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}  ── 备份 / 恢复 (落点 ${AEGIS_HOME}/backups) ──${NC}"
        echo -e "${GREEN}  1) 📦 备份当前配置${NC}"
        echo -e "${GREEN}  2) ♻  一键恢复          (从快照回滚)${NC}"
        echo -e "  3) 备份 / 快照列表"
        echo -e "${YELLOW}  ── 系统 ──${NC}"
        echo -e "  4) Swap 管理"
        echo -e "  0) 返回主菜单"
        echo ""
        read -p "请输入选择 [0-4]: " tune_choice
        case "$tune_choice" in
            1) create_config_snapshot "manual_backup"; pause_return_main_menu ;;
            2) restore_config_snapshot; pause_return_main_menu ;;
            3) list_config_snapshots; pause_return_main_menu ;;
            4) swap_menu; pause_return_main_menu ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

show_security_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${CYAN}║            🛡   安全防护                       ║${NC}"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}  ── Fail2ban ──${NC}"
        echo -e "${GREEN}  1) 启用 Fail2ban        (SSH 暴力破解防护)${NC}"
        echo -e "  2) 移除 Fail2ban"
        echo -e "  3) 查看封禁 IP / 状态"
        echo -e "  9) Fail2ban 白名单      (加白/移除/查看，安全写入防挂服务)"
        echo -e "${YELLOW}  ── SSH / 端口 ──${NC}"
        echo -e "  4) SSH 登录方式管理     (密码/密钥/公钥开关·带锁死护栏)"
        echo -e "  6) 常用端口检查/修复    (22/80/443)"
        echo -e "  7) 查看全部监听端口"
        echo -e "  8) 安全摘要检查         (SSH/端口/cron/authorized_keys)"
        echo -e "  0) 返回主菜单"
        echo ""
        read -p "请输入选择 [0-9]: " sec_choice
        case "$sec_choice" in
            1) install_fail2ban_basic; pause_return_main_menu ;;
            2) remove_fail2ban_basic; pause_return_main_menu ;;
            3) fail2ban_status_view; pause_return_main_menu ;;
            4) ssh_login_method_menu ;;
            6) check_common_ports; pause_return_main_menu ;;
            7) list_all_listening_ports; pause_return_main_menu ;;
            8) security_quick_check; pause_return_main_menu ;;
            9) fail2ban_whitelist_menu ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

show_maintenance_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        printf "%b\n" "${CYAN}║            🔧  系统维护                        ║${NC}"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  1) 工具补全             (Docker Compose / FRPS)"
        echo -e "  2) 出站流量守护         (到量自动关机)"
        echo -e "  3) 系统重装             (DD / 容器 · ${RED}高危擦盘${NC})"
        echo -e "  0) 返回主菜单"
        echo ""
        read -p "请输入选择 [0-3]: " maint_choice
        case "$maint_choice" in
            1) show_tools_menu ;;
            2) show_traffic_guard_menu ;;
            3) show_reinstall_menu ;;
            0) return 0 ;;
            *) log_error "无效选择"; sleep 1 ;;
        esac
    done
}

show_main_menu() {
    clear
    printf "%b\n" "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    printf "%b\n" "${CYAN}║        🛡   AegisTune  网络优化助手           ║${NC}"
    printf "%b\n" "${CYAN}║           自动挡调优，省心省力                ║${NC}"
    printf "%b\n" "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    print_system_status_card
    echo ""
    echo -e "${GREEN}  1) 🚀 BBR 加速${NC}          BBR / FQ·CAKE / 按 BDP 算缓冲"
    echo -e "${YELLOW}  2) 🎛  系统调优${NC}          备份 / 一键恢复 / Swap"
    echo -e "${MAGENTA}  3) 🛡  安全防护${NC}          Fail2ban / SSH / 端口"
    echo -e "${BLUE}  4) 🔧 系统维护${NC}          工具补全 / 出站守护"
    echo ""
    echo -e "  0) 退出"
    echo ""
    read -p "请输入选择 [0-4/q]: " menu_choice

    case "$menu_choice" in
        1) show_bbr_menu ;;
        2) show_tuning_menu ;;
        3) show_security_menu ;;
        4) show_maintenance_menu ;;
        0|q|Q)
            echo -e "${GREEN}再见！${NC}"
            exit 0
            ;;
        *)
            log_error "无效选择"
            sleep 1
            ;;
    esac
}

run_fq_install() {
    QDISC_CHOICE="fq"
    echo -e "${CYAN}安装模式: BBR + FQ${NC}"
    detect_os && detect_pkg_manager && detect_init_system && detect_kernel
    check_bbr_support && check_qdisc_support
    create_config_snapshot "before_fq_install"
    update_pkg_cache && install_dependencies
    install_kernel_modules && configure_sysctl
    verify_installation && show_final_message
}

run_cake_install() {
    QDISC_CHOICE="cake"
    echo -e "${CYAN}安装模式: BBR + CAKE${NC}"
    detect_os && detect_pkg_manager && detect_init_system && detect_kernel
    check_bbr_support && check_qdisc_support
    create_config_snapshot "before_cake_install"

    if [[ $CAKE_AVAILABLE -eq 0 ]]; then
        install_cake_module
    fi

    update_pkg_cache && install_dependencies
    install_kernel_modules && configure_sysctl
    verify_installation && show_final_message
}

run_interactive_install() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║      AegisTune 网络优化助手 (BBR + BDP 缓冲 + 快照)          ║"
    echo "║      自动挡调优，省心省力                                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    detect_os
    detect_pkg_manager
    detect_init_system
    detect_kernel
    check_bbr_support
    check_qdisc_support
    
    # 用户选择队列调度器
    if ! show_qdisc_menu; then
        return 0
    fi


    create_config_snapshot "before_interactive_install_${QDISC_CHOICE}"
    
    update_pkg_cache
    install_dependencies
    install_kernel_modules
    configure_sysctl
    verify_installation
    show_final_message
}

run_status_check() {
    detect_os && detect_pkg_manager && detect_init_system && detect_kernel
    check_bbr_support && check_qdisc_support
    verify_installation
}

# ============ 主函数 ============

main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            help|--help|-h|self-test|dry-run)
                ;;
            *)
                check_root
                ;;
        esac
    else
        check_root
    fi
    
    # 如果没有参数，显示交互式菜单
    if [[ $# -eq 0 ]]; then
        while true; do
            show_main_menu
        done
        exit 0
    fi
    
    case "$1" in
        install)
            run_interactive_install
            ;;
        
        fq)
            QDISC_CHOICE="fq"
            echo -e "${CYAN}快速安装模式: BBR + FQ${NC}"
            detect_os && detect_pkg_manager && detect_init_system && detect_kernel
            check_bbr_support && check_qdisc_support
            create_config_snapshot "before_cli_fq_install"
            update_pkg_cache && install_dependencies
            install_kernel_modules && configure_sysctl
            verify_installation && show_final_message
            ;;
        
        cake)
            QDISC_CHOICE="cake"
            echo -e "${CYAN}快速安装模式: BBR + CAKE${NC}"
            detect_os && detect_pkg_manager && detect_init_system && detect_kernel
            check_bbr_support && check_qdisc_support
            create_config_snapshot "before_cli_cake_install"

            if [[ $CAKE_AVAILABLE -eq 0 ]]; then
                install_cake_module
            fi
            
            update_pkg_cache && install_dependencies
            install_kernel_modules && configure_sysctl
            verify_installation && show_final_message
            ;;
        
        uninstall|remove)
            uninstall
            ;;
        
        status|check)
            detect_os && detect_pkg_manager && detect_init_system && detect_kernel
            check_bbr_support && check_qdisc_support
            verify_installation
            ;;

        snapshot|snapshot-create)
            create_config_snapshot "manual_cli_snapshot"
            ;;

        rollback|snapshot-rollback)
            restore_config_snapshot
            ;;

        snapshots|snapshot-list)
            list_config_snapshots
            ;;


        fail2ban)
            install_fail2ban_basic
            ;;

        fail2ban-rm|fail2ban-remove)
            remove_fail2ban_basic
            ;;

        fail2ban-whitelist-add)
            fail2ban_whitelist_add "${2:-}"
            ;;

        fail2ban-whitelist-remove)
            fail2ban_whitelist_remove "${2:-}"
            ;;

        fail2ban-whitelist-list)
            fail2ban_whitelist_view
            ;;


        tools|tooling|quick-tools)
            show_tools_menu
            ;;

        compose-install|docker-compose|docker-compose-install)
            install_docker_compose_tool
            ;;

        frps-install|frp-install)
            install_frps_onekey
            ;;

        frps-uninstall|frps-remove|frp-uninstall|frp-remove)
            uninstall_frps_onekey
            ;;

        traffic-guard|egress-guard|net-traffic-guard)
            detect_init_system
            traffic_guard_setup_interactive
            ;;

        reinstall|sys-reinstall|dd-menu)
            show_reinstall_menu
            ;;

        dd|dd-reinstall)
            run_dd_reinstall exec
            ;;

        dd-print|dd-cmd)
            run_dd_reinstall print
            ;;

        dd-container|container-reinstall|osmutation)
            run_container_reinstall exec
            ;;

        reinstall-cmd|dd-list)
            reinstall_show_commands
            ;;

        traffic-guard-menu|traffic-menu)
            show_traffic_guard_menu
            ;;

        traffic-guard-status|egress-guard-status)
            traffic_guard_print_status
            ;;

        traffic-guard-stop|egress-guard-stop)
            detect_init_system
            traffic_guard_stop_service
            ;;

        traffic-guard-remove|traffic-guard-rm|egress-guard-remove)
            detect_init_system
            traffic_guard_remove
            ;;


















        self-test|dry-run|auto-self-test|auto-dry-run)
            run_self_test_dry_run
            ;;





        
        ssh)
            detect_os && detect_init_system
            configure_ssh_root_login
            ;;
        
        ssh-off|ssh-disable)
            detect_os && detect_init_system
            disable_ssh_password_login
            ;;

        ssh-pubkey-off|ssh-key-off|pubkey-off)
            detect_os && detect_init_system
            disable_ssh_pubkey_login
            ;;

        setup|bootstrap|self-install|install-self)
            run_bootstrap_setup
            ;;

        link|install-cmd|aeg-install)
            install_launcher_cmd
            ;;

        help|--help|-h)
            show_help
            ;;
        
        *)
            log_error "未知命令: $1"
            show_help
            exit 1
            ;;
    esac
}

# 把当前脚本持久化到品牌家目录 $AEGIS_HOME/aegistune.sh。
# 两种来源：① $0 是本地真实文件 → 复制；② 管道运行(bash <(curl...)/curl|bash) 无实体文件 → 从 RAW_URL 下载。
# 结果写入全局 PERSISTED_SELF_PATH（不用 stdout 捕获，避免 log_* 输出污染）。
persist_self_to_home() {
    local dest="${AEGIS_HOME}/aegistune.sh"
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    mkdir -p "$AEGIS_HOME" 2>/dev/null || true

    if [[ -f "$self" && -r "$self" ]]; then
        # 已在目标位置就不自我覆盖
        if [[ "$self" != "$dest" ]]; then
            if ! cp -f "$self" "$dest"; then
                log_error "复制脚本到 $dest 失败"
                return 1
            fi
        fi
    else
        # 管道/进程替换运行，本地无实体文件 → 从远端拉取
        log_info "未检测到本地脚本文件（管道运行），正在从远端拉取到 $dest ..."
        if ! download_file "$AEGIS_RAW_URL" "$dest"; then
            log_error "下载脚本失败：$AEGIS_RAW_URL（需要 curl 或 wget，且网络可达）"
            return 1
        fi
    fi

    chmod +x "$dest" 2>/dev/null || true
    PERSISTED_SELF_PATH="$dest"
    return 0
}

# 一键安装 setup：无需 git，把脚本落地到 /root/AegisTune 并装好 aeg 短命令。
run_bootstrap_setup() {
    log_section "AegisTune 一键安装"
    if ! persist_self_to_home; then
        log_error "安装失败：无法把脚本落地到 ${AEGIS_HOME}"
        return 1
    fi
    log_success "脚本已安装到：${PERSISTED_SELF_PATH}"

    if ln -sf "$PERSISTED_SELF_PATH" /usr/local/bin/aeg 2>/dev/null; then
        log_success "短命令已就绪：以后任意目录输入 'aeg' 即可唤起菜单"
    else
        log_warn "短命令 aeg 创建失败（/usr/local/bin 不可写？）稍后可手动运行：${PERSISTED_SELF_PATH} link"
    fi

    echo ""
    log_info "安装完成，下一步任选其一："
    echo -e "  ${GREEN}aeg${NC}                          # 唤起交互式主菜单"
    echo -e "  ${GREEN}${PERSISTED_SELF_PATH} status${NC}   # 只看当前状态"
    echo ""

    # 交互终端里直接进主菜单；非交互(如 curl|bash)只给提示不自动进
    if [ -t 0 ]; then
        log_info "即将进入主菜单（Ctrl+C 可退出）..."
        exec "$PERSISTED_SELF_PATH"
    fi
    return 0
}

# 创建 aeg 短命令：软链脚本到 /usr/local/bin/aeg，之后输入 aeg 即可唤起菜单
install_launcher_cmd() {
    local target="/usr/local/bin/aeg"
    local self
    self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    if [[ ! -f "$self" || ! -r "$self" ]]; then
        # 管道运行等无实体文件场景：先把脚本落地到品牌家目录再软链
        if persist_self_to_home; then
            self="$PERSISTED_SELF_PATH"
        else
            log_error "无法定位脚本自身路径，短命令创建失败"
            return 1
        fi
    fi
    chmod +x "$self" 2>/dev/null || true
    if ln -sf "$self" "$target" 2>/dev/null; then
        log_success "短命令已创建：现在输入 'aeg' 即可唤起菜单 (aeg -> $self)"
    else
        log_error "创建 $target 失败（需 root，且 /usr/local/bin 可写）"
        return 1
    fi
}

main "$@"
