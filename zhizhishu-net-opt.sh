#!/bin/bash

# =========================================================
# AegisTune / zhizhishu 网络优化助手（BBR + 扩展模块 + 快照）
# 支持: Ubuntu / Debian / Alpine Linux
# 功能: 环境检测 + BBR + CAKE/FQ 安装 + 扩展模块管理 + 快照回滚 + 安全检查
# 备注: zhizhishu 开发整合
# =========================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============ 通用工具 ============ 

get_ssh_port() {
    local port
    port=$(grep -E "^Port" /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
    [[ -z "$port" ]] && port=22
    echo "$port"
}

# 避坑：防止将 brutal 设为全局拥塞控制
ensure_brutal_not_default() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$cc" == "brutal" ]]; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        echo "net.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-cc.conf
        sysctl --system >/dev/null 2>&1 || true
        log_warn "检测到默认拥塞控制为 brutal，已改回 bbr 以避免全局 1MB/s 限速。"
    fi
}

warn_brutal_usage() {
    if is_tcp_brutal_loaded; then
        log_warn "已加载 brutal 模块：请勿将其设为全局拥塞控制，仅在支持的应用中按需启用（如 sing-box/mihomo 的 brutal、brutal-nginx）。"
        log_info "如遇异常或不再需要，可在主菜单 5 的扩展管理中彻底删除 brutal 模块。"
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
SNAPSHOT_ROOT="/var/backups/zhizhishu-net-opt"
PROVIDER_BASELINE_FILE="${SNAPSHOT_ROOT}/provider-baseline.sysctl"
PROVIDER_BASELINE_META="${SNAPSHOT_ROOT}/provider-baseline.meta"
PROVIDER_BASELINE_SOURCEMAP="${SNAPSHOT_ROOT}/provider-baseline-sources.map"
SERVERSPAN_API_URL="https://www.serverspan.com/tools/api/sysctl_api.php"
SERVERSPAN_WEB_URL="https://www.serverspan.com/en/tools/sysctl"
SERVERSPAN_SYSCTL_FILE="/etc/sysctl.d/99-zhizhishu-serverspan.conf"
FORWARDING_OVERLAY_FILE="/etc/sysctl.d/99-zhizhishu-forwarding.conf"
PROVIDER_RESTORE_FILE="/etc/sysctl.d/99-zhizhishu-provider-baseline-restore.conf"
SERVERSPAN_LAST_API_HTTP_CODE=""
SERVERSPAN_LAST_WEB_HTTP_CODE=""

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

service_reload_or_restart_any() {
    local manager
    manager="$(get_service_manager)"

    if [[ "$manager" == "systemd" ]]; then
        service_action_any reload "$@" || service_action_any restart "$@"
        return $?
    fi

    service_action_any restart "$@"
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

is_bpftune_running() {
    if service_is_active_any bpftune; then
        return 0
    fi
    if pgrep -x bpftune >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

is_bpftune_installed() {
    command -v bpftune >/dev/null 2>&1
}

is_tcp_brutal_loaded() {
    lsmod | grep -q "^brutal"
}

is_tcp_brutal_installed() {
    find /lib/modules -type f -name "brutal.ko*" 2>/dev/null | grep -q .
}

is_brutal_nginx_installed() {
    [[ -f /etc/nginx/modules/ngx_http_tcp_brutal_module.so ]]
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

check_bpf_support() {
    log_section "eBPF 支持检测"
    
    # 挂载 BPF 文件系统
    if ! mount | grep -q "type bpf"; then
        mkdir -p /sys/fs/bpf 2>/dev/null || true
        mount -t bpf bpf /sys/fs/bpf 2>/dev/null || true
    fi
    
    if mount | grep -q "type bpf"; then
        log_success "BPF 文件系统已挂载"
    else
        log_warn "BPF 文件系统挂载失败"
    fi
    
    if [[ -f /sys/kernel/btf/vmlinux ]]; then
        log_success "BTF (BPF Type Format) 支持可用"
    else
        log_warn "BTF 不可用，bpftune 可能无法工作"
    fi
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
            apt-get install -y -qq curl wget ca-certificates gnupg bc
            ;;
        apk)
            apk add --quiet curl wget ca-certificates bc
            ;;
        dnf|yum)
            $PKG_MANAGER install -y -q curl wget ca-certificates gnupg bc
            ;;
    esac
    
    log_success "依赖安装完成"
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
    
    # 立即加载模块
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    [[ "$QDISC_CHOICE" == "cake" ]] && modprobe sch_cake 2>/dev/null || true
    
    log_success "内核模块配置完成"
}

configure_sysctl() {
    log_section "配置 BBR + $QDISC_CHOICE"
    
    local CONFIG_CONTENT="# ================================================
# BBR + ${QDISC_CHOICE^^} 网络优化配置
# 生成时间: $(date)
# ================================================

# === 拥塞控制 ===
net.core.default_qdisc = $QDISC_CHOICE
net.ipv4.tcp_congestion_control = bbr

# === 协议栈优化 ===
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# === 连接管理 ===
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# === 由 bpftune 自动调整的参数 (不设固定值) ===
# net.core.rmem_max - bpftune 自动调整
# net.core.wmem_max - bpftune 自动调整
# net.ipv4.tcp_rmem - bpftune 自动调整
# net.ipv4.tcp_wmem - bpftune 自动调整

# === 系统保护 ===
kernel.panic = 10
vm.swappiness = 10
fs.file-max = 1000000"

    # 写入 sysctl.d 目录
    mkdir -p /etc/sysctl.d
    echo "$CONFIG_CONTENT" > /etc/sysctl.d/99-bbr-tuning.conf
    
    # Alpine 兼容：同时写入主配置文件
    if [[ "$OS_TYPE" == "alpine" ]]; then
        # 备份原配置
        [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf /etc/sysctl.conf.backup 2>/dev/null || true
        echo "$CONFIG_CONTENT" >> /etc/sysctl.conf
    fi
    
    # 应用配置 (兼容多种系统)
    sysctl -p /etc/sysctl.d/99-bbr-tuning.conf 2>/dev/null || \
    sysctl -p /etc/sysctl.conf 2>/dev/null || \
    sysctl --system 2>/dev/null || true
    
    log_success "BBR + $QDISC_CHOICE 配置完成"
}

apply_aggressive_sysctl_overlay() {
    # 动态计算更高的缓冲上限：约 MemAvailable/16，范围 [16MB, 64MB]
    local avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local target=$((avail_kb * 1024 / 16))
    local floor=$((16 * 1024 * 1024))
    local cap=$((64 * 1024 * 1024))
    if (( target < floor )); then target=$floor; fi
    if (( target > cap )); then target=$cap; fi

    local rmem_max=$target
    local wmem_max=$target
    local rmem_def=$((rmem_max / 4))
    local wmem_def=$((wmem_max / 4))

    cat > /etc/sysctl.d/99-bbr-aggressive.conf <<EOF
# zhizhishu 动态缓冲上限 (bpftune 叠加) - 运行时计算
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.rmem_default = $rmem_def
net.core.wmem_default = $wmem_def
net.ipv4.tcp_rmem = 4096 $rmem_def $rmem_max
net.ipv4.tcp_wmem = 4096 $wmem_def $wmem_max
EOF

    sysctl -p /etc/sysctl.d/99-bbr-aggressive.conf 2>/dev/null || true
    log_info "已应用动态缓冲上限 (约 MemAvailable/16，封顶 64MB)"
}

install_bpftune() {
    log_section "安装 bpftune"
    
    # 检查是否已安装
    if command -v bpftune &> /dev/null; then
        log_success "bpftune 已安装: $(bpftune -V 2>/dev/null || echo 'installed')"
        return 0
    fi
    
    case $PKG_MANAGER in
        apt)
            # 优先从官方仓库安装
            if apt-cache show bpftune &> /dev/null; then
                log_info "从官方仓库安装 bpftune..."
                apt-get install -y -qq bpftune
            else
                log_info "官方仓库无 bpftune，尝试从源码编译..."
                install_bpftune_from_source
            fi
            ;;
        apk)
            log_info "Alpine: 尝试从源码编译 bpftune..."
            install_bpftune_from_source
            ;;
        dnf|yum)
            log_info "RPM 系: 尝试从源码编译 bpftune..."
            install_bpftune_from_source
            ;;
    esac
    
    if command -v bpftune &> /dev/null; then
        log_success "bpftune 安装成功"
    else
        log_warn "bpftune 安装失败，使用静态缓冲区配置"
        configure_static_buffers
    fi
}

install_bpftune_from_source() {
    # 清理函数，确保无论成功或失败都删除临时构建目录与残留服务
    rollback_bpftune_install() {
        rm -f /usr/sbin/bpftune /usr/local/sbin/bpftune /usr/bin/bpftune
        rm -f /lib/systemd/system/bpftune.service /etc/systemd/system/bpftune.service
        service_daemon_reload
    }

    cleanup_build_cache() {
        case $PKG_MANAGER in
            apt)
                apt-get clean >/dev/null 2>&1 || true
                ;;
            apk)
                apk cache clean >/dev/null 2>&1 || true
                ;;
            dnf|yum)
                $PKG_MANAGER clean all >/dev/null 2>&1 || true
                ;;
        esac
    }

    # Alpine 低内存环境临时 swap，避免编译被 OOM 杀
    local TEMP_SWAP=""
    ensure_temp_swap_for_build() {
        if [[ "$PKG_MANAGER" == "apk" ]]; then
            if ! swapon --show | grep -q '^'; then
                TEMP_SWAP="/tmp/bpftune.swap"
                log_info "检测到无 swap，为编译临时创建 1G swap..."
                fallocate -l 1024M "$TEMP_SWAP" 2>/dev/null || dd if=/dev/zero of="$TEMP_SWAP" bs=1M count=1024
                chmod 600 "$TEMP_SWAP"
                mkswap "$TEMP_SWAP" >/dev/null 2>&1 && swapon "$TEMP_SWAP" >/dev/null 2>&1 || TEMP_SWAP=""
            fi
        fi
    }

    cleanup_temp_swap() {
        if [[ -n "$TEMP_SWAP" ]]; then
            swapoff "$TEMP_SWAP" 2>/dev/null || true
            rm -f "$TEMP_SWAP"
        fi
    }

    build_bpftool_alpine() {
        local bdir="/tmp/bpftool-src"
        local blog="/tmp/bpftool-build.log"
        rm -rf "$bdir" "$blog"
        apk add --quiet --no-cache \
            build-base clang llvm lld pkgconf linux-headers \
            elfutils-dev zlib-dev bison flex libcap-dev 2>>"$blog" || true
        if git clone --depth 1 https://github.com/libbpf/bpftool.git "$bdir" >>"$blog" 2>&1; then
            make -C "$bdir/src" install PREFIX=/usr >>"$blog" 2>&1 || true
        fi
        if ! command -v bpftool >/dev/null 2>&1; then
            log_warn "bpftool 构建失败，日志尾部："
            tail -n 20 "$blog" 2>/dev/null || true
            log_info "完整日志: $blog"
        fi
        rm -rf "$bdir"
    }

    # 安装编译依赖
    case $PKG_MANAGER in
        apt)
            apt-get install -y -qq \
                build-essential git libbpf-dev libnl-3-dev \
                libnl-genl-3-dev libnl-route-3-dev pkg-config \
                clang llvm libelf-dev bpftool python3-docutils \
                python3-yaml libyaml-dev libxml2-dev 2>/dev/null || true
            apt-get install -y -qq libcap-dev 2>/dev/null || true

            # 确保 bpftool 可用，否则 bpftune 编译会失败
            if ! command -v bpftool &> /dev/null; then
                log_warn "bpftool 缺失，尝试单独安装..."
                apt-get install -y -qq bpftool 2>/dev/null || true
            fi
            ;;
        apk)
            # Alpine: 若缺 BTF，bpftune 运行有限；提前告警
            if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
                log_warn "Alpine: 未发现 /sys/kernel/btf/vmlinux，bpftune 功能可能受限或编译失败，将尝试编译，失败则回退静态配置"
            fi

            apk add --quiet --no-cache \
                build-base git clang llvm lld pkgconf \
                linux-headers bpftool libbpf-dev elfutils-dev \
                py3-docutils py3-yaml libyaml-dev libxml2-dev \
                libcap-dev libelf-static zlib-static 2>/dev/null || true

            # Alpine 确认 bpftool
            if ! command -v bpftool &> /dev/null; then
            log_warn "bpftool 在 Alpine 不可用，尝试源码构建..."
            build_bpftool_alpine
        fi

        if ! command -v bpftool &> /dev/null; then
            log_warn "bpftool 仍不可用，跳过 bpftune 编译（保持静态配置）。参考 /tmp/bpftool-build.log 查看详情。"
            return 0
        fi
            ;;
        dnf|yum)
            $PKG_MANAGER -y -q install \
                git gcc make clang llvm pkg-config bpftool \
                libbpf-devel libnl3-devel libcap-devel elfutils-libelf-devel \
                libyaml-devel libxml2-devel python3-docutils python3-pyyaml 2>/dev/null || true
            $PKG_MANAGER -y -q install kernel-devel kernel-headers 2>/dev/null || true
            if ! command -v bpftool &> /dev/null; then
                log_warn "bpftool 不可用，跳过 bpftune 编译，改用静态缓冲配置"
                configure_static_buffers
                return 0
            fi
            ;;
    esac

    if ! command -v bpftool &> /dev/null; then
        log_warn "bpftool 仍不可用，跳过 bpftune 编译，改用静态缓冲配置"
        configure_static_buffers
        return 0
    fi

    ensure_temp_swap_for_build

    # 尝试安装内核头文件
    case $PKG_MANAGER in
        apt)
            apt-get install -y -qq linux-headers-$(uname -r) 2>/dev/null || \
            apt-get install -y -qq linux-headers-generic 2>/dev/null || true
            ;;
        apk)
            # linux-headers 已在上方尝试安装；Alpine 无 generic 兜底
            true
            ;;
        dnf|yum)
            $PKG_MANAGER -y -q install kernel-devel kernel-headers 2>/dev/null || true
            ;;
    esac

    local build_dir="/tmp/bpftune-build"
    local build_log="/tmp/bpftune-build.log"
    rm -rf "$build_dir"
    trap 'rm -rf "$build_dir"' EXIT
    
    if git clone --depth 1 https://github.com/oracle/bpftune.git "$build_dir" 2>/dev/null; then
        cd "$build_dir"
        : > "$build_log"
        local jobs=$(nproc)
        [[ "$PKG_MANAGER" == "apk" ]] && jobs=1
        if make -j${jobs} >>"$build_log" 2>&1 && make install >>"$build_log" 2>&1; then
            log_success "bpftune 从源码编译成功"
        else
            log_warn "bpftune 编译失败，回滚并使用静态缓冲配置"
            log_info "编译日志尾部（/tmp/bpftune-build.log）:"
            tail -n 20 "$build_log" 2>/dev/null || true
            rollback_bpftune_install
            configure_static_buffers
            cleanup_build_cache
        fi
        cd /
    else
        log_warn "git 克隆 bpftune 失败，尝试下载 tarball..."
        local tarball="/tmp/bpftune.tar.gz"
        rm -f "$tarball" && rm -rf "$build_dir"
        if curl -fsSL https://github.com/oracle/bpftune/archive/refs/heads/master.tar.gz -o "$tarball"; then
            local extracted
            extracted=$(tar -tzf "$tarball" | head -1 | cut -d/ -f1)
            tar -xzf "$tarball" -C /tmp
            mv "/tmp/$extracted" "$build_dir" 2>/dev/null || true
            if [[ -d "$build_dir" ]]; then
                cd "$build_dir"
                : > "$build_log"
                if make -j$(nproc) >>"$build_log" 2>&1 && make install >>"$build_log" 2>&1; then
                    log_success "bpftune 从 tarball 编译成功"
                else
                    log_warn "bpftune 编译失败，回滚并使用静态缓冲配置"
                    log_info "编译日志尾部（/tmp/bpftune-build.log）:"
                    tail -n 20 "$build_log" 2>/dev/null || true
                    rollback_bpftune_install
                    configure_static_buffers
                    cleanup_build_cache
                fi
                cd /
            else
                log_warn "tarball 展开失败，使用静态缓冲配置"
                rollback_bpftune_install
                configure_static_buffers
                cleanup_build_cache
            fi
        else
            log_warn "无法下载 bpftune 源码，使用静态缓冲配置"
            rollback_bpftune_install
            configure_static_buffers
            cleanup_build_cache
        fi
    fi
    
    # 主动清理构建目录
    rm -rf "$build_dir"
    cleanup_build_cache
}

