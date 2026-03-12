#!/bin/bash
# MyNet 清单验证工具
# 功能：验证安装目录中的文件与清单是否一致
# 用法：verify-manifest.sh [install_dir]

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
log_error()   { echo -e "${RED}[✗]${NC} $*"; }

# 默认安装目录
INSTALL_DIR="${1:-}"

if [ -z "$INSTALL_DIR" ]; then
    # 自动检测安装目录
    if [ -d "/usr/local/opt/mynet" ]; then
        INSTALL_DIR="/usr/local/opt/mynet"
    elif [ -d "/usr/local/mynet" ]; then
        INSTALL_DIR="/usr/local/mynet"
    else
        log_error "找不到 MyNet 安装目录"
        echo "用法: $0 [install_dir]"
        exit 1
    fi
fi

log_info "验证目录: $INSTALL_DIR"

# 检查目录
if [ ! -d "$INSTALL_DIR" ]; then
    log_error "目录不存在: $INSTALL_DIR"
    exit 1
fi

# 检查清单文件
MANIFEST_FILE="$INSTALL_DIR/.mynet_manifest.json"
if [ ! -f "$MANIFEST_FILE" ]; then
    log_error "清单文件不存在: $MANIFEST_FILE"
    log_warn "这可能是旧版本安装，尚未支持清单验证"
    exit 1
fi

# 检查 jq
if ! command -v jq >/dev/null 2>&1; then
    log_error "需要安装 jq 工具"
    log_info "macOS: brew install jq"
    log_info "Linux: apt-get install jq 或 yum install jq"
    exit 1
fi

# 读取版本信息
VERSION=$(jq -r '.version' "$MANIFEST_FILE")
PLATFORM=$(jq -r '.platform' "$MANIFEST_FILE")
ARCH=$(jq -r '.arch' "$MANIFEST_FILE")

log_info "版本: $VERSION"
log_info "平台: $PLATFORM / $ARCH"
echo

# 计算文件哈希
calculate_hash() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        echo "unknown"
    fi
}

# 获取文件权限
get_file_mode() {
    local file="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f "%Op" "$file" | tail -c 5
    else
        stat -c "%a" "$file"
    fi
}

# 统计变量
total_files=0
verified_files=0
failed_files=0
missing_files=0
extra_files=0
permission_issues=0

# 提取所有文件路径（从所有组件）
extract_all_files() {
    jq -r '
        .components 
        | to_entries[] 
        | .value 
        | if type == "object" then
            if .files then .files[] else .[] | .files[] end
          else
            .[]
          end
        | .path
    ' "$MANIFEST_FILE" 2>/dev/null | sort -u
}

