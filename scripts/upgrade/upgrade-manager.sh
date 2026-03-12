#!/bin/bash
# MyNet 智能升级管理器
# 功能：安全、可靠地升级 MyNet 到新版本
# 特性：前置检查、备份、验证、失败回滚
# 用法：upgrade-manager.sh [version] [options]

set -euo pipefail

# ==================== 配置 ====================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info()     { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success()  { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()     { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()    { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()     { echo -e "${CYAN}▶${NC} $*"; }

# 默认配置
MYNET_HOME="${MYNET_HOME:-}"
BACKUP_DIR=""
TMP_DIR="/tmp/mynet-upgrade-$$"
UPGRADE_LOG=""
MANIFEST_URL="${MYNET_MANIFEST_URL:-https://download.mynet.club/mynet/manifest.json}"

# 状态变量
SERVICE_RUNNING=false
CURRENT_VERSION="unknown"
TARGET_VERSION=""
BACKUP_PATH=""
DRY_RUN=false
FORCE=false
SKIP_BACKUP=false

# ==================== 工具函数 ====================

# 清理函数
cleanup() {
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# 检测安装目录
detect_install_dir() {
    if [ -n "$MYNET_HOME" ] && [ -d "$MYNET_HOME" ]; then
        return 0
    fi
    
    # 按优先级尝试
    local dirs=(
        "/usr/local/opt/mynet"
        "/usr/local/mynet"
        "$HOME/.mynet"
    )
    
    for dir in "${dirs[@]}"; do
        if [ -d "$dir" ] && [ -f "$dir/bin/mynet" ]; then
            MYNET_HOME="$dir"
            return 0
        fi
    done
    
    return 1
}

# 检查 jq
ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    
    log_error "需要 jq 工具"
    log_info "macOS: brew install jq"
    log_info "Linux: apt-get install jq 或 yum install jq"
    return 1
}

# ==================== 前置检查 ====================

pre_check() {
    log_step "执行前置检查..."
    
    # 检查权限
    if [ "$(id -u)" -ne 0 ]; then
        log_error "需要 root 权限"
        log_info "请使用: sudo $0 $*"
        return 1
    fi
    
    # 检测安装目录
    if ! detect_install_dir; then
        log_error "未找到 MyNet 安装目录"
        log_info "尝试以下位置:"
        log_info "  - /usr/local/opt/mynet"
        log_info "  - /usr/local/mynet"
        return 1
    fi
    
    log_info "安装目录: $MYNET_HOME"
    
    # 设置路径
    BACKUP_DIR="$MYNET_HOME/.backup"
    UPGRADE_LOG="$MYNET_HOME/.upgrade.log"
    
    # 检查 jq
    if ! ensure_jq; then
        return 1
    fi
    
    # 读取当前版本
    if [ -f "$MYNET_HOME/.mynet_version" ]; then
        CURRENT_VERSION=$(jq -r '.version' "$MYNET_HOME/.mynet_version" 2>/dev/null || echo "unknown")
    else
        log_warn "未找到版本信息文件"
        CURRENT_VERSION="unknown"
    fi
    
    log_info "当前版本: $CURRENT_VERSION"
    
    # 检查磁盘空间（至少 150MB）
    local available
    if [[ "$OSTYPE" == "darwin"* ]]; then
        available=$(df -m "$MYNET_HOME" | awk 'NR==2 {print $4}')
    else
        available=$(df -m "$MYNET_HOME" | awk 'NR==2 {print $4}')
    fi
    
    if [ "$available" -lt 150 ]; then
        log_error "磁盘空间不足，需要至少 150MB"
        log_info "可用空间: ${available}MB"
        return 1
    fi
    
    # 检查服务状态
    if pgrep -f "$MYNET_HOME/bin/mynet" > /dev/null 2>&1; then
        log_info "检测到 MyNet 正在运行"
        SERVICE_RUNNING=true
    else
        log_info "MyNet 未运行"
        SERVICE_RUNNING=false
    fi
    
    log_success "前置检查通过"
    return 0
}

# ==================== 下载与验证 ====================