# ============ TCP Brutal (hy2) ============ 
# 需要内核 >=4.9，建议 >=5.8；构建需要内核头、git、编译链。

check_tcp_brutal_status() {
    if is_tcp_brutal_loaded; then
        echo -e "${CYAN}│${NC}  TCP Brutal:   ${GREEN}已加载模块 (brutal)${NC}"
    elif is_tcp_brutal_installed; then
        echo -e "${CYAN}│${NC}  TCP Brutal:   ${YELLOW}已安装但未加载${NC}"
    else
        echo -e "${CYAN}│${NC}  TCP Brutal:   ${YELLOW}未加载/未安装${NC}"
    fi
}

install_tcp_brutal() {
    log_section "安装/编译 TCP Brutal (hy2)"
    ensure_brutal_not_default
    detect_os
    detect_pkg_manager
    detect_kernel

    cleanup_brutal_cache() {
        case $PKG_MANAGER in
            apt) apt-get clean >/dev/null 2>&1 || true ;;
            apk) apk cache clean >/dev/null 2>&1 || true ;;
        esac
    }

    rollback_brutal_install() {
        # 卸载已加载模块并删除可能安装的 ko 文件
        remove_tcp_brutal
        cleanup_brutal_cache
    }

    case $PKG_MANAGER in
        apt)
            apt-get update -qq
            apt-get install -y -qq git build-essential 2>/dev/null || true
            # 优先安装当前运行内核的头文件与镜像（确保 build 目录存在）
            apt-get install -y -qq linux-headers-$(uname -r) linux-image-$(uname -r) 2>/dev/null || true
            # 若仍缺，再尝试通用元包，可能会安装新内核，需重启后重试
            if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
                apt-get install -y -qq linux-headers-amd64 linux-image-amd64 2>/dev/null || true
            fi
            ;;
        apk)
            apk add --quiet --no-cache git build-base linux-headers 2>/dev/null || true
            ;;
        dnf|yum)
            $PKG_MANAGER -y -q install git gcc make clang llvm kernel-devel kernel-headers elfutils-libelf-devel bpftool 2>/dev/null || true
            ;;
    esac

    local build_dir="/tmp/tcp-brutal"
    local build_log="/tmp/tcp-brutal-build.log"
    rm -rf "$build_dir"
    : > "$build_log"

    # 若头文件依旧缺失，直接提示并退出
    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        local running_kver
        running_kver="$(uname -r)"
        local latest_kver=""
        latest_kver="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
        log_warn "未找到内核头文件目录 /lib/modules/${running_kver}/build，请先安装匹配内核头或重启到已安装的新内核。"
        {
            echo "建议:"
            echo "1) apt-get install linux-headers-${running_kver}"
            echo "2) 若已安装新内核且有 /lib/modules/${latest_kver}/build，可重启后再运行"
            echo "3) 确认 /lib/modules/\$(uname -r)/build 存在后重试"
            echo "4) 如 meta 包已装（linux-image-amd64 / linux-headers-amd64），请重启以启用新内核后再运行"
        } | tee -a "$build_log"
        cleanup_brutal_cache
        return 1
    fi
    if ! git clone --depth 1 https://github.com/apernet/tcp-brutal.git "$build_dir" >>"$build_log" 2>&1; then
        log_warn "无法克隆 tcp-brutal 仓库"
        cleanup_brutal_cache
        return 1
    fi

    pushd "$build_dir" >/dev/null
    if make -C /lib/modules/$(uname -r)/build M="$build_dir" modules >>"$build_log" 2>&1; then
        # 直接 insmod 避免 Makefile 里的 sudo 依赖
        if insmod "$build_dir/brutal.ko" >>"$build_log" 2>&1; then
            depmod -a 2>/dev/null || true
            log_success "TCP Brutal 编译并加载成功 (模块名: brutal)"
            log_info "注意：不要将 brutal 设为全局拥塞控制，仅在支持的应用中按需启用。"
            warn_brutal_usage
        else
            log_warn "TCP Brutal 编译成功但加载失败，查看 /tmp/tcp-brutal-build.log 获取详情"
            rollback_brutal_install
            popd >/dev/null
            rm -rf "$build_dir"
            return 1
        fi
    else
        log_warn "TCP Brutal 编译失败，查看 /tmp/tcp-brutal-build.log 获取详情"
        rollback_brutal_install
        popd >/dev/null
        rm -rf "$build_dir"
        return 1
    fi
    popd >/dev/null
    rm -rf "$build_dir"
    cleanup_brutal_cache
}

remove_tcp_brutal() {
    log_section "卸载/停用 TCP Brutal"
    local was_loaded=0
    local was_installed=0

    is_tcp_brutal_loaded && was_loaded=1
    is_tcp_brutal_installed && was_installed=1

    if is_tcp_brutal_loaded; then
        modprobe -r brutal 2>/dev/null || rmmod brutal 2>/dev/null || true
    fi
    # 清理可能的已安装模块文件
    find /lib/modules -type f -name "brutal.ko*" -delete 2>/dev/null || true
    depmod -a 2>/dev/null || true

    if is_tcp_brutal_loaded || is_tcp_brutal_installed; then
        log_warn "TCP Brutal 仍检测到残留，请手动检查 /lib/modules 与 lsmod"
        return 1
    fi

    if [[ $was_loaded -eq 0 && $was_installed -eq 0 ]]; then
        log_info "未检测到 TCP Brutal，已完成残留文件清理检查"
    else
        log_success "TCP Brutal 已彻底清理完成"
    fi
}

# ============ brutal-nginx 动态模块 (针对 nginx 动态模块) ============

install_brutal_nginx_module() {
    log_section "安装 brutal-nginx 动态模块"

    detect_os
    detect_pkg_manager

    cleanup_brutal_nginx_cache() {
        case $PKG_MANAGER in
            apt) apt-get clean >/dev/null 2>&1 || true ;;
            apk) apk cache clean >/dev/null 2>&1 || true ;;
        esac
    }

    rollback_brutal_nginx() {
        rm -f /etc/nginx/modules/ngx_http_tcp_brutal_module.so
        # 清理配置中的 load_module 行
        if [[ -f /etc/nginx/nginx.conf ]]; then
            sed -i '/ngx_http_tcp_brutal_module.so/d' /etc/nginx/nginx.conf
        fi
        cleanup_brutal_nginx_cache
    }

    case $PKG_MANAGER in
        apt)
            apt-get update -qq
            apt-get install -y -qq nginx git build-essential libpcre3-dev zlib1g-dev libssl-dev wget curl 2>/dev/null || true
            ;;
        apk)
            apk add --quiet --no-cache nginx git build-base pcre-dev zlib-dev openssl-dev wget curl 2>/dev/null || true
            ;;
    esac

    if ! command -v nginx >/dev/null; then
        log_warn "未检测到 nginx，可手动安装后重试"
        cleanup_brutal_nginx_cache
        return 1
    fi

    local nginx_ver
    nginx_ver=$(nginx -v 2>&1 | sed 's#.*/##' | sed 's/nginx\///')
    if [[ -z "$nginx_ver" ]]; then
        log_warn "无法获取 nginx 版本"
        cleanup_brutal_nginx_cache
        return 1
    fi

    local build_dir="/tmp/brutal-nginx"
    local nginx_src="/tmp/nginx-${nginx_ver}"
    local build_log="/tmp/brutal-nginx-build.log"
    rm -rf "$build_dir" "$nginx_src"
    : > "$build_log"

    if ! git clone --depth 1 https://github.com/sduoduo233/brutal-nginx.git "$build_dir" >>"$build_log" 2>&1; then
        log_warn "克隆 brutal-nginx 失败，查看日志 $build_log"
        cleanup_brutal_nginx_cache
        return 1
    fi

    if ! curl -fsSL "http://nginx.org/download/nginx-${nginx_ver}.tar.gz" -o "/tmp/nginx-${nginx_ver}.tar.gz"; then
        log_warn "下载 nginx 源码失败"
        rollback_brutal_nginx
        return 1
    fi

    if ! tar -xf "/tmp/nginx-${nginx_ver}.tar.gz" -C /tmp; then
        log_warn "解压 nginx 源码失败"
        rollback_brutal_nginx
        return 1
    fi

    pushd "$nginx_src" >/dev/null
    if ./configure --with-compat --add-dynamic-module="$build_dir" >>"$build_log" 2>&1 && make modules >>"$build_log" 2>&1; then
        mkdir -p /etc/nginx/modules
        cp objs/ngx_http_tcp_brutal_module.so /etc/nginx/modules/ 2>/dev/null || true
        if [[ ! -f /etc/nginx/modules/ngx_http_tcp_brutal_module.so ]]; then
            log_warn "未找到编译生成的模块文件，查看 $build_log"
            rollback_brutal_nginx
            popd >/dev/null
            rm -rf "$build_dir" "$nginx_src" "/tmp/nginx-${nginx_ver}.tar.gz"
            return 1
        fi
        if ! grep -q "ngx_http_tcp_brutal_module.so" /etc/nginx/nginx.conf 2>/dev/null; then
            sed -i '1iload_module /etc/nginx/modules/ngx_http_tcp_brutal_module.so;' /etc/nginx/nginx.conf
        fi
        service_reload_or_restart_any nginx || nginx -s reload 2>/dev/null || true
        log_success "brutal-nginx 模块安装完成 (ngx_http_tcp_brutal_module.so)"
    else
        log_warn "brutal-nginx 模块编译失败，查看 $build_log"
        rollback_brutal_nginx
        popd >/dev/null
        rm -rf "$build_dir" "$nginx_src" "/tmp/nginx-${nginx_ver}.tar.gz"
        return 1
    fi
    popd >/dev/null
    rm -rf "$build_dir" "$nginx_src" "/tmp/nginx-${nginx_ver}.tar.gz"
    cleanup_brutal_nginx_cache
}

