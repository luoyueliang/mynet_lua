#!/usr/bin/env bash
set -euo pipefail

# MyNet 高级安装脚本
# 提供更多安装选项，但仍遵循"只管复制文件"的原则
#
# 使用方式:
#   curl -fsSL https://example.com/install-advanced.sh | bash
#   curl -fsSL https://example.com/install-advanced.sh | MYNET_VERSION=v1.0.0 bash
#   curl -fsSL https://example.com/install-advanced.sh | MYNET_INSTALL_DIR=/custom/path bash

# 配置项
SCRIPT_VERSION="1.0.0"  # 脚本版本（用于自更新检测）
CTL_BASE_URL="${CTL_BASE_URL:-https://ctl.mynet.club}"
SCRIPT_UPDATE_URL="${CTL_BASE_URL}/v.json"  # 脚本版本清单
MANIFEST_URL_DEFAULT="${CTL_BASE_URL}/api/v2/mynet/manifest.json"
MANIFEST_URL="${MYNET_MANIFEST_URL:-$MANIFEST_URL_DEFAULT}"
TMP_DIR="${TMPDIR:-/tmp}/mynet-install-$$"

# ==============================================================================
# 架构映射列表 (硬编码,与 scripts/common/arch_list.txt 保持同步)
# ==============================================================================
# 格式: uname_m|fpu_type|arch|goarch|goarm
readonly ARCH_LIST='
x86_64|none|amd64|amd64|
amd64|none|amd64|amd64|
i386|none|i386|386|
i686|none|i386|386|
arm64|hard|arm64|arm64|
arm64|soft|arm64-softfp|arm64|
aarch64|hard|arm64|arm64|
aarch64|soft|arm64-softfp|arm64|
armv7l|hard|armv7|arm|7
armv7l|soft|armv7-softfp|arm|7
mips64|none|mips64|mips64|
mips64el|none|mips64el|mips64le|
mips|hard|mips|mips|
mips|soft|mips-softfp|mips|
mipsel|hard|mipsel|mipsle|
mipsel|soft|mipsel-softfp|mipsle|
riscv64|none|riscv64|riscv64|
'

# 样式定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# 日志函数
log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
debug()   { [[ "${MYNET_DEBUG:-}" == "1" ]] && echo -e "${PURPLE}[DEBUG]${NC} $*" || true; }

# 工具检查
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 脚本自更新检测（可选功能，失败不影响安装）
check_script_update() {
    # 如果设置了 SKIP_SCRIPT_UPDATE=1，跳过更新检测
    [[ "${SKIP_SCRIPT_UPDATE:-}" == "1" ]] && return 0

    # 如果没有 jq，跳过（不强制要求）
    have_cmd jq || return 0

    # 获取远程版本清单（静默失败）
    local remote_manifest
    if ! remote_manifest=$(curl -fsSL --max-time 3 "$SCRIPT_UPDATE_URL" 2>/dev/null); then
        debug "无法获取脚本更新信息（网络问题或超时）"
        return 0
    fi

    # 提取 install.sh 的远程版本
    local remote_version
    if ! remote_version=$(echo "$remote_manifest" | jq -r '.scripts["install.sh"].version' 2>/dev/null); then
        debug "无法解析版本信息"
        return 0
    fi

    # 比较版本（简单字符串比较）
    if [[ "$remote_version" != "$SCRIPT_VERSION" && "$remote_version" != "null" ]]; then
        warn "检测到安装脚本更新: $SCRIPT_VERSION → $remote_version"
        log "重新下载最新安装脚本..."

        # 下载新脚本
        local new_script="/tmp/mynet-install-new-$$.sh"
        if curl -fsSL "${CTL_BASE_URL}/install.sh" -o "$new_script"; then
            chmod +x "$new_script"
            log "使用最新脚本重新执行..."
            # 设置标志避免循环更新
            export SKIP_SCRIPT_UPDATE=1
            exec bash "$new_script" "$@"
        else
            warn "下载新脚本失败，使用当前版本继续"
        fi
    else
        debug "脚本已是最新版本: $SCRIPT_VERSION"
    fi

    return 0
}

