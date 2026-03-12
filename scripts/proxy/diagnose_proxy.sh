#!/bin/bash
# 诊断 proxy.sh 运行问题
# 在 192.168.8.1 上运行

set +e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo "========================================="
echo "  proxy.sh 诊断工具"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================="
echo ""

# ============================================
# 1. 检查 MYNET_HOME 环境变量
# ============================================
echo "【1】MYNET_HOME 环境变量"
echo "-------------------------------------"

if [ -n "$MYNET_HOME" ]; then
    log_success "MYNET_HOME 已设置: $MYNET_HOME"
else
    log_error "MYNET_HOME 未设置"
fi

# 常见安装路径
POSSIBLE_HOMES=(
    "/etc/mynet"
    "/opt/mynet"
    "/usr/local/mynet"
    "$HOME/mynet"
)

echo ""
log_info "检查常见 mynet 安装路径:"
for path in "${POSSIBLE_HOMES[@]}"; do
    if [ -d "$path" ] && [ -f "$path/conf/mynet.conf" ]; then
        log_success "  找到: $path"
        DETECTED_HOME="$path"
    else
        echo "  ❌ 不存在: $path"
    fi
done

if [ -z "$MYNET_HOME" ] && [ -n "$DETECTED_HOME" ]; then
    log_warn "建议设置: export MYNET_HOME=$DETECTED_HOME"
    MYNET_HOME="$DETECTED_HOME"
fi

echo ""

# ============================================
# 2. 检查 proxy.sh 脚本
# ============================================
echo "【2】proxy.sh 脚本检查"
echo "-------------------------------------"

PROXY_SCRIPT_PATHS=(
    "$MYNET_HOME/scripts/proxy.sh"
    "/etc/mynet/scripts/proxy.sh"
    "$PWD/proxy.sh"
)

PROXY_SCRIPT=""
for path in "${PROXY_SCRIPT_PATHS[@]}"; do
    if [ -f "$path" ]; then
        log_success "找到 proxy.sh: $path"
        PROXY_SCRIPT="$path"

        if [ -x "$path" ]; then
            log_success "  可执行: 是"
        else
            log_error "  可执行: 否"
            log_info "  修复: chmod +x $path"
        fi
        break
    fi
done

if [ -z "$PROXY_SCRIPT" ]; then
    log_error "未找到 proxy.sh 脚本"
fi

echo ""

# ============================================
# 3. 检查 mynet_proxy 二进制
# ============================================
echo "【3】mynet_proxy 二进制检查"
echo "-------------------------------------"

MYNET_PROXY_PATHS=(
    "$MYNET_HOME/bin/mynet_proxy"
    "/usr/local/bin/mynet_proxy"
    "/usr/bin/mynet_proxy"
)

MYNET_PROXY_BIN=""
for path in "${MYNET_PROXY_PATHS[@]}"; do
    if [ -f "$path" ]; then
        log_success "找到 mynet_proxy: $path"
        MYNET_PROXY_BIN="$path"

        if [ -x "$path" ]; then
            log_success "  可执行: 是"
        else
            log_error "  可执行: 否"
        fi

        # 检查版本
        if [ -x "$path" ]; then
            log_info "  版本信息:"
            MYNET_HOME="$MYNET_HOME" "$path" --version 2>&1 | sed 's/^/    /' || log_warn "    无法获取版本"
        fi
        break
    fi
done

if [ -z "$MYNET_PROXY_BIN" ]; then
    log_error "未找到 mynet_proxy 二进制"
fi

echo ""

# ============================================
# 4. 检查 proxy 配置文件
# ============================================
echo "【4】proxy 配置文件"
echo "-------------------------------------"

if [ -n "$MYNET_HOME" ]; then
    PROXY_CONF_DIR="$MYNET_HOME/conf/proxy"

    log_info "配置目录: $PROXY_CONF_DIR"

    if [ -d "$PROXY_CONF_DIR" ]; then
        log_success "配置目录存在"

        # 检查关键配置文件
        FILES=(
            "proxy_peers.conf"
            "proxy_role.conf"
            "proxy_ips.txt"
            "proxy_route.conf"
        )

        for file in "${FILES[@]}"; do
            filepath="$PROXY_CONF_DIR/$file"
            if [ -f "$filepath" ]; then
                size=$(wc -l < "$filepath" 2>/dev/null || echo "0")
                log_success "  ✓ $file ($size 行)"
            else
                log_warn "  ✗ $file (不存在)"
            fi
        done
    else
        log_error "配置目录不存在"
    fi