remove_brutal_nginx_module() {
    log_section "卸载 brutal-nginx 模块"
    local found=0

    if is_brutal_nginx_installed; then
        found=1
    fi

    rm -f /etc/nginx/modules/ngx_http_tcp_brutal_module.so
    rm -f /usr/lib/nginx/modules/ngx_http_tcp_brutal_module.so
    rm -f /usr/lib64/nginx/modules/ngx_http_tcp_brutal_module.so
    if [[ -f /etc/nginx/nginx.conf ]]; then
        sed -i '/ngx_http_tcp_brutal_module.so/d' /etc/nginx/nginx.conf
    fi
    find /etc/nginx -type f \( -name "*.conf" -o -name "nginx.conf" \) \
        -exec sed -i '/ngx_http_tcp_brutal_module.so/d' {} + 2>/dev/null || true
    service_reload_or_restart_any nginx || nginx -s reload 2>/dev/null || true

    if is_brutal_nginx_installed; then
        log_warn "brutal-nginx 仍检测到残留模块，请手动检查 nginx 模块目录"
        return 1
    fi

    if [[ $found -eq 0 ]]; then
        log_info "未检测到 brutal-nginx，已完成残留配置清理检查"
    else
        log_success "brutal-nginx 模块已彻底卸载"
    fi
}

# ============ Fail2ban 管理 (SSH 防暴力) ============

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
    esac

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1d
bantime.increment = true
bantime.factor = 1
bantime.maxtime = 30d
findtime = 7d
maxretry = 3
backend = auto

[sshd]
enabled = true
port = $ssh_port,22
mode = aggressive
EOF

    service_action_any restart rsyslog || true
    service_enable_any fail2ban || true
    service_action_any restart fail2ban || true

    if service_is_active_any fail2ban; then
        log_success "Fail2ban 已启用 (SSH 端口: $ssh_port)"
    else
        log_warn "Fail2ban 启动状态未知，请检查服务日志"
    fi
}

remove_fail2ban_basic() {
    log_section "停用/移除 Fail2ban"
    service_action_any stop fail2ban || true
    service_disable_any fail2ban || true
    rm -f /etc/fail2ban/jail.local
    log_success "Fail2ban 已停用并移除自定义配置"
}

# ============ Swap 管理 ============

swap_create() {
    log_section "创建 Swap"
    read -p "请输入 Swap 大小 (MB，默认 1024): " swap_size
    [[ -z "$swap_size" ]] && swap_size=1024
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    if ! fallocate -l ${swap_size}M /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=${swap_size}
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    log_success "Swap 已创建并启用: ${swap_size}MB"
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
    read -p "请输入 swappiness (0-100，默认 60): " new_val
    [[ -z "$new_val" ]] && new_val=60
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

configure_static_buffers() {
    log_info "配置静态 TCP 缓冲区 (bpftune 替代方案)..."
    
    local STATIC_CONFIG="
# === 静态缓冲区配置 (bpftune 不可用时使用) ===
# 设置合理的自适应范围，让内核自动调整
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216"
    
    # 追加到 sysctl.d 配置文件
    echo "$STATIC_CONFIG" >> /etc/sysctl.d/99-bbr-tuning.conf
    
    # Alpine 兼容：同时写入主配置文件
    if [[ "$OS_TYPE" == "alpine" ]]; then
        echo "$STATIC_CONFIG" >> /etc/sysctl.conf
        log_info "Alpine: 配置已写入 /etc/sysctl.conf"
    fi
    
    # 应用配置 (兼容 Alpine 和 Debian/Ubuntu)
    if [[ -f /etc/sysctl.d/99-bbr-tuning.conf ]]; then
        sysctl -p /etc/sysctl.d/99-bbr-tuning.conf 2>/dev/null || true
    fi
    sysctl -p /etc/sysctl.conf 2>/dev/null || true
    
    # 验证是否生效
    local current_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    if [[ "$current_rmem" -ge 16777216 ]]; then
        log_success "静态缓冲区配置完成 (rmem_max: ${current_rmem})"
    else
        log_warn "配置可能未完全生效，当前 rmem_max: ${current_rmem}"
        log_info "请手动运行: sysctl -p /etc/sysctl.conf"
    fi
}

setup_bpftune_service() {
    log_section "配置 bpftune 服务"
    
    if ! command -v bpftune &> /dev/null; then
        log_info "bpftune 未安装，跳过服务配置"
        return 0
    fi
    
    case $INIT_SYSTEM in
        systemd)
            # 避免 systemctl 回退到 SysV：如存在旧版 /etc/init.d/bpftune 但无 LSB 头，则先移除
            if [[ -f /etc/init.d/bpftune ]]; then
                mv /etc/init.d/bpftune /etc/init.d/bpftune.disabled.$$ 2>/dev/null || rm -f /etc/init.d/bpftune
            fi

            local BPFTUNE_BIN
            BPFTUNE_BIN=$(command -v bpftune || echo /usr/sbin/bpftune)

            # 检查是否已有服务文件
            if [[ ! -f /lib/systemd/system/bpftune.service ]] && \
               [[ ! -f /etc/systemd/system/bpftune.service ]]; then
                cat > /etc/systemd/system/bpftune.service <<EOF
[Unit]
Description=BPF auto-tuning daemon
After=network.target

[Service]
Type=simple
ExecStart=${BPFTUNE_BIN} -s
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
            fi
            
            service_daemon_reload
            service_enable_any bpftune || true
            service_action_any restart bpftune || service_action_any start bpftune || true

            if service_is_active_any bpftune; then
                log_success "bpftune 服务已启动"
            else
                log_warn "bpftune 服务启动失败"
                log_info "查看日志: journalctl -u bpftune -n 20"
            fi
            ;;
        openrc)
            local BPFTUNE_BIN
            BPFTUNE_BIN=$(command -v bpftune || echo /usr/sbin/bpftune)

            cat > /etc/init.d/bpftune <<'INITEOF'
#!/sbin/openrc-run
name="bpftune"
description="BPF auto-tuning daemon"
command="BPFTUNE_BIN_PLACEHOLDER"
command_args="-s"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
depend() { need net; }
INITEOF
            # 替换占位符为实际路径
            sed -i "s|BPFTUNE_BIN_PLACEHOLDER|${BPFTUNE_BIN}|g" /etc/init.d/bpftune
            chmod +x /etc/init.d/bpftune
            service_enable_any bpftune || true
            service_action_any start bpftune || true
            log_success "bpftune OpenRC 服务已配置"
            ;;
    esac
}

remove_bpftune() {
    log_section "检测并移除 bpftune"

    local found=0
    local removed=0

    if command -v bpftune &>/dev/null; then
        found=1
        log_info "检测到 bpftune 可执行文件: $(command -v bpftune)"
    fi

    service_action_any stop bpftune || true
    service_disable_any bpftune || true

    rm -f /etc/systemd/system/bpftune.service /lib/systemd/system/bpftune.service /etc/init.d/bpftune
    service_daemon_reload

    case $PKG_MANAGER in
        apt)
            if dpkg -s bpftune >/dev/null 2>&1; then
                apt-get remove -y -qq bpftune >/dev/null 2>&1 || true
                removed=1
            fi
            ;;
        apk)
            if apk info -e bpftune >/dev/null 2>&1; then
                apk del --quiet bpftune >/dev/null 2>&1 || true
                removed=1
            fi
            ;;
        dnf|yum)
            if rpm -q bpftune >/dev/null 2>&1; then
                $PKG_MANAGER -y -q remove bpftune >/dev/null 2>&1 || true
                removed=1
            fi
            ;;
    esac

    local candidates=(
        /usr/sbin/bpftune
        /usr/local/sbin/bpftune
        /usr/bin/bpftune
        /usr/local/bin/bpftune
    )
    local bin_path
    for bin_path in "${candidates[@]}"; do
        if [[ -e "$bin_path" ]]; then
            rm -f "$bin_path"
            removed=1
        fi
    done
    hash -r 2>/dev/null || true

    if command -v bpftune &>/dev/null; then
        log_warn "bpftune 仍可执行，请手动检查 PATH 中残留文件"
        return 1
    fi

    if [[ $found -eq 0 && $removed -eq 0 ]]; then
        log_info "未检测到 bpftune，已完成残留服务/文件清理检查"
    else
        log_success "bpftune 已清理完成"
    fi
}

snapshot_tracked_files() {
    cat <<'EOF'
/etc/sysctl.conf
/etc/sysctl.d/99-bbr-tuning.conf
/etc/sysctl.d/99-bbr-aggressive.conf
/etc/sysctl.d/99-cc.conf
/etc/sysctl.d/99-zhizhishu-serverspan.conf
/etc/sysctl.d/99-zhizhishu-forwarding.conf
/etc/sysctl.d/99-zhizhishu-provider-baseline-restore.conf
/etc/modules-load.d/network-tuning.conf
/etc/systemd/system/bpftune.service
/lib/systemd/system/bpftune.service
/etc/init.d/bpftune
/etc/gai.conf
EOF
}

provider_tuning_keys() {
    cat <<'EOF'
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.core.netdev_max_backlog
net.core.rmem_max
net.core.wmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_sack
net.ipv4.tcp_timestamps
net.ipv4.tcp_window_scaling
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_fastopen
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.core.rmem_default
net.core.wmem_default
fs.file-max
kernel.panic
vm.swappiness
vm.overcommit_memory
EOF
}

is_managed_sysctl_file() {
    local file="$1"
    case "$file" in
        /etc/sysctl.d/99-bbr-tuning.conf|\
        /etc/sysctl.d/99-bbr-aggressive.conf|\
        /etc/sysctl.d/99-cc.conf|\
        /etc/sysctl.d/99-zhizhishu-serverspan.conf|\
        /etc/sysctl.d/99-zhizhishu-forwarding.conf|\
        /etc/sysctl.d/99-zhizhishu-provider-baseline-restore.conf)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

collect_sysctl_source_files() {
    local include_managed="${1:-0}"
    local files=()
    local dir

    for dir in /usr/lib/sysctl.d /usr/local/lib/sysctl.d /lib/sysctl.d /run/sysctl.d /etc/sysctl.d; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r conf; do
            [[ -z "$conf" ]] && continue
            if [[ "$include_managed" != "1" ]] && is_managed_sysctl_file "$conf"; then
                continue
            fi
            files+=("$conf")
        done < <(find "$dir" -maxdepth 1 -type f -name "*.conf" 2>/dev/null | sort)
    done

    if [[ -f /etc/sysctl.conf ]]; then
        files+=("/etc/sysctl.conf")
    fi

    printf '%s\n' "${files[@]}"
}