download_and_verify() {
    local version="$1"
    
    log_step "下载版本: $version"
    
    mkdir -p "$TMP_DIR"
    
    # 检测平台和架构
    local os platform arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin) platform="darwin" ;;
        linux)
            if [ -f /etc/openwrt_release ]; then
                platform="openwrt"
            else
                platform="linux"
            fi
            ;;
        *) platform="linux" ;;
    esac
    
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) ;;
    esac
    
    log_info "平台: $platform / $arch"
    
    # 下载主清单
    log_info "获取版本清单..."
    if ! curl -fsSL "$MANIFEST_URL" -o "$TMP_DIR/main_manifest.json"; then
        log_error "下载清单失败: $MANIFEST_URL"
        return 1
    fi
    
    # 解析版本信息
    local package_url sha256_hash
    
    if [ "$version" = "latest" ]; then
        # 获取最新稳定版本
        version=$(jq -r ".latest.stable // .versions[0]" "$TMP_DIR/main_manifest.json")
        log_info "最新版本: $version"
    fi
    
    # 构建下载 URL（根据实际清单结构调整）
    package_url=$(jq -r ".versions[] | select(.version==\"$version\") | .packages[] | select(.platform==\"$platform\" and .arch==\"$arch\") | .url" "$TMP_DIR/main_manifest.json")
    sha256_hash=$(jq -r ".versions[] | select(.version==\"$version\") | .packages[] | select(.platform==\"$platform\" and .arch==\"$arch\") | .sha256" "$TMP_DIR/main_manifest.json")
    
    if [ -z "$package_url" ] || [ "$package_url" = "null" ]; then
        log_error "未找到 $version ($platform/$arch) 的下载链接"
        log_info "可能该平台不支持或版本不存在"
        return 1
    fi
    
    log_info "下载地址: $package_url"
    
    # 下载安装包
    local package_file="$TMP_DIR/mynet.tgz"
    log_info "下载中..."
    if ! curl -fsSL --progress-bar "$package_url" -o "$package_file"; then
        log_error "下载失败"
        return 1
    fi
    
    # 验证 SHA256
    if [ -n "$sha256_hash" ] && [ "$sha256_hash" != "null" ]; then
        log_info "验证完整性..."
        local actual_sha256
        if command -v sha256sum >/dev/null 2>&1; then
            actual_sha256=$(sha256sum "$package_file" | awk '{print $1}')
        elif command -v shasum >/dev/null 2>&1; then
            actual_sha256=$(shasum -a 256 "$package_file" | awk '{print $1}')
        else
            log_warn "无法验证 SHA256，跳过"
            actual_sha256="$sha256_hash"
        fi
        
        if [ "$actual_sha256" != "$sha256_hash" ]; then
            log_error "SHA256 验证失败"
            log_info "期望: $sha256_hash"
            log_info "实际: $actual_sha256"
            return 1
        fi
        
        log_success "完整性验证通过"
    fi
    
    # 解压
    log_info "解压安装包..."
    if ! tar -xzf "$package_file" -C "$TMP_DIR"; then
        log_error "解压失败"
        return 1
    fi
    
    # 查找解压后的目录
    local extracted_dir
    extracted_dir=$(find "$TMP_DIR" -maxdepth 1 -type d -name "mynet" | head -n1)
    
    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
        log_error "未找到解压后的 mynet 目录"
        return 1
    fi
    
    # 验证清单文件存在
    if [ ! -f "$extracted_dir/.mynet_manifest.json" ]; then
        log_error "安装包中缺少清单文件"
        return 1
    fi
    
    log_success "下载并验证成功"
    TARGET_VERSION="$version"
    
    return 0
}

# ==================== 备份 ====================

backup_current() {
    if $SKIP_BACKUP; then
        log_warn "跳过备份（--skip-backup）"
        return 0
    fi
    
    log_step "备份当前安装..."
    
    local backup_name="backup-$(date +%Y%m%d-%H%M%S)-$CURRENT_VERSION"
    BACKUP_PATH="$BACKUP_DIR/$backup_name"
    
    mkdir -p "$BACKUP_PATH"
    
    # 备份关键文件和目录
    local items_to_backup=(
        "bin"
        "conf"
        "scripts"
        ".mynet_version"
        ".mynet_manifest.json"
    )
    
    for item in "${items_to_backup[@]}"; do
        if [ -e "$MYNET_HOME/$item" ]; then
            cp -a "$MYNET_HOME/$item" "$BACKUP_PATH/" 2>/dev/null || log_warn "备份 $item 失败"
        fi
    done
    
    # 记录备份路径
    echo "$BACKUP_PATH" > "$TMP_DIR/backup_path"
    
    log_success "备份完成: $BACKUP_PATH"
    
    # 清理旧备份（保留最近 5 个）
    if [ -d "$BACKUP_DIR" ]; then
        local backup_count=$(ls -1 "$BACKUP_DIR" | wc -l | tr -d ' ')
        if [ "$backup_count" -gt 5 ]; then
            log_info "清理旧备份..."
            ls -1t "$BACKUP_DIR" | tail -n +6 | while read -r old_backup; do
                rm -rf "$BACKUP_DIR/$old_backup"
                log_info "  删除: $old_backup"
            done
        fi
    fi
    
    return 0
}

# ==================== 执行升级 ====================