# 自动安装 jq (Linux 系统专用)
ensure_jq() {
    local os="$1" arch="$2"

    # 如果已经有 jq，直接返回
    have_cmd jq && return 0

    # 只在 Linux 系统（包括 OpenWrt）上自动安装
    [[ "$os" != "linux" && "$os" != "openwrt" ]] && return 1

    log "正在自动安装 jq 工具..."

    # 映射架构到 jq 文件名
    # jq 使用特殊命名: armhf(hard-float), armel(soft-float), 且没有 mips-softfp 等变体
    local jq_arch="$arch"
    case "$arch" in
        armv7)            jq_arch="armhf" ;;    # hard-float -> armhf
        armv7-softfp)     jq_arch="armel" ;;    # soft-float -> armel
        arm64-softfp)     jq_arch="arm64" ;;    # arm64 soft 也用 arm64
        mipsel-softfp)    jq_arch="mipsel" ;;   # mipsel soft 也用 mipsel
        mips-softfp)      jq_arch="mips" ;;     # mips soft 也用 mips
    esac

    # 尝试下载特定架构的 jq
    local jq_url="${CTL_BASE_URL}/tools/jq-linux-${jq_arch}"
    local jq_bin="/usr/local/bin/jq"
    [[ -w "/usr/bin" ]] && jq_bin="/usr/bin/jq"

    local download_success=0
    if have_cmd curl; then
        if curl -fsSL "$jq_url" -o "$jq_bin" 2>/dev/null; then
            download_success=1
        fi
    elif have_cmd wget; then
        if wget -q -O "$jq_bin" "$jq_url" 2>/dev/null; then
            download_success=1
        fi
    fi

    # 如果特定架构下载失败，尝试 latest (通用版本)
    if [[ $download_success -eq 0 ]]; then
        warn "未找到 jq-linux-${jq_arch}，尝试使用通用版本..."
        jq_url="${CTL_BASE_URL}/tools/jq-linux-latest"

        if have_cmd curl; then
            curl -fsSL "$jq_url" -o "$jq_bin" 2>/dev/null && download_success=1
        elif have_cmd wget; then
            wget -q -O "$jq_bin" "$jq_url" 2>/dev/null && download_success=1
        fi
    fi

    if [[ $download_success -eq 1 ]]; then
        chmod +x "$jq_bin" && success "jq 安装成功" && return 0
    fi

    warn "jq 自动安装失败，请手动安装"
    return 1
}

# 清理函数
cleanup() {
    debug "清理临时目录: $TMP_DIR"
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

# 下载函数
fetch() {
    local url="$1" output="$2" desc="${3:-文件}"
    debug "下载 $desc: $url -> $output"

    if have_cmd curl; then
        curl -fsSL --progress-bar "$url" -o "$output"
    elif have_cmd wget; then
        wget --progress=bar:force -qO "$output" "$url"
    else
        error "需要 curl 或 wget"
        exit 1
    fi
}

# 检测 OpenWrt 架构 (优先级最高,因为 uname -m 在某些 OpenWrt 设备上不可靠)
detect_openwrt_arch() {
    # 尝试从 /etc/openwrt_release 获取架构
    if [[ -f /etc/openwrt_release ]]; then
        local distrib_arch
        distrib_arch=$(grep '^DISTRIB_ARCH=' /etc/openwrt_release 2>/dev/null | cut -d"'" -f2 || true)

        if [[ -n "$distrib_arch" ]]; then
            # 提取基础架构 (如 mipsel_24kc -> mipsel)
            # 注意: 不要处理 x86_64 这样的标准架构名称
            local base_arch="$distrib_arch"
            case "$distrib_arch" in
                mipsel_*|mips_*|arm_*|aarch64_*)
                    # 只对带 CPU 型号后缀的架构提取基础部分
                    base_arch="${distrib_arch%%_*}"
                    ;;
            esac
            echo "$base_arch"
            return 0
        fi
    fi

    # 尝试从 opkg 配置获取架构
    if have_cmd opkg; then
        local opkg_arch
        opkg_arch=$(opkg print-architecture 2>/dev/null | grep -oE 'mipsel|mips|aarch64|arm|x86_64|i386' | head -n1 || true)

        if [[ -n "$opkg_arch" ]]; then
            echo "$opkg_arch"
            return 0
        fi
    fi

    # 无法检测
    return 1
}

# 检测 FPU 类型
detect_fpu() {
    local uname_m="$1"

    # 非 Linux 系统默认 hard-float
    [[ ! -f /proc/cpuinfo ]] && echo "hard" && return

    case "$uname_m" in
        arm64|aarch64)
            # ARM64 检查 fp/asimd 特性
            if grep -qiE "Features.*(fp|asimd)" /proc/cpuinfo 2>/dev/null; then
                echo "hard"
            else
                echo "soft"
            fi
            ;;
        armv7l|armv7|armv6l|armv6)
            # ARM 32位检查 vfp/neon 特性
            if grep -qiE "Features.*(vfp|neon)" /proc/cpuinfo 2>/dev/null; then
                echo "hard"
            else
                echo "soft"
            fi
            ;;
        mipsel|mips)
            # MIPS 检查 FPU 字段
            # 逻辑: 如果找到 FPU 且不是 none/soft,才是 hard-float
            # 否则(没有FPU或FPU是none/soft)都是 soft-float
            if grep -qiE "^FPU" /proc/cpuinfo 2>/dev/null; then
                # 有 FPU 字段,检查值
                if grep -qiE "FPU.*:.*none|FPU.*:.*soft" /proc/cpuinfo 2>/dev/null; then
                    echo "soft"
                else
                    # FPU 字段存在且不是 none/soft,说明有硬件 FPU
                    echo "hard"
                fi
            else
                # 没有 FPU 字段,说明是 soft-float
                echo "soft"
            fi
            ;;
        *)
            # 其他架构默认 none (不区分 FPU)
            echo "none"
            ;;
    esac
}