sysctl_kv_get() {
    local key="$1"
    local file="$2"
    local key_re="${key//./\\.}"
    grep -E "^[[:space:]]*${key_re}[[:space:]]*=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

write_current_provider_tuning_kv() {
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local value
        value=$(sysctl -n "$key" 2>/dev/null || echo "__unsupported__")
        echo "${key}=${value}"
    done < <(provider_tuning_keys)
}

seed_provider_baseline_from_sysctl_sources() {
    local files=()
    while IFS= read -r conf; do
        [[ -z "$conf" ]] && continue
        files+=("$conf")
    done < <(collect_sysctl_source_files 0)

    [[ ${#files[@]} -eq 0 ]] && return 1

    : > "$PROVIDER_BASELINE_FILE"
    : > "$PROVIDER_BASELINE_SOURCEMAP"

    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local value=""
        local source_file="__kernel_default__"
        local conf
        for conf in "${files[@]}"; do
            local candidate
            candidate=$(sysctl_kv_get "$key" "$conf")
            if [[ -n "$candidate" ]]; then
                value="$candidate"
                source_file="$conf"
            fi
        done

        if [[ -n "$value" ]]; then
            echo "${key}=${value}" >> "$PROVIDER_BASELINE_FILE"
            echo "${key}|${source_file}|${value}" >> "$PROVIDER_BASELINE_SOURCEMAP"
        else
            echo "${key}=__not_set_in_sysctl_files__" >> "$PROVIDER_BASELINE_FILE"
            echo "${key}|__kernel_default__|__not_set_in_sysctl_files__" >> "$PROVIDER_BASELINE_SOURCEMAP"
        fi
    done < <(provider_tuning_keys)

    {
        echo "source=sysctl_source_scrape"
        echo "captured_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "snapshot=none"
    } > "$PROVIDER_BASELINE_META"
    return 0
}

seed_provider_baseline_from_snapshot() {
    local oldest_snapshot
    oldest_snapshot=$(ls -1dt "${SNAPSHOT_ROOT}"/snapshot-* 2>/dev/null | tail -1)
    [[ -z "$oldest_snapshot" ]] && return 1

    local old_conf="${oldest_snapshot}/files/etc/sysctl.conf"
    [[ -f "$old_conf" ]] || return 1

    : > "$PROVIDER_BASELINE_FILE"
    : > "$PROVIDER_BASELINE_SOURCEMAP"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local value
        value=$(sysctl_kv_get "$key" "$old_conf")
        if [[ -n "$value" ]]; then
            echo "${key}=${value}" >> "$PROVIDER_BASELINE_FILE"
            echo "${key}|${old_conf}|${value}" >> "$PROVIDER_BASELINE_SOURCEMAP"
        else
            echo "${key}=__not_set_in_snapshot__" >> "$PROVIDER_BASELINE_FILE"
            echo "${key}|${old_conf}|__not_set_in_snapshot__" >> "$PROVIDER_BASELINE_SOURCEMAP"
        fi
    done < <(provider_tuning_keys)

    {
        echo "source=oldest_snapshot"
        echo "captured_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "snapshot=$(basename "$oldest_snapshot")"
    } > "$PROVIDER_BASELINE_META"
    return 0
}

ensure_provider_baseline() {
    mkdir -p "$SNAPSHOT_ROOT"
    if [[ -f "$PROVIDER_BASELINE_FILE" ]]; then
        return 0
    fi

    if seed_provider_baseline_from_sysctl_sources; then
        log_info "已搜刮系统 sysctl 配置来源并生成服务商基线"
        return 0
    fi

    if seed_provider_baseline_from_snapshot; then
        log_info "已从最早快照推断服务商原始参数基线"
        return 0
    fi

    write_current_provider_tuning_kv > "$PROVIDER_BASELINE_FILE"
    : > "$PROVIDER_BASELINE_SOURCEMAP"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local v
        v=$(provider_tuning_kv_read "$key" "$PROVIDER_BASELINE_FILE")
        echo "${key}|runtime|${v}" >> "$PROVIDER_BASELINE_SOURCEMAP"
    done < <(provider_tuning_keys)
    {
        echo "source=current_runtime"
        echo "captured_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "snapshot=none"
    } > "$PROVIDER_BASELINE_META"
    log_info "首次记录当前参数为服务商基线（建议在首次调优前执行该检测）"
}

provider_tuning_kv_read() {
    local key="$1"
    local file="$2"
    grep -E "^${key//./\\.}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

scan_provider_tuning_sources() {
    log_section "服务商参数来源扫描 (sysctl 配置文件)"
    mkdir -p "$SNAPSHOT_ROOT"
    local report_file="${SNAPSHOT_ROOT}/provider-source-report-$(date +%Y%m%d-%H%M%S).txt"
    local files=()

    while IFS= read -r conf; do
        [[ -z "$conf" ]] && continue
        files+=("$conf")
    done < <(collect_sysctl_source_files 0)

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "未发现可扫描的 sysctl 配置文件"
        return 0
    fi

    {
        echo "# provider source report"
        echo "# generated_at: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# scanned_files_count: ${#files[@]}"
        echo ""
        echo "[scanned_files]"
        local file
        for file in "${files[@]}"; do
            echo "  ${file}"
        done
        echo ""
    } > "$report_file"

    local found_any=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local key_re="${key//./\\.}"
        local hits
        hits=$(grep -HnE "^[[:space:]]*${key_re}[[:space:]]*=" "${files[@]}" 2>/dev/null || true)
        if [[ -n "$hits" ]]; then
            found_any=1
            {
                echo "[${key}]"
                echo "$hits" | sed 's/^/  /'
                echo ""
            } >> "$report_file"
        fi
    done < <(provider_tuning_keys)

    if [[ $found_any -eq 0 ]]; then
        echo "[no_explicit_key_found]" >> "$report_file"
        echo "  在配置文件中未找到关键参数显式声明，可能使用内核默认值" >> "$report_file"
    fi

    cat "$report_file"
    log_info "来源扫描报告已保存: $report_file"
}

detect_provider_tuning_params() {
    log_section "服务商原生调优参数检测"
    ensure_provider_baseline

    local current_kv
    current_kv=$(mktemp)
    write_current_provider_tuning_kv > "$current_kv"

    local source captured snapshot
    source=$(grep '^source=' "$PROVIDER_BASELINE_META" 2>/dev/null | cut -d= -f2-)
    captured=$(grep '^captured_at=' "$PROVIDER_BASELINE_META" 2>/dev/null | cut -d= -f2-)
    snapshot=$(grep '^snapshot=' "$PROVIDER_BASELINE_META" 2>/dev/null | cut -d= -f2-)
    [[ -z "$source" ]] && source="unknown"
    [[ -z "$captured" ]] && captured="unknown"
    [[ -z "$snapshot" ]] && snapshot="unknown"

    log_info "基线来源: ${source} | 记录时间: ${captured} | 参考快照: ${snapshot}"
    if [[ -f "$PROVIDER_BASELINE_SOURCEMAP" ]]; then
        log_info "基线来源映射文件: ${PROVIDER_BASELINE_SOURCEMAP}"
    fi
    if [[ "$source" == "current_runtime" ]]; then
        log_warn "基线来自首次检测当下值，若此前已做过调优，这不是严格意义上的服务商出厂值"
    fi
    echo "参数 | 基线值 | 当前值 | 状态"
    echo "-----|--------|--------|-----"

    local changed=0
    local unchanged=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local base current status
        base=$(provider_tuning_kv_read "$key" "$PROVIDER_BASELINE_FILE")
        current=$(provider_tuning_kv_read "$key" "$current_kv")
        [[ -z "$base" ]] && base="__unknown__"
        [[ -z "$current" ]] && current="__unknown__"
        if [[ "$base" == "$current" ]]; then
            status="未变化"
            unchanged=$((unchanged + 1))
        else
            status="已变化"
            changed=$((changed + 1))
        fi
        echo "${key} | ${base} | ${current} | ${status}"
    done < <(provider_tuning_keys)

    rm -f "$current_kv"
    log_info "对比完成: 已变化 ${changed} 项，未变化 ${unchanged} 项"
    scan_provider_tuning_sources
}

rebuild_provider_baseline_from_sources() {
    log_section "重建服务商参数基线 (搜刮系统配置来源)"
    mkdir -p "$SNAPSHOT_ROOT"
    rm -f "$PROVIDER_BASELINE_FILE" "$PROVIDER_BASELINE_META" "$PROVIDER_BASELINE_SOURCEMAP"

    if seed_provider_baseline_from_sysctl_sources; then
        log_success "服务商参数基线已重建 (来源: 系统 sysctl 配置搜刮)"
        detect_provider_tuning_params
        return 0
    fi

    log_warn "从系统配置搜刮基线失败，回退到当前运行参数"
    write_current_provider_tuning_kv > "$PROVIDER_BASELINE_FILE"
    {
        echo "source=current_runtime"
        echo "captured_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "snapshot=none"
    } > "$PROVIDER_BASELINE_META"
    : > "$PROVIDER_BASELINE_SOURCEMAP"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local v
        v=$(provider_tuning_kv_read "$key" "$PROVIDER_BASELINE_FILE")
        echo "${key}|runtime|${v}" >> "$PROVIDER_BASELINE_SOURCEMAP"
    done < <(provider_tuning_keys)
    detect_provider_tuning_params
}

restore_provider_tuning_baseline() {
    log_section "按服务商基线恢复 sysctl 参数"
    ensure_provider_baseline
    create_config_snapshot "before_restore_provider_baseline"

    {
        echo "# Generated by zhizhishu-net-opt baseline restore"
        echo "# generated_at=$(date '+%Y-%m-%d %H:%M:%S')"
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local value
            value=$(provider_tuning_kv_read "$key" "$PROVIDER_BASELINE_FILE")
            case "$value" in
                ""|__unknown__|__unsupported__|__not_set_in_snapshot__|__not_set_in_sysctl_files__)
                    continue
                    ;;
            esac
            echo "${key} = ${value}"
        done < <(provider_tuning_keys)
    } > "$PROVIDER_RESTORE_FILE"

    if ! grep -qE '^[a-z0-9_.]+[[:space:]]*=' "$PROVIDER_RESTORE_FILE"; then
        log_warn "基线中无可恢复的显式参数，已跳过应用"
        rm -f "$PROVIDER_RESTORE_FILE"
        return 1
    fi

    sysctl -p "$PROVIDER_RESTORE_FILE" >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
    log_success "已应用服务商基线参数: $PROVIDER_RESTORE_FILE"
    verify_installation
}

create_config_snapshot() {
    local reason="$1"
    ensure_provider_baseline
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

    local bpftune_running="no"
    is_bpftune_running && bpftune_running="yes"
    {
        echo "created_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "reason=${reason:-manual}"
        echo "kernel=$(uname -r)"
        echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
        echo "qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
        echo "bpftune_installed=$([[ -n "$(command -v bpftune 2>/dev/null)" ]] && echo yes || echo no)"
        echo "bpftune_running=${bpftune_running}"
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

snapshot_menu() {
    log_section "快照管理"
    echo "1) 创建快照"
    echo "2) 从快照回滚"
    echo "3) 查看快照列表"
    echo "0) 返回上层菜单"
    read -p "请选择 [1-3/0]: " snapshot_choice
    case $snapshot_choice in
        1)
            read -p "请输入快照备注(可选): " snapshot_note
            [[ -z "$snapshot_note" ]] && snapshot_note="manual_snapshot"
            create_config_snapshot "$snapshot_note"
            ;;
        2)
            restore_config_snapshot
            ;;
        3)
            list_config_snapshots
            ;;
        0)
            return 0
            ;;
        *)
            log_warn "无效选择"
            ;;
    esac
}

print_system_status_card() {
    echo -e "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│              📊 系统状态检查                     │${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────┤${NC}"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    if [[ "$cc" == "bbr" ]]; then
        echo -e "${CYAN}│${NC}  拥塞控制:     ${GREEN}BBR ✓${NC}"
    else
        echo -e "${CYAN}│${NC}  拥塞控制:     ${YELLOW}${cc}${NC}"
    fi

    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    if [[ "$qdisc" == "fq" || "$qdisc" == "cake" ]]; then
        echo -e "${CYAN}│${NC}  队列调度:     ${GREEN}${qdisc^^} ✓${NC}"
    else
        echo -e "${CYAN}│${NC}  队列调度:     ${YELLOW}${qdisc}${NC}"
    fi

    local ipv4_addr ipv4_forward ipv6_addr ipv6_forward ipv4_addr_short ipv6_addr_short
    ipv4_addr=$(get_primary_ipv4)
    ipv4_forward=$(get_ipv4_forwarding_status)
    ipv6_addr=$(get_primary_ipv6)
    ipv6_forward=$(get_ipv6_forwarding_status)
    ipv4_addr_short=$(truncate_status_value "${ipv4_addr:-未检测到}" 20)
    ipv6_addr_short=$(truncate_status_value "${ipv6_addr:-未检测到}" 20)

    if [[ -n "$ipv4_addr" ]]; then
        echo -e "${CYAN}│${NC}  IPv4 本机:    ${GREEN}${ipv4_addr_short}${NC}"
    else
        echo -e "${CYAN}│${NC}  IPv4 本机:    ${YELLOW}未检测到${NC}"
    fi
    if [[ "$ipv4_forward" == "已启用" ]]; then
        echo -e "${CYAN}│${NC}  IPv4 转发:    ${GREEN}${ipv4_forward} ✓${NC}"
    else
        echo -e "${CYAN}│${NC}  IPv4 转发:    ${YELLOW}${ipv4_forward}${NC}"
    fi

    if [[ -n "$ipv6_addr" ]]; then
        echo -e "${CYAN}│${NC}  IPv6 本机:    ${GREEN}${ipv6_addr_short}${NC}"
    else
        echo -e "${CYAN}│${NC}  IPv6 本机:    ${YELLOW}未检测到${NC}"
    fi
    if [[ "$ipv6_forward" == "已启用" ]]; then
        echo -e "${CYAN}│${NC}  IPv6 转发:    ${GREEN}${ipv6_forward} ✓${NC}"
    elif [[ "$ipv6_forward" == "未检测到" ]]; then
        echo -e "${CYAN}│${NC}  IPv6 转发:    ${YELLOW}${ipv6_forward}${NC}"
    else
        echo -e "${CYAN}│${NC}  IPv6 转发:    ${YELLOW}${ipv6_forward}${NC}"
    fi

    if is_bpftune_installed; then
        if is_bpftune_running; then
            echo -e "${CYAN}│${NC}  bpftune:      ${GREEN}运行中 ✓ (自动调优)${NC}"
        else
            echo -e "${CYAN}│${NC}  bpftune:      ${YELLOW}已安装但未运行${NC}"
        fi
    else
        echo -e "${CYAN}│${NC}  bpftune:      ${YELLOW}未安装/未运行${NC}"
    fi

    local rmem_max
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
    if [[ -n "$rmem_max" && "$rmem_max" =~ ^[0-9]+$ ]]; then
        local rmem_mib
        rmem_mib=$(awk -v v="$rmem_max" 'BEGIN {printf "%.1f", v/1024/1024}')
        echo -e "${CYAN}│${NC}  TCP 缓冲区:   ${GREEN}${rmem_mib} MiB (max)${NC}"
    else
        echo -e "${CYAN}│${NC}  TCP 缓冲区:   ${YELLOW}未知${NC}"
    fi

    check_tcp_brutal_status

    if is_brutal_nginx_installed; then
        echo -e "${CYAN}│${NC}  brutal-nginx: ${GREEN}模块已安装${NC}"
    else
        echo -e "${CYAN}│${NC}  brutal-nginx: ${YELLOW}未安装${NC}"
    fi

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
    local bpftune_status=""
    if command -v bpftune &> /dev/null && is_bpftune_running; then
        bpftune_status="bpftune 自动调优已启用"
    else
        bpftune_status="使用静态缓冲区配置"
    fi
    
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    ✅ 安装完成！                             ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    echo "║  🚀 已配置: BBR + ${QDISC_CHOICE^^}                                        ║"
    echo "║  🔧 $bpftune_status                              ║"
    echo "║                                                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  配置文件:                                                   ║"
    echo "║    • /etc/sysctl.d/99-bbr-tuning.conf                       ║"
    echo "║    • /etc/modules-load.d/network-tuning.conf                ║"
    echo "║                                                              ║"
    if command -v bpftune &> /dev/null; then
    echo "║  查看 bpftune 调优日志:                                      ║"
    echo "║    journalctl -u bpftune -f                                 ║"
    echo "║                                                              ║"
    fi
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
    remove_bpftune
    
    # 删除配置文件
    rm -f /etc/sysctl.d/99-bbr-tuning.conf
    rm -f /etc/sysctl.d/99-bbr-aggressive.conf
    rm -f /etc/modules-load.d/network-tuning.conf
    
    sysctl --system > /dev/null 2>&1
    
    log_success "配置已删除"
    log_info "注意: BBR 和队列调度将在重启后恢复默认值"
}

write_corona_profile_sysctl() {
    local profile="$1"
    case "$profile" in
        dmit)
            cat > /etc/sysctl.conf <<'DMIT_CORONA_EOF'
net.core.default_qdisc = fq
net.core.rmem_max = 67108848
net.core.wmem_max = 67108848
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 16384 16777216 536870912
net.ipv4.tcp_wmem = 16384 16777216 536870912
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
kernel.panic = -1
vm.swappiness = 0
DMIT_CORONA_EOF
            ;;
        an4)
            cat > /etc/sysctl.conf <<'AN4_CORONA_EOF'