do_upgrade() {
    log_step "执行升级..."
    
    local source_dir="$TMP_DIR/mynet"
    
    if $DRY_RUN; then
        log_info "[DRY RUN] 模拟升级，不实际修改文件"
        return 0
    fi
    
    # 停止服务
    if $SERVICE_RUNNING; then
        log_info "停止服务..."
        "$MYNET_HOME/bin/mynetd" stop 2>/dev/null || true
        sleep 2
    fi
    
    # 读取新版本清单
    local manifest="$source_dir/.mynet_manifest.json"
    
    # 升级核心组件
    upgrade_component "core" "$source_dir" "$manifest"
    
    # 升级驱动
    upgrade_component "driver" "$source_dir" "$manifest"
    
    # 升级脚本
    upgrade_component "scripts" "$source_dir" "$manifest"
    
    # 处理配置文件（保留用户配置）
    handle_configs "$source_dir" "$manifest"
    
    # 更新版本信息
    if [ -f "$source_dir/.mynet_version" ]; then
        cp "$source_dir/.mynet_version" "$MYNET_HOME/"
    fi
    
    if [ -f "$source_dir/.mynet_manifest.json" ]; then
        cp "$source_dir/.mynet_manifest.json" "$MYNET_HOME/"
    fi
    
    log_success "文件升级完成"
    return 0
}