# 从硬编码的架构列表查找架构标识
find_arch_from_list() {
    local uname_m="$1"
    local fpu="$2"

    # 读取硬编码的 ARCH_LIST 并查找匹配项
    while IFS='|' read -r list_uname_m list_fpu list_arch list_goarch list_goarm; do
        # 跳过空行和注释
        [[ -z "$list_uname_m" || "$list_uname_m" =~ ^[[:space:]]*# ]] && continue

        # 去除前后空格
        list_uname_m=$(echo "$list_uname_m" | xargs)
        list_fpu=$(echo "$list_fpu" | xargs)
        list_arch=$(echo "$list_arch" | xargs)

        # 匹配 uname_m 和 fpu
        if [[ "$list_uname_m" == "$uname_m" ]]; then
            # 如果 list_fpu 是 none,忽略 FPU 类型
            if [[ "$list_fpu" == "none" || "$list_fpu" == "$fpu" ]]; then
                echo "$list_arch"
                return 0
            fi
        fi
    done <<< "$ARCH_LIST"

    return 1
}

# 系统检测
detect_system() {
    local os arch

    # 检测操作系统
    if [[ -f /etc/openwrt_release ]] || [[ -x /bin/opkg ]] || [[ -x /usr/bin/opkg ]]; then
        os="openwrt"
    else
        case "$(uname -s)" in
            Linux)   os="linux" ;;
            Darwin)  os="darwin" ;;
            FreeBSD) os="freebsd" ;;
            MINGW*|MSYS*|CYGWIN*) os="windows" ;;
            *)
                error "不支持的操作系统: $(uname -s)"
                exit 1
                ;;
        esac
    fi

    # 获取 uname -m 结果
    local uname_m
    uname_m="$(uname -m)"

    # OpenWrt 特殊处理: 优先使用 /etc/openwrt_release 的架构信息
    # 因为某些 OpenWrt 设备的 uname -m 不准确 (如 MT7621 返回 mips 实际是 mipsel)
    if [[ "$os" == "openwrt" ]]; then
        local openwrt_arch
        openwrt_arch=$(detect_openwrt_arch || echo "")

        if [[ -n "$openwrt_arch" ]]; then
            debug "OpenWrt 架构覆盖: $uname_m -> $openwrt_arch (从 /etc/openwrt_release)"
            uname_m="$openwrt_arch"
        else
            warn "无法从 /etc/openwrt_release 获取架构,使用 uname -m: $uname_m"
        fi
    fi

    # 检测 FPU 类型
    local fpu
    fpu=$(detect_fpu "$uname_m")
    debug "uname -m: $uname_m, FPU: $fpu"

    # 从硬编码的架构列表查找匹配
    arch=$(find_arch_from_list "$uname_m" "$fpu")

    if [[ -z "$arch" ]]; then
        error "不支持的架构: $uname_m (FPU: $fpu)"
        error "请访问 https://github.com/yourusername/mynet 报告此问题"
        exit 1
    fi

    debug "检测到架构: $arch"

    echo "${os}|${arch}"
}

# 选择安装目录
get_default_install_dir() {
    local os="$1"
    case "$os" in
        openwrt)  echo "/etc/mynet" ;;
        linux)    echo "/usr/local/mynet" ;;
        darwin)   echo "/usr/local/opt/mynet" ;;
        windows)  echo "/c/Program Files/MyNet" ;;
        *)        echo "/opt/mynet" ;;
    esac
}