# === LAX.AN4.EB.CORONA (1G内存 + 2Gbps口) ===
# 基于 BDP 目标约 37.5MB，缓冲区锁定 40MB

# 1. 拥塞控制 (Kernel 6.x BBR)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 2. 流量队列
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.core.netdev_max_backlog = 2048

# 3. 核心缓冲区：锁定 40MB
net.core.rmem_max = 41943040
net.core.wmem_max = 41943040
net.ipv4.tcp_rmem = 16384 16777216 41943040
net.ipv4.tcp_wmem = 16384 16777216 41943040

# 4. 内存压榨
net.ipv4.tcp_adv_win_scale = 30

# 5. 协议优化
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# 6. 系统保命
kernel.panic = 10
vm.swappiness = 1
vm.overcommit_memory = 1

# === 进阶功能优化 (Optional, 默认不启用) ===
# net.ipv4.ip_forward = 1
# net.ipv4.tcp_fastopen = 3
# net.ipv4.tcp_mtu_probing = 1
# net.ipv4.tcp_keepalive_time = 600
# net.ipv4.tcp_keepalive_intvl = 15
# net.ipv4.tcp_keepalive_probes = 3
# net.core.rmem_default = 8388608
# net.core.wmem_default = 8388608
# fs.file-max = 1000000
AN4_CORONA_EOF
            ;;
        *)
            return 1
            ;;
    esac
}

apply_corona_profile() {
    local profile="${1:-}"
    local profile_name=""
    local snapshot_reason=""

    if [[ -z "$profile" ]]; then
        echo "请选择 Corona 参数配置:"
        echo "1) dmit corona（默认配置, 40MB）"
        echo "2) dmit corona（激进, 67MB）"
        echo "0) 返回上层菜单"
        read -p "请输入选择 [1/2/0] (默认: 1): " corona_choice
        corona_choice=${corona_choice:-1}
        case "$corona_choice" in
            1) profile="an4" ;;
            2) profile="dmit" ;;
            0)
                log_info "已取消 Corona 参数应用，返回上层菜单"
                return 0
                ;;
            *)
                log_error "无效选择"
                return 1
                ;;
        esac
    fi

    case "$profile" in
        dmit|dmit-corona|corona-dmit)
            profile="dmit"
            profile_name="DMIT.CORONA.AGGRESSIVE"
            snapshot_reason="before_dmit_corona_profile"
            ;;
        an4|an4-corona|lax-an4-eb-corona|corona-an4)
            profile="an4"
            profile_name="DMIT.CORONA.DEFAULT"
            snapshot_reason="before_lax_an4_eb_corona_profile"
            ;;
        *)
            log_error "未知 Corona 配置: $profile"
            return 1
            ;;
    esac

    log_section "应用 ${profile_name} 专用参数"
    create_config_snapshot "$snapshot_reason"

    local backup_file="/etc/sysctl.conf.backup.corona.${profile}.$(date +%Y%m%d%H%M%S)"
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "$backup_file"
        log_info "已备份 /etc/sysctl.conf -> $backup_file"
    fi

    if ! write_corona_profile_sysctl "$profile"; then
        log_error "写入 ${profile_name} 参数失败"
        return 1
    fi

    sysctl -p
    sysctl --system

    log_success "${profile_name} 参数已应用"
    verify_installation
}

# ============ Serverspan 自动调优 ============

map_serverspan_os() {
    case "$OS_TYPE" in
        ubuntu|debian|linuxmint|pop|kali)
            echo "deb"
            ;;
        rocky|almalinux|centos|rhel|fedora|ol|oraclelinux)
            echo "rhel"
            ;;
        alpine)
            log_warn "Serverspan API 仅支持 deb/rhel，Alpine 将按 deb 传参"
            echo "deb"
            ;;
        *)
            log_warn "未知发行版 ${OS_TYPE}，默认按 deb 传参"
            echo "deb"
            ;;
    esac
}

detect_serverspan_cores() {
    local cores=""
    if command -v lscpu >/dev/null 2>&1; then
        cores=$(LC_ALL=C lscpu -p=CORE 2>/dev/null | grep -Ev '^#' | sort -u | wc -l | awk '{print $1}')
    fi
    if [[ -z "$cores" || ! "$cores" =~ ^[0-9]+$ || "$cores" -le 0 ]]; then
        cores=$(nproc 2>/dev/null || echo 1)
    fi
    echo "$cores"
}

detect_serverspan_threads() {
    local threads
    threads=$(nproc --all 2>/dev/null || nproc 2>/dev/null || echo 1)
    [[ "$threads" =~ ^[0-9]+$ ]] || threads=1
    (( threads > 0 )) || threads=1
    echo "$threads"
}

detect_serverspan_ram_gb() {
    local ram_gb
    ram_gb=$(awk '/MemTotal/ {v=$2/1024/1024; if (v < 1) v = 1; printf "%.0f\n", v + 0.5}' /proc/meminfo 2>/dev/null)
    [[ "$ram_gb" =~ ^[0-9]+$ ]] || ram_gb=1
    (( ram_gb > 0 )) || ram_gb=1
    echo "$ram_gb"
}

detect_serverspan_nic_speed() {
    local iface speed
    iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|veth|br-|virbr|tun|tap|wg|tailscale)' | head -1)
    fi

    if [[ -n "$iface" && -r "/sys/class/net/${iface}/speed" ]]; then
        speed=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null || true)
    fi
    if [[ -z "$speed" || ! "$speed" =~ ^[0-9]+$ || "$speed" -le 0 ]] && command -v ethtool >/dev/null 2>&1 && [[ -n "$iface" ]]; then
        speed=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/,"",$2); print $2; exit}')
    fi
    [[ "$speed" =~ ^[0-9]+$ ]] || speed=1000
    (( speed > 0 )) || speed=1000
    echo "$speed"
}