# 验证单个文件
verify_file() {
    local rel_path="$1"
    local full_path="$INSTALL_DIR/$rel_path"
    
    ((total_files++))
    
    # 检查文件是否存在
    if [ ! -f "$full_path" ]; then
        log_error "$rel_path (文件缺失)"
        ((missing_files++))
        ((failed_files++))
        return 1
    fi
    
    # 获取期望的 SHA256 和权限
    local expected_sha256=$(jq -r "
        .components 
        | to_entries[] 
        | .value 
        | if type == \"object\" then
            if .files then .files[] else .[] | .files[] end
          else
            .[]
          end
        | select(.path == \"$rel_path\")
        | .sha256
    " "$MANIFEST_FILE" | head -n1)
    
    local expected_mode=$(jq -r "
        .components 
        | to_entries[] 
        | .value 
        | if type == \"object\" then
            if .files then .files[] else .[] | .files[] end
          else
            .[]
          end
        | select(.path == \"$rel_path\")
        | .mode
    " "$MANIFEST_FILE" | head -n1)
    
    # 验证 SHA256
    local actual_sha256=$(calculate_hash "$full_path")
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        log_error "$rel_path (SHA256 不匹配)"
        log_info "  期望: $expected_sha256"
        log_info "  实际: $actual_sha256"
        ((failed_files++))
        return 1
    fi
    
    # 验证权限
    local actual_mode=$(get_file_mode "$full_path")
    if [ "$actual_mode" != "$expected_mode" ]; then
        log_warn "$rel_path (权限不匹配: 期望 $expected_mode, 实际 $actual_mode)"
        ((permission_issues++))
    fi
    
    # 验证通过
    log_success "$rel_path"
    ((verified_files++))
    return 0
}

# 主验证流程
main() {
    log_info "开始验证文件..."
    echo
    
    # 验证所有清单中的文件
    while IFS= read -r filepath; do
        [ -z "$filepath" ] && continue
        verify_file "$filepath"
    done < <(extract_all_files)
    
    echo
    log_info "验证完成"
    echo
    
    # 输出统计信息
    echo "======================================"
    echo "验证结果统计"
    echo "======================================"
    echo "总文件数:     $total_files"
    echo "验证通过:     $verified_files"
    echo "验证失败:     $failed_files"
    echo "  - 缺失文件: $missing_files"
    echo "权限问题:     $permission_issues"
    echo "======================================"
    echo
    
    # 检查额外文件（不在清单中的文件）
    log_info "检查额外文件..."
    check_extra_files
    
    echo
    
    # 返回状态
    if [ $failed_files -gt 0 ]; then
        log_error "验证失败！发现 $failed_files 个问题"
        exit 1
    elif [ $permission_issues -gt 0 ]; then
        log_warn "验证通过，但有 $permission_issues 个权限警告"
        exit 0
    else
        log_success "所有文件验证通过！"
        exit 0
    fi
}

# 检查额外文件（不在清单中）
check_extra_files() {
    # 获取清单中的所有文件
    local manifest_files=$(extract_all_files)
    
    # 遍历实际目录
    cd "$INSTALL_DIR"
    find . -type f ! -path "./.mynet_*" ! -path "./log/*" ! -path "./tmp/*" ! -path "./var/*" | sort | while read -r filepath; do
        local rel_path="${filepath#./}"
        
        # 检查是否在清单中
        if ! echo "$manifest_files" | grep -qx "$rel_path"; then
            log_warn "额外文件: $rel_path (不在清单中)"
            ((extra_files++))
        fi
    done
    
    if [ $extra_files -eq 0 ]; then
        log_success "没有发现额外文件"
    else
        log_warn "发现 $extra_files 个额外文件"
    fi
}

# 修复模式
fix_mode() {
    log_info "修复模式：尝试恢复损坏的文件..."
    
    # 需要从远程下载当前版本
    local version=$(jq -r '.version' "$MANIFEST_FILE")
    local platform=$(jq -r '.platform' "$MANIFEST_FILE")
    local arch=$(jq -r '.arch' "$MANIFEST_FILE")
    
    log_info "版本: $version"
    log_info "平台: $platform / $arch"
    
    # TODO: 实现文件修复逻辑
    # 1. 下载对应版本的包
    # 2. 仅提取损坏的文件
    # 3. 替换到安装目录
    
    log_warn "修复功能尚未实现"
    exit 1
}

# 详细模式
verbose_mode() {
    log_info "详细模式：显示所有文件信息..."
    
    # 提取并显示所有文件的详细信息
    jq -r '
        .components 
        | to_entries[] 
        | .key as $component
        | .value 
        | if type == "object" then
            if .files then 
                .files[] | [$component, .path, .mode, .sha256, .required // false, .preserve // false]
            else 
                .[] | .files[] | [$component, .path, .mode, .sha256, .required // false, .preserve // false]
            end
          else
            .[]
          end
        | @tsv
    ' "$MANIFEST_FILE" | while IFS=$'\t' read -r component path mode sha256 required preserve; do
        echo "======================================"
        echo "组件:     $component"
        echo "路径:     $path"
        echo "权限:     $mode"
        echo "SHA256:   $sha256"
        echo "必需:     $required"
        echo "保留:     $preserve"
    done
}

# 参数解析
case "${1:-verify}" in
    --fix)
        fix_mode
        ;;
    --verbose|-v)
        verbose_mode
        ;;
    --help|-h)
        cat <<EOF
MyNet 清单验证工具

用法:
    $0 [install_dir]              # 验证安装目录
    $0 --fix                      # 修复损坏的文件
    $0 --verbose                  # 显示详细信息
    $0 --help                     # 显示帮助

示例:
    $0                            # 自动检测并验证
    $0 /usr/local/opt/mynet       # 验证指定目录
    $0 --verbose                  # 显示所有文件详情

EOF
        exit 0
        ;;
    *)
        main
        ;;
esac