# 列出可用版本
list_available_versions() {
    local manifest_file="$1" os="$2" arch="$3"

    if ! have_cmd jq; then
        debug "需要 jq 工具来列出可用版本"
        return 1
    fi

    debug "获取可用版本列表..."

    # 获取所有版本并过滤出有对应平台包的版本
    local versions=""
    versions=$(jq -r --arg os "$os" --arg arch "$arch" '
        .versions | to_entries |
        map(select(.value.artifacts[]? | select(.os==$os and .arch==$arch))) |
        .[].key
    ' "$manifest_file" 2>/dev/null | sort -rV | head -n 10 || echo "")

    if [[ -z "$versions" ]]; then
        debug "未找到适用于 $os/$arch 的版本"
        return 1
    fi

    echo "$versions"
}

# 交互式选择版本
select_version_interactive() {
    local manifest_file="$1" os="$2" arch="$3"

    # 获取最新稳定版本（初始化为空，避免 unbound variable）
    local latest_stable=""
    if have_cmd jq; then
        latest_stable=$(jq -r '.latest_stable // .latest.stable // empty' "$manifest_file" 2>/dev/null || echo "")
    fi

    # 如果没有获取到，使用默认值
    if [[ -z "$latest_stable" ]]; then
        latest_stable="latest_stable"
    fi

    # 列出可用版本
    local versions=""
    versions=$(list_available_versions "$manifest_file" "$os" "$arch" || echo "")

    if [[ -z "$versions" ]]; then
        # 无法获取版本列表，直接返回最新稳定版（不显示任何界面）
        echo "$latest_stable"
        return 0
    fi

    # 显示版本选择界面标题（输出到标准错误，避免管道问题）
    {
        echo
        echo "=========================================="
        echo "  请选择要安装的版本"
        echo "=========================================="
        echo
    } >&2

    # 显示版本列表
    local i=1
    local version_array=()

    while IFS= read -r version; do
        version_array+=("$version")
        if [[ "$version" == "$latest_stable" ]]; then
            echo "  $i) $version [推荐]" >&2
        else
            echo "  $i) $version" >&2
        fi
        i=$((i + 1))
    done <<< "$versions"

    {
        echo
        echo "  0) 手动输入版本号"
        echo
        echo "=========================================="
        echo
    } >&2

    # 用户选择
    local choice
    while true; do
        read -r -p "请选择 [0-${#version_array[@]}] (直接回车默认选择 1): " choice >&2
        choice=${choice:-1}

        if [[ "$choice" == "0" ]]; then
            echo
            read -r -p "请输入版本号 (如 v0.9.4.18): " custom_version
            if [[ -n "$custom_version" ]]; then
                echo "$custom_version"
                return 0
            else
                continue
            fi
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#version_array[@]}" ]]; then
            echo "${version_array[$((choice-1))]}"
            return 0
        else
            error "无效的选择，请重新输入"
        fi
    done
}

# 交互式选择安装目录
select_install_dir_interactive() {
    local default_dir="$1" os="$2"

    # 确保输出到标准错误（避免管道问题）
    {
        echo
        echo "=========================================="
        echo "  请选择安装目录"
        echo "=========================================="
        echo
        echo "  1) 使用默认目录 [推荐]"
        echo "     → $default_dir"
        echo
        echo "  2) 自定义安装目录"
        echo "     → 手动指定安装路径"
        echo
        echo "=========================================="
        echo
    } >&2

    local choice
    read -r -p "请选择 [1-2] (直接回车默认选择 1): " choice >&2
    choice=${choice:-1}

    case "$choice" in
        1)
            echo "$default_dir"
            ;;
        2)
            local custom_dir
            echo
            echo "提示: 请输入绝对路径 (以 / 开头)"
            while true; do
                read -r -p "安装目录: " custom_dir

                if [[ -z "$custom_dir" ]]; then
                    warn "路径不能为空，请重新输入"
                    continue
                fi

                # 展开 ~ 为 $HOME
                custom_dir="${custom_dir/#\~/$HOME}"

                # 验证路径格式
                if [[ ! "$custom_dir" =~ ^/ ]]; then
                    warn "请输入绝对路径（以 / 开头）"
                    continue
                fi

                # 检查目录是否存在
                if [[ -d "$custom_dir" ]]; then
                    warn "目录已存在: $custom_dir"
                    read -r -p "是否覆盖现有安装? [y/N]: " overwrite
                    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                        continue
                    fi
                fi

                # 检查是否可以创建目录
                local test_dir="$custom_dir"
                while [[ ! -d "$test_dir" ]]; do
                    test_dir=$(dirname "$test_dir")
                done

                if [[ ! -w "$test_dir" ]]; then
                    warn "没有权限写入: $test_dir"
                    read -r -p "是否继续? [y/N]: " continue_anyway
                    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
                        continue
                    fi
                fi

                echo "$custom_dir"
                return 0
            done
            ;;
        *)
            error "无效的选择，使用默认目录"
            echo "$default_dir"
            ;;
    esac
}