detect_serverspan_disk_type() {
    local source disk rotational
    source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    disk=""

    if [[ "$source" =~ ^/dev/ ]]; then
        disk=$(lsblk -no pkname "$source" 2>/dev/null | head -1)
        if [[ -z "$disk" ]]; then
            disk=$(basename "$source")
            if [[ "$disk" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
                disk="${BASH_REMATCH[1]}"
            elif [[ "$disk" =~ ^(mmcblk[0-9]+)p[0-9]+$ ]]; then
                disk="${BASH_REMATCH[1]}"
            else
                disk=$(echo "$disk" | sed -E 's/p?[0-9]+$//')
            fi
        fi
    fi

    if [[ "$disk" =~ ^nvme ]]; then
        echo "nvme"
        return 0
    fi

    if [[ -n "$disk" && -r "/sys/block/${disk}/queue/rotational" ]]; then
        rotational=$(cat "/sys/block/${disk}/queue/rotational" 2>/dev/null || echo "")
        if [[ "$rotational" == "1" ]]; then
            echo "hdd"
            return 0
        fi
    fi

    echo "ssd"
}

detect_serverspan_disk_size_gb() {
    local size_gb
    size_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$2); print $2}')
    [[ "$size_gb" =~ ^[0-9]+$ ]] || size_gb=20
    (( size_gb > 0 )) || size_gb=20
    echo "$size_gb"
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

is_valid_serverspan_use_case() {
    case "$1" in
        general|virtualization|web|database|cache|compute|fileserver|network|container|development|security|realtime|media|mail|game|blockchain|api)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

bool_to_json() {
    [[ "$1" == "1" ]] && echo "true" || echo "false"
}

extract_serverspan_error_message() {
    local json_file="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json_file" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    print("无法解析 API 响应")
    sys.exit(0)
if isinstance(data, dict):
    if "error" in data:
        print(str(data["error"]))
    elif data.get("success") is False:
        print("API 返回 success=false")
    else:
        print("API 返回异常结构")
else:
    print("API 返回非 JSON 对象")
PY
        return 0
    fi
    grep -oE '"error"[[:space:]]*:[[:space:]]*"[^"]+"' "$json_file" 2>/dev/null | sed -E 's/^"error"[[:space:]]*:[[:space:]]*"//; s/"$//' || true
}

render_serverspan_sysctl_from_json() {
    local json_file="$1"
    local output_file="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$json_file" "$output_file" <<'PY'
import json
import sys

json_path, output_path = sys.argv[1], sys.argv[2]
with open(json_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

if not isinstance(data, dict) or data.get("success") is not True:
    raise SystemExit(2)

config = data.get("config")
if not isinstance(config, dict):
    raise SystemExit(3)

with open(output_path, 'w', encoding='utf-8') as out:
    out.write("# Generated by zhizhishu-net-opt via Serverspan API\n")
    comments = config.get("comments", [])
    if isinstance(comments, list):
        for line in comments:
            out.write("# " + str(line) + "\n")
    for k, v in config.items():
        if k == "comments":
            continue
        if isinstance(v, bool):
            value = "1" if v else "0"
        elif isinstance(v, list):
            value = " ".join(str(item) for item in v)
        else:
            value = str(v)
        out.write(f"{k} = {value}\n")
PY
        return $?
    fi

    if command -v jq >/dev/null 2>&1; then
        if ! jq -e '.success == true and (.config | type == "object")' "$json_file" >/dev/null 2>&1; then
            return 2
        fi
        {
            echo "# Generated by zhizhishu-net-opt via Serverspan API"
            jq -r '.config.comments[]? | "# " + tostring' "$json_file"
            jq -r '.config
                | to_entries[]
                | select(.key != "comments")
                | "\(.key) = \(
                    if (.value|type) == "array" then (.value|map(tostring)|join(" "))
                    elif (.value|type) == "boolean" then (if .value then "1" else "0" end)
                    else (.value|tostring)
                    end
                  )"' "$json_file"
        } > "$output_file"
        return 0
    fi

    log_error "缺少 JSON 解析器：请安装 python3 或 jq"
    return 1
}

request_serverspan_api() {
    local payload="$1"
    local response_file="$2"
    local quiet="${3:-0}"
    local attempt=1

    SERVERSPAN_LAST_API_HTTP_CODE="000"
    while (( attempt <= 2 )); do
        local http_code
        if ! http_code=$(curl -sS -L -m 30 -H "Content-Type: application/json" -X POST -d "$payload" -o "$response_file" -w "%{http_code}" "$SERVERSPAN_API_URL"); then
            SERVERSPAN_LAST_API_HTTP_CODE="000"
            [[ "$quiet" == "1" ]] || log_error "Serverspan API 请求失败（网络错误）"
            return 1
        fi
        SERVERSPAN_LAST_API_HTTP_CODE="$http_code"

        if [[ "$http_code" == "200" ]]; then
            return 0
        fi

        if [[ "$http_code" == "404" ]]; then
            return 2
        fi

        if [[ "$http_code" == "429" && "$attempt" -eq 1 ]]; then
            local retry_after
            retry_after=$(grep -oE '"retry_after"[[:space:]]*:[[:space:]]*[0-9]+' "$response_file" 2>/dev/null | grep -oE '[0-9]+' | head -1)
            [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=20
            [[ "$quiet" == "1" ]] || log_warn "Serverspan API 触发限流，${retry_after}s 后重试一次"
            sleep "$retry_after"
            attempt=$((attempt + 1))
            continue
        fi

        [[ "$quiet" == "1" ]] || log_error "Serverspan API 返回 HTTP ${http_code}"
        local err_msg
        err_msg=$(extract_serverspan_error_message "$response_file")
        [[ -n "$err_msg" && "$quiet" != "1" ]] && log_error "API 错误: ${err_msg}"
        return 1
    done

    return 1
}

extract_sysctl_from_serverspan_html() {
    local html_file="$1"
    local output_file="$2"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$html_file" "$output_file" <<'PY'
import html
import re
import sys

html_path, out_path = sys.argv[1], sys.argv[2]
content = open(html_path, 'r', encoding='utf-8', errors='ignore').read()
m = re.search(r'<pre id=sysctlOut[^>]*>(.*?)</pre>', content, flags=re.S | re.I)
if not m:
    raise SystemExit(2)
text = html.unescape(m.group(1)).strip()
if "Generate a configuration to see output here" in text:
    raise SystemExit(3)
open(out_path, 'w', encoding='utf-8').write(text + "\n")
PY
        return $?
    fi

    awk '
    BEGIN { in_pre=0 }
    /<pre id=sysctlOut/ {
        in_pre=1
        sub(/.*<pre id=sysctlOut[^>]*>/, "", $0)
    }
    in_pre {
        line=$0
        if (line ~ /<\/pre>/) {
            sub(/<\/pre>.*/, "", line)
            print line
            exit
        }
        print line
    }' "$html_file" > "$output_file"

    if grep -q "Generate a configuration to see output here" "$output_file"; then
        return 3
    fi
    if [[ ! -s "$output_file" ]]; then
        return 2
    fi
    return 0
}

request_serverspan_web_generator() {
    local os="$1"
    local cores="$2"
    local threads="$3"
    local ram="$4"
    local nic="$5"
    local disk_type="$6"
    local use_case="$7"
    local disable_ipv6="$8"
    local disable_ipv4="$9"
    local enable_forwarding="${10}"
    local output_file="${11}"

    local html_tmp
    html_tmp=$(mktemp)

    SERVERSPAN_LAST_WEB_HTTP_CODE="000"
    local http_code
    if ! http_code=$(curl -sS -m 30 -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data "os=${os}&cores=${cores}&threads=${threads}&ram=${ram}&nic=${nic}&disk_type=${disk_type}&use_case=${use_case}&tuning_mode=moderate&disable_ipv6=${disable_ipv6}&disable_ipv4=${disable_ipv4}&enable_forwarding=${enable_forwarding}" \
        -o "$html_tmp" -w "%{http_code}" "$SERVERSPAN_WEB_URL"); then
        rm -f "$html_tmp"
        SERVERSPAN_LAST_WEB_HTTP_CODE="000"
        return 1
    fi
    SERVERSPAN_LAST_WEB_HTTP_CODE="$http_code"
    if [[ "$http_code" != "200" ]]; then
        rm -f "$html_tmp"
        return 1
    fi

    if ! extract_sysctl_from_serverspan_html "$html_tmp" "$output_file"; then
        rm -f "$html_tmp"
        return 1
    fi

    rm -f "$html_tmp"
    return 0
}

calc_fallback_buffer_max_bytes() {
    local ram_gb="$1"
    if (( ram_gb <= 1 )); then
        echo 41943040
    elif (( ram_gb <= 2 )); then
        echo 67108864
    elif (( ram_gb <= 4 )); then
        echo 100663296
    elif (( ram_gb <= 8 )); then
        echo 134217728
    elif (( ram_gb <= 16 )); then
        echo 268435456
    else
        echo 536870912
    fi
}

write_local_detected_fallback_sysctl() {
    local output_file="$1"
    local use_case="$2"
    local cores="$3"
    local threads="$4"
    local ram_gb="$5"
    local nic="$6"
    local disk_type="$7"
    local disk_size_gb="$8"

    local max_buf mid_buf def_buf
    max_buf=$(calc_fallback_buffer_max_bytes "$ram_gb")
    mid_buf=$((max_buf / 4))
    (( mid_buf < 1048576 )) && mid_buf=1048576
    def_buf=$((max_buf / 8))
    (( def_buf < 1048576 )) && def_buf=1048576
    (( def_buf > 16777216 )) && def_buf=16777216

    local somaxconn syn_backlog netdev_backlog
    somaxconn=$((1024 + threads * 256))
    (( somaxconn < 1024 )) && somaxconn=1024
    (( somaxconn > 16384 )) && somaxconn=16384
    if [[ "$use_case" == "web" || "$use_case" == "api" || "$use_case" == "network" ]]; then
        somaxconn=$((somaxconn * 2))
        (( somaxconn > 32768 )) && somaxconn=32768
    fi
    syn_backlog=$((somaxconn * 2))
    (( syn_backlog > 65535 )) && syn_backlog=65535
    netdev_backlog=$((somaxconn * 4))
    (( netdev_backlog > 65535 )) && netdev_backlog=65535

    local swappiness dirty_ratio dirty_bg_ratio writeback_cs
    swappiness=10
    dirty_ratio=15
    dirty_bg_ratio=5
    writeback_cs=1500
    if [[ "$disk_type" == "hdd" ]]; then
        writeback_cs=3000
    fi
    if (( disk_size_gb <= 20 )); then
        dirty_ratio=10
        dirty_bg_ratio=3
    fi
    if [[ "$use_case" == "database" ]]; then
        swappiness=5
        dirty_ratio=10
        dirty_bg_ratio=3
    fi

    cat > "$output_file" <<EOF
# Generated by zhizhishu-net-opt local hardware fallback
# reason: Serverspan API/Web generator unavailable
# profile: ${use_case} (moderate), hardware=${cores}c/${threads}t ${ram_gb}GB RAM ${nic}Mb/s ${disk_type} ${disk_size_gb}GB
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.core.netdev_max_backlog = ${netdev_backlog}
net.core.rmem_max = ${max_buf}
net.core.wmem_max = ${max_buf}
net.core.rmem_default = ${def_buf}
net.core.wmem_default = ${def_buf}
net.ipv4.tcp_rmem = 16384 ${mid_buf} ${max_buf}
net.ipv4.tcp_wmem = 16384 ${mid_buf} ${max_buf}
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
vm.swappiness = ${swappiness}
vm.dirty_ratio = ${dirty_ratio}
vm.dirty_background_ratio = ${dirty_bg_ratio}
vm.dirty_writeback_centisecs = ${writeback_cs}
kernel.panic = 10
EOF
}

write_forwarding_overlay() {
    local ipv4_forward="$1"
    local ipv6_forward="$2"
    local has_ipv6=0

    system_has_ipv6 && has_ipv6=1
    if [[ "$has_ipv6" != "1" ]]; then
        ipv6_forward="0"
    fi

    if [[ "$ipv4_forward" != "1" && "$ipv6_forward" != "1" ]]; then
        rm -f "$FORWARDING_OVERLAY_FILE"
        log_info "未启用 IPv4/IPv6 转发（已移除转发覆盖文件，如存在）"
        return 0
    fi

    cat > "$FORWARDING_OVERLAY_FILE" <<EOF
# Generated by zhizhishu-net-opt (forwarding overlay)
net.ipv4.ip_forward = ${ipv4_forward}
EOF
    if [[ "$has_ipv6" == "1" ]]; then
        cat >> "$FORWARDING_OVERLAY_FILE" <<EOF
net.ipv6.conf.all.forwarding = ${ipv6_forward}
net.ipv6.conf.default.forwarding = ${ipv6_forward}
EOF
        log_success "已写入转发覆盖: $FORWARDING_OVERLAY_FILE (IPv4=${ipv4_forward}, IPv6=${ipv6_forward})"
    else
        log_success "已写入转发覆盖: $FORWARDING_OVERLAY_FILE (IPv4=${ipv4_forward})"
        log_info "未检测到可用 IPv6，已跳过 IPv6 转发配置写入"
    fi
}

apply_ipv4_preference_no_disable_ipv6() {
    local skip_snapshot="${1:-0}"
    local gai_conf="/etc/gai.conf"

    log_section "设置 IPv4 优先 (不关闭 IPv6)"
    if [[ "$skip_snapshot" != "1" ]]; then
        create_config_snapshot "before_ipv4_prefer_no_disable_ipv6"
    fi

    [[ -f "$gai_conf" ]] || touch "$gai_conf"
    cp "$gai_conf" "${gai_conf}.backup.$(date +%Y%m%d%H%M%S)"

    sed -i '/^[[:space:]]*precedence[[:space:]]*::ffff:0:0\/96[[:space:]]*/d' "$gai_conf"
    echo "precedence ::ffff:0:0/96  100" >> "$gai_conf"

    log_success "已启用 IPv4 优先地址选择（保留 IPv6 可用）"
    log_info "配置文件: $gai_conf"
}

preview_sysctl_candidate() {
    local candidate_file="$1"
    local source_label="$2"
    local total_lines=0

    [[ -f "$candidate_file" ]] || return 1

    log_section "自动检测配置预览"
    log_info "来源: ${source_label}"
    total_lines=$(wc -l < "$candidate_file" 2>/dev/null || echo 0)
    sed -n '1,28p' "$candidate_file"
    if (( total_lines > 28 )); then
        echo "... (共 ${total_lines} 行，已截取前 28 行预览)"
    fi
    log_info "确认应用后将自动创建快照，可从主菜单 4 回滚。"
}

apply_serverspan_api_profile() {
    local use_case="${1:-general}"
    local non_interactive="${2:-0}"
    local prefer_ipv4="${3:-}"
    local ipv4_forward="${4:-}"
    local ipv6_forward="${5:-}"
    local has_ipv6=0
    local candidate_file=""
    local candidate_source=""

    log_section "Serverspan 自动生成调优配置"
    detect_os
    detect_kernel
    system_has_ipv6 && has_ipv6=1

    if [[ "$non_interactive" != "1" ]]; then
        local use_case_input
        read -p "Use Case (默认 general，输入 0 返回): " use_case_input
        if [[ "$use_case_input" == "0" ]]; then
            log_info "已取消 Serverspan 自动调优，返回上层菜单"
            return 0
        fi
        use_case="${use_case_input:-$use_case}"
    fi

    if ! is_valid_serverspan_use_case "$use_case"; then
        log_error "无效 use_case: ${use_case}"
        log_info "可用值: general/web/database/cache/network/api 等"
        return 1
    fi

    if [[ "$non_interactive" == "1" ]]; then
        [[ -z "$prefer_ipv4" ]] && prefer_ipv4="1"
        [[ -z "$ipv4_forward" ]] && ipv4_forward="0"
        [[ -z "$ipv6_forward" ]] && ipv6_forward="0"
        if [[ "$has_ipv6" != "1" ]]; then
            ipv6_forward="0"
        fi
    else
        local ans
        read -p "是否启用 IPv4 优先（不关闭 IPv6）? [Y/n]: " ans
        [[ "$ans" =~ ^[Nn]$ ]] && prefer_ipv4="0" || prefer_ipv4="1"

        read -p "是否开启 IPv4 转发? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && ipv4_forward="1" || ipv4_forward="0"

        if [[ "$has_ipv6" == "1" ]]; then
            read -p "是否开启 IPv6 转发? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] && ipv6_forward="1" || ipv6_forward="0"
        else
            ipv6_forward="0"
            log_info "未检测到可用 IPv6，已跳过 IPv6 转发提问"
        fi
    fi

    local api_os cores threads ram nic disk_type disk_size_gb
    api_os=$(map_serverspan_os)
    cores=$(detect_serverspan_cores)
    threads=$(detect_serverspan_threads)
    ram=$(detect_serverspan_ram_gb)
    nic=$(detect_serverspan_nic_speed)
    disk_type=$(detect_serverspan_disk_type)
    disk_size_gb=$(detect_serverspan_disk_size_gb)

    log_info "硬件识别: os=${api_os}, cores=${cores}, threads=${threads}, ram=${ram}GB, nic=${nic}Mb/s, disk=${disk_type}, disk_size=${disk_size_gb}GB, kernel=${KERNEL_VERSION}"
    log_info "说明: Serverspan 仅基于系统/硬件生成模板，不会自动识别线路 RTT、BDP、业务协议或服务商隐藏调优。"

    local enable_forwarding=0
    if [[ "$ipv4_forward" == "1" || "$ipv6_forward" == "1" ]]; then
        enable_forwarding=1
    fi

    local payload
    payload=$(cat <<EOF
{"os":"${api_os}","cores":${cores},"threads":${threads},"ram":${ram},"nic":${nic},"disk_type":"${disk_type}","use_case":"${use_case}","disable_ipv6":false,"disable_ipv4":false,"enable_forwarding":$(bool_to_json "$enable_forwarding")}
EOF
)

    local response_file
    response_file=$(mktemp)
    candidate_file=$(mktemp)
    local api_status=0 used_api=0 used_web=0 used_local=0

    if request_serverspan_web_generator "$api_os" "$cores" "$threads" "$ram" "$nic" "$disk_type" "$use_case" 0 0 "$enable_forwarding" "$candidate_file"; then
        used_web=1
        candidate_source="Serverspan 网页生成器"
        log_success "已使用 Serverspan 网页生成器结果"
        log_info "连通性测试(Web生成器): HTTP=${SERVERSPAN_LAST_WEB_HTTP_CODE:-000}"
    else
        log_warn "网页生成器不可用 (HTTP ${SERVERSPAN_LAST_WEB_HTTP_CODE:-000})，尝试旧 API 端点"
        request_serverspan_api "$payload" "$response_file" 1 || api_status=$?
        log_info "连通性测试(API): HTTP=${SERVERSPAN_LAST_API_HTTP_CODE}"

        if [[ "$api_status" -eq 0 ]]; then
            if render_serverspan_sysctl_from_json "$response_file" "$candidate_file"; then
                used_api=1
                candidate_source="Serverspan 旧 API"
                log_success "已使用 Serverspan 旧 API 结果"
            else
                local err_msg
                err_msg=$(extract_serverspan_error_message "$response_file")
                log_warn "Serverspan API 解析失败: ${err_msg:-unknown}"
            fi
        elif [[ "$api_status" -eq 2 ]]; then
            log_warn "Serverspan 旧 API 端点当前不可用 (HTTP ${SERVERSPAN_LAST_API_HTTP_CODE})"
        else
            log_warn "Serverspan 旧 API 请求失败 (HTTP ${SERVERSPAN_LAST_API_HTTP_CODE:-000})"
        fi

        if [[ "$used_api" -ne 1 ]]; then
            log_warn "将使用本地硬件模板回退"
            write_local_detected_fallback_sysctl "$candidate_file" "$use_case" "$cores" "$threads" "$ram" "$nic" "$disk_type" "$disk_size_gb"
            used_local=1
            candidate_source="本地硬件模板回退"
        fi
    fi
    rm -f "$response_file"

    if [[ "$non_interactive" != "1" ]]; then
        preview_sysctl_candidate "$candidate_file" "$candidate_source"
        local confirm_apply
        read -p "是否应用以上自动检测配置? [Y/n]: " confirm_apply
        if [[ "$confirm_apply" =~ ^[Nn]$ ]]; then
            log_info "已取消应用，候选配置未写入系统"
            rm -f "$candidate_file"
            return 0
        fi
    fi

    create_config_snapshot "before_serverspan_api_${use_case}"
    if [[ -f "$SERVERSPAN_SYSCTL_FILE" ]]; then
        cp "$SERVERSPAN_SYSCTL_FILE" "${SERVERSPAN_SYSCTL_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    cp "$candidate_file" "$SERVERSPAN_SYSCTL_FILE"
    rm -f "$candidate_file"

    write_forwarding_overlay "$ipv4_forward" "$ipv6_forward"

    if [[ "$prefer_ipv4" == "1" ]]; then
        apply_ipv4_preference_no_disable_ipv6 1
    fi

    sysctl -p "$SERVERSPAN_SYSCTL_FILE" >/dev/null 2>&1 || true
    if [[ -f "$FORWARDING_OVERLAY_FILE" ]]; then
        sysctl -p "$FORWARDING_OVERLAY_FILE" >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true

    if [[ "$used_api" == "1" ]]; then
        log_success "Serverspan 旧 API 调优已应用: $SERVERSPAN_SYSCTL_FILE (use_case=${use_case})"
    elif [[ "$used_web" == "1" ]]; then
        log_success "已应用 Serverspan 网页生成器调优: $SERVERSPAN_SYSCTL_FILE (use_case=${use_case})"
    elif [[ "$used_local" == "1" ]]; then
        log_success "已应用本地硬件模板回退调优: $SERVERSPAN_SYSCTL_FILE (use_case=${use_case})"
    else
        log_warn "调优来源状态未知，但已写入配置文件: $SERVERSPAN_SYSCTL_FILE"
    fi

    local live_rmem_max live_rmem_mib
    live_rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "")
    if [[ "$use_case" == "general" && "$live_rmem_max" =~ ^[0-9]+$ ]]; then
        live_rmem_mib=$(awk -v v="$live_rmem_max" 'BEGIN {printf "%.1f", v/1024/1024}')
        if (( live_rmem_max < 16777216 )); then
            log_info "说明: 当前是 Serverspan general/moderate 通用保守模板，TCP max 约 ${live_rmem_mib} MiB；如需长 RTT / 高吞吐，请改用 Corona 参数。"
        fi
    fi
    verify_installation
}

# ============ SSH 配置 ============

configure_ssh_root_login() {
    log_section "配置 SSH Root 密码登录"
    
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    local SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
    local BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"
    
    # 检查 SSH 配置文件
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        log_error "SSH 配置文件不存在: $SSHD_CONFIG"
        return 1
    fi
    
    # 备份原配置
    log_info "备份原始配置到: $BACKUP_FILE"
    cp "$SSHD_CONFIG" "$BACKUP_FILE"
    log_success "配置已备份"
    
    # 显示当前状态
    echo ""
    echo -e "${CYAN}当前 SSH 配置状态:${NC}"
    local current_root_login=$(grep -E "^#?PermitRootLogin" "$SSHD_CONFIG" | tail -1 || echo "未设置")
    local current_password_auth=$(grep -E "^#?PasswordAuthentication" "$SSHD_CONFIG" | tail -1 || echo "未设置")
    echo "  PermitRootLogin:        $current_root_login"
    echo "  PasswordAuthentication: $current_password_auth"
    echo ""
    
    # 确认操作
    echo -e "${YELLOW}⚠️  警告: 开启 root 密码登录会降低安全性！${NC}"
    echo -e "${YELLOW}   建议：设置强密码 + 使用 fail2ban 防暴力破解${NC}"
    echo ""
    read -p "确认要开启 SSH root 密码登录? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消操作"
        return 0
    fi
    
    # 修改配置
    log_info "正在修改 SSH 配置..."
    
    # 处理 PermitRootLogin
    if grep -qE "^PermitRootLogin" "$SSHD_CONFIG"; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    elif grep -qE "^#PermitRootLogin" "$SSHD_CONFIG"; then
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    else
        echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
    fi
    
    # 处理 PasswordAuthentication
    if grep -qE "^PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
    elif grep -qE "^#PasswordAuthentication" "$SSHD_CONFIG"; then
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
    else
        echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
    fi
    
    # 处理 sshd_config.d 目录下可能覆盖的配置 (Ubuntu 22.04+)
    if [[ -d "$SSHD_CONFIG_DIR" ]]; then
        log_info "检查 $SSHD_CONFIG_DIR 目录..."
        
        # 创建覆盖配置
        cat > "$SSHD_CONFIG_DIR/99-allow-root-password.conf" <<'EOF'
# 允许 root 密码登录
PermitRootLogin yes
PasswordAuthentication yes
EOF
        log_success "创建覆盖配置: $SSHD_CONFIG_DIR/99-allow-root-password.conf"
    fi
    
    # 验证配置语法
    log_info "验证配置语法..."
    if sshd -t 2>/dev/null; then
        log_success "配置语法正确"
    else
        log_error "配置语法错误！正在恢复备份..."
        cp "$BACKUP_FILE" "$SSHD_CONFIG"
        rm -f "$SSHD_CONFIG_DIR/99-allow-root-password.conf" 2>/dev/null
        return 1
    fi
    
    # 重启 SSH 服务
    log_info "重启 SSH 服务..."
    if service_action_any restart sshd ssh; then
        log_success "SSH 服务已重启"
    else
        log_warn "SSH 服务重启可能失败，请手动检查"
    fi
    
    # 询问是否修改 root 密码
    echo ""
    read -p "是否现在设置/修改 root 密码? [y/N]: " set_password
    
    if [[ "$set_password" =~ ^[Yy]$ ]]; then
        log_info "请输入新的 root 密码:"
        passwd root
    fi
    
    # 显示最终结果
    echo ""
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              ✅ SSH Root 密码登录已开启！                    ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    echo "║  已修改:                                                     ║"
    echo "║    • PermitRootLogin yes                                    ║"
    echo "║    • PasswordAuthentication yes                             ║"
    echo "║                                                              ║"
    echo "║  备份文件: $BACKUP_FILE               ║"
    echo "║                                                              ║"
    echo "║  ⚠️  安全建议:                                               ║"
    echo "║    1. 使用强密码 (大小写+数字+特殊字符，12位以上)            ║"
    echo "║    2. 安装 fail2ban 防暴力破解                               ║"
    echo "║    3. 考虑修改 SSH 端口 (Port 22 -> 其他)                    ║"
    echo "║                                                              ║"
    echo "║  恢复原配置:                                                 ║"
    echo "║    cp $BACKUP_FILE /etc/ssh/sshd_config ║"
    echo "║    systemctl restart sshd                                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

disable_ssh_password_login() {
    log_section "禁用 SSH 密码登录 (仅密钥)"
    
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    local SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
    
    # 确认操作
    echo -e "${YELLOW}⚠️  警告: 禁用密码登录后，只能通过 SSH 密钥访问！${NC}"
    echo -e "${YELLOW}   请确保你已经配置好 SSH 密钥登录！${NC}"
    echo ""
    read -p "确认要禁用 SSH 密码登录? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "已取消操作"
        return 0
    fi
    
    # 备份
    cp "$SSHD_CONFIG" "$SSHD_CONFIG.backup.$(date +%Y%m%d%H%M%S)"
    
    # 修改配置
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    
    # 删除覆盖配置
    rm -f "$SSHD_CONFIG_DIR/99-allow-root-password.conf" 2>/dev/null
    
    # 重启服务
    if service_action_any restart sshd ssh; then
        log_success "SSH 密码登录已禁用，仅允许密钥登录"
    else
        log_warn "SSH 重启失败，请手动检查 sshd/ssh 服务状态"
    fi
}

# ============ 帮助 ============

show_help() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║      zhizhishu 网络优化助手 (BBR + 扩展模块 + 快照)          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  用法: sudo bash $0 [命令]                                   ║"
    echo "║                                                              ║"
    echo "║  网络优化命令:                                               ║"
    echo "║    install   - 交互式安装 (FQ/CAKE，不安装 bpftune)          ║"
    echo "║    uninstall - 卸载网络优化配置                              ║"
    echo "║    status    - 查看当前状态                                  ║"
    echo "║    snapshot  - 创建配置快照                                  ║"
    echo "║    rollback  - 从快照回滚                                    ║"
    echo "║    bpftune-rm - 检测并删除 bpftune                           ║"
    echo "║    vendor-check - 检测服务商原生调优参数                     ║"
    echo "║    vendor-rescan - 搜刮系统配置并重建服务商参数基线          ║"
    echo "║    vendor-restore - 按服务商参数基线恢复                      ║"
    echo "║    corona    - 应用 DMIT Corona 参数 (默认/激进)             ║"
    echo "║    dmit-corona/an4-corona - 直接应用指定 Corona 参数          ║"
    echo "║    api-sysctl - Serverspan 自动检测/预览/应用                 ║"
    echo "║    api-general - 一键应用 Serverspan general 默认配置         ║"
    echo "║    ipv4-prefer - 设置 IPv4 优先 (不关闭 IPv6)                ║"
    echo "║                                                              ║"
    echo "║  安全检查命令:                                               ║"
    echo "║    ssh        - 开启 SSH root 密码登录                       ║"
    echo "║    ssh-off    - 禁用 SSH 密码登录 (仅密钥)                   ║"
    echo "║    fail2ban   - 配置/启用 Fail2ban                           ║"
    echo "║    fail2ban-rm - 停用/移除 Fail2ban                          ║"
    echo "║                                                              ║"
    echo "║  扩展:                                                       ║"
    echo "║    extensions - 打开 bpftune / Brutal / brutal-nginx 管理    ║"
    echo "║    brutal     - 安装/加载 TCP Brutal                         ║"
    echo "║    brutal-ng  - 安装 brutal-nginx 模块                       ║"
    echo "║    help       - 显示此帮助                                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============ 交互式菜单 ============

show_extension_menu() {
    while true; do
        clear
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
        printf "%b\n" "${CYAN}║         扩展管理 (bpftune / TCP Brutal / brutal-nginx)      ║"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        print_system_status_card
        echo ""
        printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
        printf "%b\n" "${CYAN}║     1) 查看扩展状态                                          ║"
        printf "%b\n" "${CYAN}║     2) 安装并启用 bpftune                                    ║"
        printf "%b\n" "${CYAN}║     3) 彻底删除 bpftune                                      ║"
        printf "%b\n" "${CYAN}║     4) 安装/加载 TCP Brutal                                  ║"
        printf "%b\n" "${CYAN}║     5) 彻底删除 TCP Brutal                                   ║"
        printf "%b\n" "${CYAN}║     6) 安装 brutal-nginx 动态模块                            ║"
        printf "%b\n" "${CYAN}║     7) 彻底删除 brutal-nginx 模块                            ║"
        printf "%b\n" "${CYAN}║     0) 返回主菜单                                            ║"
        printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

        read -p "请输入选择 [0-7]: " ext_choice

        case $ext_choice in
            1)
                print_system_status_card
                pause_return_main_menu
                return 0
                ;;
            2)
                detect_os && detect_pkg_manager && detect_init_system && detect_kernel
                install_bpftune
                if is_bpftune_installed; then
                    setup_bpftune_service
                fi
                pause_return_main_menu
                return 0
                ;;
            3)
                detect_pkg_manager
                remove_bpftune
                pause_return_main_menu
                return 0
                ;;
            4)
                install_tcp_brutal
                pause_return_main_menu
                return 0
                ;;
            5)
                remove_tcp_brutal
                pause_return_main_menu
                return 0
                ;;
            6)
                install_brutal_nginx_module
                pause_return_main_menu
                return 0
                ;;
            7)
                remove_brutal_nginx_module
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