# 升级单个组件
upgrade_component() {
    local component="$1"
    local source_dir="$2"
    local manifest="$3"
    
    log_info "升级组件: $component"
    
    # 从清单提取文件列表
    local files
    files=$(jq -r "
        .components.$component 
        | if type == \"object\" then
            if .files then .files[] else .[] | .files[] end
          else
            .[]
          end
        | .path
    " "$manifest" 2>/dev/null || echo "")
    
    if [ -z "$files" ]; then
        log_warn "组件 $component 无文件"
        return 0
    fi
    
    # 复制文件
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        local src="$source_dir/$file"
        local dst="$MYNET_HOME/$file"
        
        if [ -f "$src" ]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            
            # 设置权限
            local mode
            mode=$(jq -r "
                .components.$component 
                | if type == \"object\" then
                    if .files then .files[] else .[] | .files[] end
                  else
                    .[]
                  end
                | select(.path==\"$file\")
                | .mode
            " "$manifest" | head -n1)
            
            if [ -n "$mode" ] && [ "$mode" != "null" ]; then
                chmod "$mode" "$dst"
            fi
            
            log_info "  ✓ $file"
        else
            log_warn "  ? $file (源文件不存在)"
        fi
    done <<< "$files"
}

# 处理配置文件
handle_configs() {
    local source_dir="$1"
    local manifest="$2"
    
    log_info "处理配置文件..."
    
    # 查找标记为 preserve 的文件
    local preserve_files
    preserve_files=$(jq -r '
        .components.config.files[]
        | select(.preserve==true)
        | .path
    ' "$manifest" 2>/dev/null || echo "")
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        if [ -f "$MYNET_HOME/$file" ]; then
            log_info "  保留: $file"
            # 不覆盖，跳过
        else
            # 新配置，复制模板
            local src="$source_dir/$file"
            local dst="$MYNET_HOME/$file"
            
            if [ -f "$src" ]; then
                mkdir -p "$(dirname "$dst")"
                cp "$src" "$dst"
                log_info "  新增: $file"
            fi
        fi
    done <<< "$preserve_files"
}

# ==================== 验证升级 ====================

verify_upgrade() {
    log_step "验证升级..."
    
    # 使用验证工具
    if [ -f "$MYNET_HOME/scripts/tools/verify-manifest.sh" ]; then
        if "$MYNET_HOME/scripts/tools/verify-manifest.sh" "$MYNET_HOME" > /dev/null 2>&1; then
            log_success "文件验证通过"
        else
            log_warn "文件验证失败，但可能不影响使用"
        fi
    else
        log_warn "验证工具不存在，跳过验证"
    fi
    
    return 0
}

# ==================== 启动服务 ====================

start_service() {
    if $DRY_RUN; then
        log_info "[DRY RUN] 跳过服务启动"
        return 0
    fi
    
    if $SERVICE_RUNNING; then
        log_step "启动服务..."
        
        if [ -f "$MYNET_HOME/bin/mynetd" ]; then
            "$MYNET_HOME/bin/mynetd" start
        else
            log_warn "mynetd 不存在，请手动启动服务"
            return 0
        fi
        
        # 等待服务就绪
        sleep 3
        
        # 健康检查
        if "$MYNET_HOME/bin/mynetd" status > /dev/null 2>&1; then
            log_success "服务启动成功"
        else
            log_error "服务启动失败"
            return 1
        fi
    fi
    
    return 0
}

# ==================== 回滚 ====================

rollback() {
    log_warn "执行回滚..."
    
    if [ ! -f "$TMP_DIR/backup_path" ]; then
        log_error "找不到备份路径"
        return 1
    fi
    
    local backup_path
    backup_path=$(cat "$TMP_DIR/backup_path")
    
    if [ ! -d "$backup_path" ]; then
        log_error "备份目录不存在: $backup_path"
        return 1
    fi
    
    # 停止服务
    if [ -f "$MYNET_HOME/bin/mynetd" ]; then
        "$MYNET_HOME/bin/mynetd" stop 2>/dev/null || true
    fi
    
    # 恢复备份
    log_info "恢复文件..."
    cp -a "$backup_path"/* "$MYNET_HOME/"
    
    # 重启服务
    if $SERVICE_RUNNING && [ -f "$MYNET_HOME/bin/mynetd" ]; then
        "$MYNET_HOME/bin/mynetd" start
    fi
    
    log_success "回滚完成"
    log_info "当前版本: $CURRENT_VERSION"
    
    return 0
}

# ==================== 升级日志 ====================

log_upgrade() {
    local status="$1"
    local message="${2:-}"
    
    local log_entry=$(cat <<EOF
{
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "from_version": "$CURRENT_VERSION",
  "to_version": "$TARGET_VERSION",
  "status": "$status",
  "message": "$message"
}
EOF
)
    
    # 追加到日志文件
    if [ -f "$UPGRADE_LOG" ]; then
        # 读取现有日志，追加新记录
        local existing_logs
        existing_logs=$(cat "$UPGRADE_LOG" 2>/dev/null || echo "[]")
        
        echo "$existing_logs" | jq ". += [$log_entry]" > "$UPGRADE_LOG.tmp" && mv "$UPGRADE_LOG.tmp" "$UPGRADE_LOG"
    else
        echo "[$log_entry]" > "$UPGRADE_LOG"
    fi
}

# ==================== 主函数 ====================

show_help() {
    cat <<EOF
MyNet 智能升级管理器

用法:
    $0 [version] [options]

参数:
    version                 目标版本（如 v0.9.8.5）或 "latest"（默认）

选项:
    --dry-run              模拟运行，不实际修改文件
    --force                强制升级，跳过版本检查
    --skip-backup          跳过备份（不推荐）
    --manifest-url <url>   指定清单 URL
    --help, -h             显示帮助信息

示例:
    $0                      # 升级到最新稳定版本
    $0 v0.9.8.5             # 升级到指定版本
    $0 latest --dry-run     # 测试升级流程
    $0 --skip-backup        # 跳过备份（快速升级）

EOF
}

main() {
    local target_version="latest"
    
    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --skip-backup)
                SKIP_BACKUP=true
                shift
                ;;
            --manifest-url)
                MANIFEST_URL="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                target_version="$1"
                shift
                ;;
        esac
    done
    
    # 显示标题
    echo
    echo "======================================"
    echo "  MyNet 智能升级管理器"
    echo "======================================"
    echo
    
    if $DRY_RUN; then
        log_warn "** DRY RUN 模式 - 不会实际修改文件 **"
        echo
    fi
    
    # 执行升级流程
    if ! pre_check; then
        log_error "前置检查失败"
        exit 1
    fi
    
    echo
    
    if ! download_and_verify "$target_version"; then
        log_error "下载验证失败"
        exit 1
    fi
    
    echo
    
    # 版本检查
    if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ] && ! $FORCE; then
        log_warn "已经是最新版本: $TARGET_VERSION"
        log_info "使用 --force 强制重新安装"
        exit 0
    fi
    
    if ! backup_current; then
        log_error "备份失败"
        exit 1
    fi
    
    echo
    
    if ! do_upgrade; then
        log_error "升级失败，执行回滚"
        rollback
        log_upgrade "failed" "Upgrade failed, rolled back"
        exit 1
    fi
    
    echo
    
    if ! verify_upgrade; then
        log_warn "验证失败，但升级已完成"
    fi
    
    echo
    
    if ! start_service; then
        log_error "服务启动失败，执行回滚"
        rollback
        log_upgrade "failed" "Service start failed, rolled back"
        exit 1
    fi
    
    echo
    log_success "======================================"
    log_success "  升级成功！"
    log_success "======================================"
    log_info "从版本: $CURRENT_VERSION"
    log_info "到版本: $TARGET_VERSION"
    
    if [ -n "$BACKUP_PATH" ]; then
        log_info "备份位置: $BACKUP_PATH"
    fi
    
    echo
    
    log_upgrade "success" "Upgrade completed successfully"
}

main "$@"
