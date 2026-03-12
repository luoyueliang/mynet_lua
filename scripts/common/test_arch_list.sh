#!/usr/bin/env bash
# 测试 arch_list.txt 的解析

ARCH_LIST="$(dirname "$0")/arch_list.txt"

echo "=== 测试架构列表解析 ==="
echo

echo "1. 读取所有架构映射:"
printf "   %-10s | %-4s | %-16s | %-8s | %-5s\n" "uname -m" "FPU" "架构标识" "GOARCH" "GOARM"
echo "   -------------------------------------------------------"
while IFS='|' read -r uname_m fpu arch goarch goarm; do
    [[ "$uname_m" =~ ^#.*$ || -z "$uname_m" ]] && continue
    printf "   %-10s | %-4s | %-16s | %-8s | %-5s\n" "$uname_m" "$fpu" "$arch" "$goarch" "$goarm"
done < "$ARCH_LIST"
echo

echo "2. 根据系统信息查找架构:"
find_arch() {
    local uname_val="$1"
    local fpu_val="${2:-none}"
    
    while IFS='|' read -r uname_m fpu arch goarch goarm; do
        [[ "$uname_m" =~ ^#.*$ || -z "$uname_m" ]] && continue
        
        if [[ "$uname_m" == "$uname_val" && "$fpu" == "$fpu_val" ]]; then
            echo "$arch|$goarch|$goarm"
            return 0
        fi
    done < "$ARCH_LIST"
    return 1
}

test_cases=(
    "x86_64:none:x86_64 PC"
    "armv7l:hard:树莓派 3 (hard-float)"
    "armv7l:soft:旧嵌入式 (soft-float)"
    "mipsel:hard:MT7621 路由器"
    "mipsel:soft:AR9331 路由器"
    "aarch64:hard:树莓派 4"
)

for test_case in "${test_cases[@]}"; do
    IFS=':' read -r uname_val fpu_val desc <<< "$test_case"
    result=$(find_arch "$uname_val" "$fpu_val")
    if [[ -n "$result" ]]; then
        IFS='|' read -r arch goarch goarm <<< "$result"
        printf "   %-25s (%s, FPU: %s)\n" "$desc" "$uname_val" "$fpu_val"
        printf "     架构标识: %s\n" "$arch"
        if [[ -n "$goarm" ]]; then
            printf "     Go 构建:  GOOS=linux GOARCH=%s GOARM=%s\n" "$goarch" "$goarm"
        else
            printf "     Go 构建:  GOOS=linux GOARCH=%s\n" "$goarch"
        fi
        printf "     文件名示例:\n"
        printf "       MyNet:     mynet_linux_%s_v1.0.0.tgz\n" "$arch"
        printf "       GNB:       gnb_linux_%s_v1.6.0.a.tgz\n" "$arch"
        printf "       WireGuard: wireguard_linux_%s_v1.0.0.tgz\n" "$arch"
        printf "       jq:        jq_linux_%s_v1.6.tgz\n" "$arch"
        echo
    else
        printf "   %-25s -> NOT FOUND\n" "$desc"
    fi
done

echo "3. 当前系统架构检测:"
current_uname=$(uname -m)
current_fpu="none"

# FPU 检测 (仅 Linux)
if [[ -f /proc/cpuinfo ]]; then
    case "$current_uname" in
        armv7l|armv7|armv6l|armv6)
            if grep -qiE "Features.*(vfp|neon)" /proc/cpuinfo 2>/dev/null; then
                current_fpu="hard"
            else
                current_fpu="soft"
            fi
            ;;
        aarch64|arm64)
            if grep -qiE "Features.*(fp|asimd)" /proc/cpuinfo 2>/dev/null; then
                current_fpu="hard"
            else
                current_fpu="soft"
            fi
            ;;
        mipsel|mips)
            if grep -qiE "FPU.*:.*none|FPU.*:.*soft" /proc/cpuinfo 2>/dev/null; then
                current_fpu="soft"
            else
                current_fpu="hard"
            fi
            ;;
    esac
else
    # 非 Linux 系统,默认 hard-float
    case "$current_uname" in
        armv7l|armv7|armv6l|armv6|aarch64|arm64|mipsel|mips)
            current_fpu="hard"
            ;;
    esac
fi

result=$(find_arch "$current_uname" "$current_fpu")
if [[ -n "$result" ]]; then
    IFS='|' read -r arch goarch goarm <<< "$result"
    echo "   系统:     $(uname -s) $(uname -m)"
    echo "   FPU:      $current_fpu"
    echo "   架构标识: $arch"
    echo
    echo "   Go 构建命令:"
    if [[ -n "$goarm" ]]; then
        echo "     GOOS=linux GOARCH=$goarch GOARM=$goarm go build -o mynet_linux_${arch}"
    else
        echo "     GOOS=linux GOARCH=$goarch go build -o mynet_linux_${arch}"
    fi
    echo
    echo "   可下载的文件(统一使用架构标识 '$arch'):"
    echo "     mynet_linux_${arch}_v1.0.0.tgz"
    echo "     gnb_linux_${arch}_v1.6.0.a.tgz"
    echo "     wireguard_linux_${arch}_v1.0.0.tgz"
    echo "     jq_linux_${arch}_v1.6.tgz"
else
    echo "   系统: $(uname -s) $(uname -m) (FPU: $current_fpu)"
    echo "   未找到匹配的架构定义"
fi
echo

echo "=== 测试完成 ==="