# 解析manifest
parse_manifest() {
    local manifest_file="$1" version="$2" os="$3" arch="$4"

    debug "解析manifest: version=$version, os=$os, arch=$arch"

    # 初始化所有变量（避免 unbound variable）
    local target_version="" download_url="" filename="" sha256_hash=""

    # 解析版本
    if [[ "$version" == "latest" ]] || [[ "$version" == "latest_stable" ]]; then
        if have_cmd jq; then
            target_version=$(jq -r '.latest_stable // .latest.stable // empty' "$manifest_file")
        else
            target_version=$(grep -E '"latest_stable"' "$manifest_file" | head -n1 | sed -E 's/.*"latest_stable"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)
            [[ -z "$target_version" ]] && target_version=$(grep -E '"stable"' "$manifest_file" | head -n5 | sed -E 's/.*"stable"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -n1 || true)
        fi
    else
        target_version="$version"
    fi

    if [[ -z "$target_version" ]]; then
        error "无法解析版本: $version"
        exit 1
    fi

    # 构建文件信息
    local ext="tgz"
    [[ "$os" == "windows" ]] && ext="zip"
    filename="mynet_${os}_${arch}_${target_version}.${ext}"

    # 尝试从manifest获取精确信息
    if have_cmd jq; then
        local artifact_info
        artifact_info=$(jq -r --arg v "$target_version" --arg os "$os" --arg arch "$arch" \
            '.versions[$v].artifacts[]? | select(.os==$os and .arch==$arch) | "\(.url)|\(.sha256 // "")"' \
            "$manifest_file" 2>/dev/null | head -n1 || true)

        if [[ -n "$artifact_info" ]]; then
            IFS='|' read -r download_url sha256_hash <<< "$artifact_info"
        fi
    fi

    # 如果没有找到精确信息，使用默认URL
    if [[ -z "$download_url" ]]; then
        download_url="${CTL_BASE_URL}/mynet/${target_version}/${filename}"
        sha256_hash=""
    fi

    echo "${target_version}|${download_url}|${filename}|${sha256_hash}"
}

# 校验下载文件
verify_download() {
    local file="$1" expected_hash="$2" filename="$3"

    if [[ -z "$expected_hash" ]]; then
        warn "没有提供校验和，跳过文件校验"
        return 0
    fi

    log "校验下载文件..."

    local actual_hash
    if have_cmd sha256sum; then
        actual_hash=$(sha256sum "$file" | awk '{print $1}')
    elif have_cmd shasum; then
        actual_hash=$(shasum -a 256 "$file" | awk '{print $1}')
    elif have_cmd openssl; then
        actual_hash=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else
        warn "没有找到校验工具，跳过文件校验"
        return 0
    fi

    if [[ "$actual_hash" == "$expected_hash" ]]; then
        success "文件校验通过"
        return 0
    else
        error "文件校验失败!"
        error "期望: $expected_hash"
        error "实际: $actual_hash"
        exit 1
    fi
}

# 解压文件
extract_package() {
    local package_file="$1" extract_dir="$2"

    log "正在解压安装包..." >&2
    mkdir -p "$extract_dir"

    if [[ "$package_file" == *.zip ]]; then
        if ! have_cmd unzip; then
            error "需要 unzip 命令解压 ZIP 文件" >&2
            exit 1
        fi
        debug "使用 unzip 解压" >&2
        unzip -oq "$package_file" -d "$extract_dir"
    else
        debug "使用 tar 解压" >&2
        tar -xzf "$package_file" -C "$extract_dir"
    fi

    # 检查解压结果
    debug "解压后目录内容:" >&2
    if [[ "${MYNET_DEBUG:-}" == "1" ]]; then
        ls -la "$extract_dir" >&2 || true
    fi

    # 查找源目录 - 更健壮的检测逻辑
    local source_dir=""

    # 首先检查是否有 mynet 子目录
    if [[ -d "$extract_dir/mynet" ]]; then
        source_dir="$extract_dir/mynet"
        debug "找到嵌套目录: $source_dir" >&2
    else
        # 检查是否直接解压到了根目录
        if [[ -f "$extract_dir/bin/mynet" ]] || [[ -d "$extract_dir/bin" ]] || [[ -d "$extract_dir/scripts" ]]; then
            source_dir="$extract_dir"
            debug "直接解压到根目录: $source_dir" >&2
        else
            # 尝试找第一个包含 bin 目录的子目录
            local first_subdir
            first_subdir=$(find "$extract_dir" -maxdepth 1 -type d -name "*mynet*" | head -n1 || true)
            if [[ -n "$first_subdir" && -d "$first_subdir" ]]; then
                source_dir="$first_subdir"
                debug "找到匹配子目录: $source_dir" >&2
            else
                # 最后尝试找任何包含可执行文件的目录
                first_subdir=$(find "$extract_dir" -name "mynet" -type f -executable | head -n1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null || true)
                if [[ -n "$first_subdir" && -d "$first_subdir" ]]; then
                    source_dir="$first_subdir"
                    debug "通过可执行文件找到目录: $source_dir" >&2
                fi
            fi
        fi
    fi

    # 验证源目录
    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        error "无法找到有效的源目录" >&2
        error "解压后的目录结构：" >&2
        ls -la "$extract_dir" >&2 || true
        exit 1
    fi

    debug "最终源目录: $source_dir" >&2
    debug "源目录内容:" >&2
    if [[ "${MYNET_DEBUG:-}" == "1" ]]; then
        ls -la "$source_dir" >&2 || true
    fi

    echo "$source_dir"
}

# 安装文件
install_files() {
    local source_dir="$1" install_dir="$2"

    log "安装文件到 $install_dir ..."

    # 验证源目录
    if [[ ! -d "$source_dir" ]]; then
        error "源目录不存在: $source_dir"
        exit 1
    fi

    # 检查源目录是否有内容
    if [[ -z "$(ls -A "$source_dir" 2>/dev/null)" ]]; then
        error "源目录为空: $source_dir"
        exit 1
    fi

    # 创建安装目录
    mkdir -p "$install_dir"

    # 复制所有文件 - 使用更安全的方法
    debug "复制文件: $source_dir/ -> $install_dir/"

    # 使用 find 和 cp 确保所有文件都被复制
    if cd "$source_dir" 2>/dev/null; then
        # 复制所有文件和目录
        tar cf - . | (cd "$install_dir" && tar xf -)
        cd - >/dev/null
    else
        # 备用方法：直接复制
        cp -rf "$source_dir"/. "$install_dir/"
    fi

    # 验证复制结果
    if [[ -z "$(ls -A "$install_dir" 2>/dev/null)" ]]; then
        error "文件复制失败，安装目录为空"
        exit 1
    fi

    debug "安装目录内容:"
    if [[ "${MYNET_DEBUG:-}" == "1" ]]; then
        ls -la "$install_dir" || true
    fi

    # 设置权限
    if [[ -d "$install_dir/bin" ]]; then
        debug "设置 bin 目录权限"
        find "$install_dir/bin" -type f -exec chmod +x {} \; 2>/dev/null || true
    fi

    # 设置脚本权限
    if [[ -d "$install_dir/scripts" ]]; then
        debug "设置 scripts 目录权限"
        find "$install_dir/scripts" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
    fi
}

# 创建系统链接
create_system_links() {
    local install_dir="$1" os="$2"

    local mynet_bin="$install_dir/bin/mynet"
    if [[ ! -x "$mynet_bin" ]]; then
        warn "可执行文件不存在或不可执行: $mynet_bin"
        return 1
    fi

    # 尝试创建系统级链接
    if ln -sf "$mynet_bin" /usr/local/bin/mynet 2>/dev/null; then
        success "已创建系统链接: /usr/local/bin/mynet"
        return 0
    fi

    # 尝试创建用户级链接
    if mkdir -p "$HOME/.local/bin" 2>/dev/null && ln -sf "$mynet_bin" "$HOME/.local/bin/mynet" 2>/dev/null; then
        success "已创建用户链接: $HOME/.local/bin/mynet"
        warn "请确保 $HOME/.local/bin 在您的 PATH 中"
        return 0
    fi

    warn "无法创建系统链接，请手动添加到 PATH: $mynet_bin"
    return 1
}

# 平台特殊处理
handle_platform_specific() {
    local install_dir="$1" os="$2"

    case "$os" in
        darwin)
            log "处理 macOS 特定配置..."

            # 移除 quarantine 属性（防止 Gatekeeper 阻止）
            if have_cmd xattr; then
                debug "检查并移除 quarantine 属性"

                # 检查主程序
                if [[ -f "$install_dir/bin/mynet" ]]; then
                    local attrs
                    attrs=$(xattr "$install_dir/bin/mynet" 2>/dev/null || true)

                    if echo "$attrs" | grep -q "com.apple.quarantine"; then
                        log "移除主程序的 quarantine 属性..."
                        xattr -d com.apple.quarantine "$install_dir/bin/mynet" 2>/dev/null || true
                        success "已移除 quarantine 属性"
                    else
                        debug "主程序没有 quarantine 属性"
                    fi
                fi

                # 移除整个目录的 quarantine 属性（递归）
                debug "递归移除所有文件的 quarantine 属性"
                xattr -dr com.apple.quarantine "$install_dir" 2>/dev/null || true
            else
                warn "未找到 xattr 命令，无法移除 quarantine 属性"
                warn "如果遇到 \"无法验证开发者\" 错误，请手动运行:"
                warn "  sudo xattr -dr com.apple.quarantine $install_dir"
            fi

            # 验证 Gatekeeper 状态
            if have_cmd spctl; then
                debug "检查 Gatekeeper 状态"
                local gk_status
                gk_status=$(spctl --status 2>/dev/null || echo "unknown")
                debug "Gatekeeper: $gk_status"

                if [[ "$gk_status" == *"enabled"* ]]; then
                    log "检测到 Gatekeeper 已启用"
                    log "如果遇到运行问题，可以尝试："
                    log "  1. 右键点击应用 → 打开"
                    log "  2. 或运行: sudo spctl --master-disable"
                fi
            fi

            # 设置正确的权限
            debug "设置 macOS 权限"
            chmod +x "$install_dir/bin/mynet" 2>/dev/null || true
            chmod +x "$install_dir/bin/mynetd" 2>/dev/null || true
            chmod +x "$install_dir/bin/mynet-updater" 2>/dev/null || true

            # 检查是否需要代码签名（仅提示）
            if have_cmd codesign; then
                local sign_status
                sign_status=$(codesign -dv "$install_dir/bin/mynet" 2>&1 || echo "unsigned")

                if echo "$sign_status" | grep -q "not signed"; then
                    debug "程序未签名，可能需要在安全设置中允许运行"
                else
                    debug "代码签名状态: $(echo "$sign_status" | head -n1)"
                fi
            fi
            ;;

        openwrt)
            # OpenWrt: 设置适当的文件权限
            log "设置 OpenWrt 权限..."
            chmod -R 755 "$install_dir" 2>/dev/null || true

            # 确保脚本可执行
            if [[ -d "$install_dir/scripts" ]]; then
                find "$install_dir/scripts" -name "*.sh" -type f -exec chmod +x {} \; 2>/dev/null || true
            fi
            ;;

        linux)
            # Linux: 设置标准权限
            debug "设置 Linux 权限"
            chmod 755 "$install_dir/bin/mynet" 2>/dev/null || true
            chmod 755 "$install_dir/bin/mynetd" 2>/dev/null || true
            chmod 755 "$install_dir/bin/mynet-updater" 2>/dev/null || true

            # 检查 SELinux
            if have_cmd getenforce && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
                warn "检测到 SELinux 启用，如果遇到权限问题，请运行:"
                warn "  sudo chcon -t bin_t $install_dir/bin/mynet"
            fi
            ;;
    esac
}