show_main_menu() {
    clear
    printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
    printf "%b\n" "${CYAN}║      🚀 zhizhishu 网络优化助手 (BBR + 扩展模块 + 快照)       ║"
    printf "%b\n" "${CYAN}║         自动挡调优，省心省力                                  ║"
    printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_system_status_card
    echo ""
    printf "%b\n" "${CYAN}╔══════════════════════════════════════════════════════════════╗"
    printf "%b\n" "${CYAN}║   ${GREEN}网络优化${CYAN}                                                  ║"
    printf "%b\n" "${CYAN}║     1) 交互式安装 (FQ/CAKE，不安装 bpftune)                  ║"
    printf "%b\n" "${CYAN}║     2) 查看当前网络状态                                      ║"
    printf "%b\n" "${CYAN}║     3) 卸载网络优化                                          ║"
    printf "%b\n" "${CYAN}║     4) 快照管理 (创建/回滚/列表)                             ║"
    printf "%b\n" "${CYAN}║     5) 扩展管理 (bpftune / Brutal / brutal-nginx)            ║"
    printf "%b\n" "${CYAN}║     6) 应用 DMIT Corona 参数 (默认/激进)                     ║"
    printf "%b\n" "${CYAN}║                                                              ║"
    printf "%b\n" "${CYAN}║   ${YELLOW}安全检查${CYAN}                                                  ║"
    printf "%b\n" "${CYAN}║     7) 开启 SSH root 密码登录                                ║"
    printf "%b\n" "${CYAN}║     8) 禁用 SSH 密码登录 (仅密钥)                            ║"
    printf "%b\n" "${CYAN}║     9) 配置/启用 Fail2ban (SSH 防护)                         ║"
    printf "%b\n" "${CYAN}║    10) 停用/移除 Fail2ban 配置                               ║"
    printf "%b\n" "${CYAN}║    11) 安全摘要检查 (SSH/端口/cron/authorized_keys)          ║"
    printf "%b\n" "${CYAN}║    12) 常用端口检查/修复 (22/80/443)                         ║"
    printf "%b\n" "${CYAN}║    13) 查看全部监听端口 (含 nft/iptables 概览)               ║"
    printf "%b\n" "${CYAN}║                                                              ║"
    printf "%b\n" "${CYAN}║   ${MAGENTA}系统维护${CYAN}                                                  ║"
    printf "%b\n" "${CYAN}║    14) Swap 管理                                             ║"
    printf "%b\n" "${CYAN}║    15) 检测服务商原生调优参数 (基线对比+来源扫描)            ║"
    printf "%b\n" "${CYAN}║    16) Serverspan 自动检测/预览/应用                         ║"
    printf "%b\n" "${CYAN}║    17) 设置 IPv4 优先 (不关闭 IPv6)                          ║"
    printf "%b\n" "${CYAN}║    18) 重建服务商基线 (搜刮系统 sysctl 配置来源)             ║"
    printf "%b\n" "${CYAN}║    19) 按服务商基线恢复参数                                  ║"
    printf "%b\n" "${CYAN}║                                                              ║"
    printf "%b\n" "${CYAN}║     0) 退出                                                  ║"
    printf "%b\n" "${CYAN}║     q) 退出脚本                                              ║"
    printf "%b\n" "${CYAN}║                                                              ║"
    printf "%b\n" "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    
    read -p "请输入选择 [0-19/q]: " menu_choice
    
    local should_pause=1
    case $menu_choice in
        1)
            run_interactive_install
            ;;
        2)
            run_status_check
            ;;
        3)
            uninstall
            ;;
        4)
            snapshot_menu
            ;;
        5)
            show_extension_menu
            should_pause=0
            ;;
        6)
            apply_corona_profile
            ;;
        7)
            detect_os && detect_init_system
            configure_ssh_root_login
            ;;
        8)
            detect_os && detect_init_system
            disable_ssh_password_login
            ;;
        9)
            install_fail2ban_basic
            ;;
        10)
            remove_fail2ban_basic
            ;;
        11)
            security_quick_check
            ;;
        12)
            check_common_ports
            ;;
        13)
            list_all_listening_ports
            ;;
        14)
            swap_menu
            ;;
        15)
            detect_provider_tuning_params
            ;;
        16)
            apply_serverspan_api_profile general 0
            ;;
        17)
            apply_ipv4_preference_no_disable_ipv6
            ;;
        18)
            rebuild_provider_baseline_from_sources
            ;;
        19)
            restore_provider_tuning_baseline
            ;;
        0|q|Q)
            echo -e "${GREEN}再见！${NC}"
            exit 0
            ;;
        *)
            log_error "无效选择"
            sleep 1
            should_pause=0
            ;;
    esac

    if [[ $should_pause -eq 1 ]]; then
        pause_return_main_menu
    fi
}

