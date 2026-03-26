#!/bin/bash
#
# mynet_proxy Web 安装脚本
# 用法: curl -fsSL https://ctl.mynet.club/mp/install.sh | bash
#       或: wget -qO- https://ctl.mynet.club/mp/install.sh | bash
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[→]${NC} $1"
}

# 检测平台
detect_platform() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "$os" in
        linux)
            if [[ -f "/etc/openwrt_release" ]]; then
                echo "openwrt"
            else
                echo "linux"
            fi
            ;;
        darwin) echo "darwin" ;;
        *) echo "unknown" ;;
    esac
}

# 检测架构
detect_arch() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        mips) echo "mips" ;;
        mipsel) echo "mipsel" ;;
        i386|i686) echo "i386" ;;
        *) echo "$arch" ;;
    esac
}

# 查找 mynet 安装目录
find_mynet_home() {
    local platform=$(detect_platform)
    local paths_to_check=()
    
    case "$platform" in
        "openwrt")
            paths_to_check=("/etc/mynet")
            ;;
        "linux")
            paths_to_check=("/usr/local/mynet" "/opt/mynet")
            ;;
        "darwin")
            paths_to_check=("/usr/local/opt/mynet" "/usr/local/mynet" "/opt/mynet")
            ;;
    esac
    
    if [[ -n "${MYNET_HOME:-}" ]]; then
        paths_to_check=("$MYNET_HOME" "${paths_to_check[@]}")
    fi
    
    for path in "${paths_to_check[@]}"; do
        if [[ -f "$path/conf/mynet.conf" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# 主安装流程
main() {
    echo ""
    echo "========================================="
    echo "  MyNet Proxy 插件在线安装"
    echo "========================================="
    echo ""
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        log_error "需要 root 权限"
        echo "请使用 sudo 运行:"
        echo "  curl -fsSL https://ctl.mynet.club/mp/install.sh | sudo bash"
        exit 1
    fi
    
    # 检测平台
    local platform=$(detect_platform)
    local arch=$(detect_arch)
    
    log_info "平台: $platform"
    log_info "架构: $arch"
    
    # 查找 mynet 安装目录
    log_step "查找 mynet 安装目录..."
    local mynet_home=$(find_mynet_home)
    
    if [[ -z "$mynet_home" ]]; then
        log_error "未找到 mynet 安装"
        log_info "请先安装 mynet: https://mynet.club"
        exit 1
    fi
    
    log_success "找到 mynet: $mynet_home"
    
    # 下载最新版本信息
    log_step "获取最新版本..."
    local base_url="${CTL_BASE_URL:-https://ctl.mynet.club}/mp"
    local version="WEBINSTALL_VERSION"
    
    log_info "版本: $version"
    
    # 构建下载文件名
    local filename="mynet_proxy_${platform}_${arch}_${version}.tgz"
    local download_url="$base_url/$version/$filename"
    
    log_step "下载插件包..."
    log_info "URL: $download_url"
    
    # 创建临时目录
    local tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT
    
    # 下载文件
    if command -v curl >/dev/null 2>&1; then
        if ! curl -fsSL "$download_url" -o "$tmp_dir/$filename"; then
            log_error "下载失败"
            log_info "请检查网络连接或版本是否存在"
            exit 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q "$download_url" -O "$tmp_dir/$filename"; then
            log_error "下载失败"
            exit 1
        fi
    else
        log_error "未找到 curl 或 wget"
        exit 1
    fi
    
    log_success "下载完成"
    
    # 解压
    log_step "解压安装包..."
    cd "$tmp_dir"
    if ! tar -xzf "$filename"; then
        log_error "解压失败"
        exit 1
    fi
    
    # 解压后的目录固定为 mynet_proxy
    local extract_dir="mynet_proxy"
    
    if [[ ! -d "$extract_dir" ]]; then
        log_error "未找到解压目录: $extract_dir"
        log_info "当前目录内容:"
        ls -la
        exit 1
    fi
    
    cd "$extract_dir"
    log_success "✓ 进入目录: $extract_dir"
    
    # 运行安装脚本
    log_step "运行安装脚本..."
    echo ""
    
    if [[ ! -f "install.sh" ]]; then
        log_error "未找到安装脚本"
        exit 1
    fi
    
    # 确保 install.sh 可执行
    chmod +x install.sh
    
    # 运行安装（已经是 root 身份）
    export MYNET_HOME="$mynet_home"
    if bash install.sh install; then
        echo ""
        log_success "========================================="
        log_success "安装完成！"
        log_success "========================================="
    else
        echo ""
        log_error "========================================="
        log_error "安装失败！"
        log_error "========================================="
        log_info "请检查上面的错误信息"
        exit 1
    fi
}

main "$@"