# 验证安装
verify_installation() {
    local install_dir="$1"

    log "验证安装..."

    local mynet_bin="$install_dir/bin/mynet"
    if [[ ! -x "$mynet_bin" ]]; then
        error "主程序不可执行: $mynet_bin"
        return 1
    fi

    # 尝试运行版本命令
    if "$mynet_bin" --version >/dev/null 2>&1; then
        local version_output
        version_output=$("$mynet_bin" --version 2>/dev/null | head -n1 || echo "unknown")
        success "安装验证成功: $version_output"
        return 0
    else
        warn "无法获取版本信息，安装可能有问题"
        return 1
    fi
}

# 显示帮助
show_help() {
    cat << 'EOF'
MyNet 高级安装脚本

环境变量:
  ./      - 指定版本 (默认: latest_stable)
  MYNET_INSTALL_DIR  - 安装目录 (默认: 根据系统自动选择)
  MYNET_MANIFEST_URL - Manifest URL (默认: 官方地址)
  MYNET_AUTO_YES     - 自动确认安装 (1=是, 0=否)
  MYNET_DEBUG        - 调试模式 (1=开启, 0=关闭)

使用示例:
  # 基本安装
  curl -fsSL https://example.com/install-advanced.sh | bash

  # 指定版本
  curl -fsSL https://example.com/install-advanced.sh | MYNET_VERSION=v1.0.0 bash

  # 自定义目录
  curl -fsSL https://example.com/install-advanced.sh | MYNET_INSTALL_DIR=/custom/path bash

  # 静默安装
  curl -fsSL https://example.com/install-advanced.sh | MYNET_AUTO_YES=1 bash

  # 调试模式
  curl -fsSL https://example.com/install-advanced.sh | MYNET_DEBUG=1 bash

EOF
}