run_fq_install() {
    QDISC_CHOICE="fq"
    echo -e "${CYAN}安装模式: BBR + FQ${NC}"
    detect_os && detect_pkg_manager && detect_init_system && detect_kernel
    check_bpf_support && check_bbr_support && check_qdisc_support
    create_config_snapshot "before_fq_install"
    update_pkg_cache && install_dependencies
    install_kernel_modules && configure_sysctl
    apply_aggressive_sysctl_overlay
    log_info "bpftune 已从基础安装流程剥离，如需启用请在扩展管理中单独安装"
    verify_installation && show_final_message
}

run_cake_install() {
    QDISC_CHOICE="cake"
    echo -e "${CYAN}安装模式: BBR + CAKE${NC}"
    detect_os && detect_pkg_manager && detect_init_system && detect_kernel
    check_bpf_support && check_bbr_support && check_qdisc_support
    
    if [[ $CAKE_AVAILABLE -eq 0 ]]; then
        install_cake_module
    fi
    
    update_pkg_cache && install_dependencies
    install_kernel_modules && configure_sysctl
    apply_aggressive_sysctl_overlay
    log_info "bpftune 已从基础安装流程剥离，如需启用请在扩展管理中单独安装"
    verify_installation && show_final_message
}

run_interactive_install() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║      zhizhishu 网络优化助手 (BBR + 扩展模块 + 快照)          ║"
    echo "║      自动挡调优，省心省力                                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    detect_os
    detect_pkg_manager
    detect_init_system
    detect_kernel
    check_bpf_support
    check_bbr_support
    check_qdisc_support
    
    # 用户选择队列调度器
    if ! show_qdisc_menu; then
        return 0
    fi

    log_info "基础安装流程不包含 bpftune；如需启用，请在主菜单 5 的扩展管理中单独安装。"

    create_config_snapshot "before_interactive_install_${QDISC_CHOICE}"
    
    update_pkg_cache
    install_dependencies
    install_kernel_modules
    configure_sysctl
    apply_aggressive_sysctl_overlay
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
    check_root
    
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
            check_bpf_support && check_bbr_support && check_qdisc_support
            create_config_snapshot "before_cli_fq_install"
            update_pkg_cache && install_dependencies
            install_kernel_modules && configure_sysctl
            apply_aggressive_sysctl_overlay
            log_info "bpftune 已从基础安装流程剥离，如需启用请在扩展管理中单独安装"
            verify_installation && show_final_message
            ;;
        
        cake)
            QDISC_CHOICE="cake"
            echo -e "${CYAN}快速安装模式: BBR + CAKE${NC}"
            detect_os && detect_pkg_manager && detect_init_system && detect_kernel
            check_bpf_support && check_bbr_support && check_qdisc_support
            
            if [[ $CAKE_AVAILABLE -eq 0 ]]; then
                install_cake_module
            fi
            
            update_pkg_cache && install_dependencies
            install_kernel_modules && configure_sysctl
            apply_aggressive_sysctl_overlay
            log_info "bpftune 已从基础安装流程剥离，如需启用请在扩展管理中单独安装"
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

        bpftune-rm|bpftune-remove)
            detect_pkg_manager
            remove_bpftune
            ;;

        fail2ban)
            install_fail2ban_basic
            ;;

        fail2ban-rm|fail2ban-remove)
            remove_fail2ban_basic
            ;;

        extensions|extension|ext)
            show_extension_menu
            ;;

        vendor-check|provider-check|baseline-check)
            detect_provider_tuning_params
            ;;

        vendor-rescan|provider-rescan|baseline-rescan)
            rebuild_provider_baseline_from_sources
            ;;

        vendor-restore|provider-restore|baseline-restore)
            restore_provider_tuning_baseline
            ;;

        corona)
            apply_corona_profile
            ;;

        dmit-corona|corona-dmit)
            apply_corona_profile dmit
            ;;

        an4-corona|lax-an4-eb-corona|corona-an4)
            apply_corona_profile an4
            ;;

        api-sysctl|serverspan-api)
            apply_serverspan_api_profile general 0
            ;;

        api-general|serverspan-general)
            apply_serverspan_api_profile general 1 1 0 0
            ;;

        ipv4-prefer|prefer-ipv4)
            apply_ipv4_preference_no_disable_ipv6
            ;;

        brutal)
            install_tcp_brutal
            ;;

        brutal-rm|brutal-remove)
            remove_tcp_brutal
            ;;

        brutal-ng|brutal-nginx)
            install_brutal_nginx_module
            ;;
        
        ssh)
            detect_os && detect_init_system
            configure_ssh_root_login
            ;;
        
        ssh-off|ssh-disable)
            detect_os && detect_init_system
            disable_ssh_password_login
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

main "$@"