else
    log_warn "MYNET_HOME 未设置，跳过配置检查"
fi

echo ""

# ============================================
# 5. 测试 proxy.sh status
# ============================================
echo "【5】测试 proxy.sh status"
echo "-------------------------------------"

if [ -n "$PROXY_SCRIPT" ] && [ -n "$MYNET_HOME" ]; then
    log_info "执行: MYNET_HOME=$MYNET_HOME $PROXY_SCRIPT status"
    echo ""
    echo "--- 输出开始 ---"

    if MYNET_HOME="$MYNET_HOME" "$PROXY_SCRIPT" status 2>&1; then
        STATUS_OK=true
    else
        STATUS_OK=false
    fi

    echo "--- 输出结束 ---"
    echo ""

    if [ "$STATUS_OK" = true ]; then
        log_success "proxy.sh status 执行成功"
    else
        log_error "proxy.sh status 执行失败"
        log_info "错误码: $?"
    fi
else
    log_warn "缺少 proxy.sh 或 MYNET_HOME，跳过测试"
fi

echo ""

# ============================================
# 6. 测试 mynet_proxy status
# ============================================
echo "【6】测试 mynet_proxy status (直接调用)"
echo "-------------------------------------"

if [ -n "$MYNET_PROXY_BIN" ] && [ -n "$MYNET_HOME" ]; then
    log_info "执行: MYNET_HOME=$MYNET_HOME $MYNET_PROXY_BIN status"
    echo ""
    echo "--- 输出开始 ---"

    if MYNET_HOME="$MYNET_HOME" "$MYNET_PROXY_BIN" status 2>&1; then
        STATUS_OK=true
    else
        STATUS_OK=false
    fi

    echo "--- 输出结束 ---"
    echo ""

    if [ "$STATUS_OK" = true ]; then
        log_success "mynet_proxy status 执行成功"
    else
        log_error "mynet_proxy status 执行失败"
        log_info "错误码: $?"
    fi
else
    log_warn "缺少 mynet_proxy 或 MYNET_HOME，跳过测试"
fi

echo ""

# ============================================
# 总结和建议
# ============================================
echo "========================================="
echo "  诊断总结"
echo "========================================="
echo ""

if [ -z "$MYNET_HOME" ]; then
    log_error "问题 1: MYNET_HOME 未设置"
    if [ -n "$DETECTED_HOME" ]; then
        echo "  修复: export MYNET_HOME=$DETECTED_HOME"
    else
        echo "  修复: 手动设置 MYNET_HOME 到 mynet 安装目录"
    fi
    echo ""
fi

if [ -z "$MYNET_PROXY_BIN" ]; then
    log_error "问题 2: mynet_proxy 二进制未找到"
    echo "  可能原因:"
    echo "    - mynet_proxy 未安装"
    echo "    - 安装路径不在标准位置"
    echo "  修复: 检查 mynet 安装是否完整"
    echo ""
fi

if [ ! -d "$MYNET_HOME/conf/proxy" ]; then
    log_error "问题 3: proxy 配置目录不存在"
    echo "  可能原因:"
    echo "    - proxy 插件未初始化"
    echo "    - MYNET_HOME 路径错误"
    echo "  修复: 运行 mynet_proxy setup 初始化配置"
    echo ""
fi

echo "快速修复命令 (在 shell 中执行):"
echo ""
if [ -n "$DETECTED_HOME" ]; then
    echo "  # 设置环境变量"
    echo "  export MYNET_HOME=$DETECTED_HOME"
    echo ""
fi
echo "  # 测试 proxy.sh"
echo "  $PROXY_SCRIPT status"
echo ""
echo "  # 或者直接调用"
echo "  MYNET_HOME=$MYNET_HOME $MYNET_PROXY_BIN status"
echo ""