# 主函数
main() {
    # 第一步：检查脚本更新（可选，失败不影响安装）
    check_script_update "$@"

    # 检查是否显示帮助
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        show_help
        exit 0
    fi

    # 检查权限
    if [[ "$(id -u)" -ne 0 ]]; then
        error "需要 root 权限运行安装脚本"
        error "请使用: sudo bash 或切换到 root 用户"
        exit 1
    fi

    # 显示标题
    echo -e "${CYAN}"
    echo "=================================="
    echo "     MyNet 高级安装脚本"
    echo "=================================="
    echo -e "${NC}"

    # 创建临时目录
    mkdir -p "$TMP_DIR"
    debug "临时目录: $TMP_DIR"

    # 检测系统
    local system_info os arch
    system_info=$(detect_system)
    IFS='|' read -r os arch <<< "$system_info"

    log "检测到系统: $os $arch"

    # 确保 jq 工具可用（Linux 系统自动安装）
    ensure_jq "$os" "$arch" || warn "jq 工具不可用，将使用备用方案解析 JSON"

    # 下载并解析manifest（提前下载以支持交互式版本选择）
    local manifest_file="$TMP_DIR/manifest.json"
    log "获取版本清单..."
    fetch "$MANIFEST_URL" "$manifest_file" "版本清单"

    if [[ ! -s "$manifest_file" ]]; then
        error "版本清单下载失败或为空"
        exit 1
    fi

    # 获取安装参数（支持交互式选择）
    local version install_dir

    # 版本选择
    if [[ -n "${MYNET_VERSION:-}" ]]; then
        # 环境变量指定版本（非交互模式）
        version="$MYNET_VERSION"
        log "使用指定版本: $version"
    elif [[ "${MYNET_AUTO_YES:-}" == "1" ]]; then
        # 自动模式，使用最新稳定版
        version="latest_stable"
        log "自动模式，使用最新稳定版"
    else
        # 交互式选择版本（不显示日志，函数内部会显示界面）
        version=$(select_version_interactive "$manifest_file" "$os" "$arch")
    fi

    # 安装目录选择
    local install_dir_default
    install_dir_default=$(get_default_install_dir "$os")

    if [[ -n "${MYNET_INSTALL_DIR:-}" ]]; then
        # 环境变量指定目录（非交互模式）
        install_dir="$MYNET_INSTALL_DIR"
        log "使用指定目录: $install_dir"
    elif [[ "${MYNET_AUTO_YES:-}" == "1" ]]; then
        # 自动模式，使用默认目录
        install_dir="$install_dir_default"
        log "自动模式，使用默认目录: $install_dir"
    else
        # 交互式选择目录（不显示日志，函数内部会显示界面）
        install_dir=$(select_install_dir_interactive "$install_dir_default" "$os")
    fi

    # 解析下载信息
    local download_info target_version download_url filename sha256_hash
    download_info=$(parse_manifest "$manifest_file" "$version" "$os" "$arch")
    IFS='|' read -r target_version download_url filename sha256_hash <<< "$download_info"

    # 显示安装信息摘要
    echo
    log "准备安装 MyNet $target_version"
    log "安装目录: $install_dir"
    debug "下载地址: $download_url"
    debug "文件名: $filename"
    debug "校验和: ${sha256_hash:-无}"

    # 用户确认
    if [[ "${MYNET_AUTO_YES:-}" != "1" ]]; then
        echo
        echo -e "${YELLOW}即将安装 MyNet $target_version 到 $install_dir${NC}"
        echo -e "${YELLOW}下载地址: $download_url${NC}"
        echo
        read -r -p "是否继续? [Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log "用户取消安装"
            exit 0
        fi
        echo
    fi

    # 下载安装包
    local package_file="$TMP_DIR/$filename"
    log "正在下载 MyNet $target_version ..."
    fetch "$download_url" "$package_file" "安装包"

    if [[ ! -s "$package_file" ]]; then
        error "安装包下载失败"
        exit 1
    fi

    local file_size
    file_size=$(du -h "$package_file" | cut -f1)
    success "下载完成，大小: $file_size"

    # 校验文件
    verify_download "$package_file" "$sha256_hash" "$filename"

    # 解压安装包
    local extract_dir="$TMP_DIR/extract"
    local source_dir
    source_dir=$(extract_package "$package_file" "$extract_dir")

    # 安装文件
    install_files "$source_dir" "$install_dir"

    # 平台特殊处理
    handle_platform_specific "$install_dir" "$os"

    # 创建系统链接
    create_system_links "$install_dir" "$os"

    # 验证安装
    verify_installation "$install_dir"

    # 显示安装结果
    echo
    echo -e "${GREEN}=================================="
    echo "     MyNet 安装完成！"
    echo "==================================${NC}"
    echo
    echo "安装信息:"
    echo "  版本: $target_version"
    echo "  安装目录: $install_dir"
    echo "  可执行文件: $install_dir/bin/mynet"
    echo
    echo "快速开始:"
    echo "  mynet --help         # 查看帮助"
    echo "  mynet --version      # 查看版本"
    echo "  mynet                # 启动 TUI 界面"
    echo

    success "安装完成！"
}

# 执行主函数
main "$@"
