#!/bin/bash
# YouTube 访问性能测试脚本
# 用于诊断和监控 YouTube 访问质量

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置
SNI_PROXY="192.168.88.253"
TEST_DOMAIN="www.youtube.com"
TIMEOUT=10

echo "========================================="
echo "  YouTube 访问性能测试"
echo "========================================="
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "客户端: $(hostname) ($(ipconfig getifaddr en0 2>/dev/null || echo 'unknown'))"
echo ""

# 1. DNS 解析测试
echo -e "${YELLOW}[1/5] DNS 解析测试${NC}"
echo "---"
DNS_START=$(date +%s%N)
DNS_RESULT=$(nslookup $TEST_DOMAIN 2>&1)
DNS_END=$(date +%s%N)
DNS_TIME=$(( ($DNS_END - $DNS_START) / 1000000 ))

if echo "$DNS_RESULT" | grep -q "Address: $SNI_PROXY"; then
    echo -e "${GREEN}✓${NC} DNS 解析正确: $TEST_DOMAIN → $SNI_PROXY"
    echo "  耗时: ${DNS_TIME}ms"
else
    echo -e "${RED}✗${NC} DNS 解析异常"
    echo "$DNS_RESULT"
fi
echo ""

# 2. 网络延迟测试
echo -e "${YELLOW}[2/5] 网络延迟测试${NC}"
echo "---"
PING_RESULT=$(ping -c 5 $SNI_PROXY 2>&1 || echo "FAILED")

if echo "$PING_RESULT" | grep -q "packets transmitted"; then
    AVG_PING=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}')
    PACKET_LOSS=$(echo "$PING_RESULT" | grep "packet loss" | awk '{print $7}')

    if [ "${PACKET_LOSS%\%}" -lt 10 ]; then
        echo -e "${GREEN}✓${NC} 延迟: ${AVG_PING}ms, 丢包率: ${PACKET_LOSS}"
    else
        echo -e "${YELLOW}⚠${NC} 延迟: ${AVG_PING}ms, 丢包率: ${PACKET_LOSS} (偏高)"
    fi
else
    echo -e "${RED}✗${NC} Ping 失败"
fi
echo ""

# 3. 路由追踪
echo -e "${YELLOW}[3/5] 路由追踪${NC}"
echo "---"
traceroute -m 5 -q 1 $SNI_PROXY 2>&1 | head -6
echo ""

# 4. HTTPS 连接测试
echo -e "${YELLOW}[4/5] HTTPS 连接测试${NC}"
echo "---"
CURL_START=$(date +%s%N)
CURL_RESULT=$(curl --tlsv1.2 -I -m $TIMEOUT https://$TEST_DOMAIN 2>&1 || echo "FAILED")
CURL_END=$(date +%s%N)
CURL_TIME=$(( ($CURL_END - $CURL_START) / 1000000 ))

if echo "$CURL_RESULT" | grep -q "HTTP/2 200"; then
    echo -e "${GREEN}✓${NC} HTTPS 连接成功 (HTTP/2)"
    echo "  耗时: ${CURL_TIME}ms"

    # 提取 SSL 信息
    if echo "$CURL_RESULT" | grep -q "SSL connection"; then
        TLS_VERSION=$(echo "$CURL_RESULT" | grep "SSL connection" | awk '{print $4}')
        echo "  TLS 版本: $TLS_VERSION"
    fi
else
    echo -e "${RED}✗${NC} HTTPS 连接失败"
    echo "$CURL_RESULT" | head -10
fi
echo ""

# 5. 下载速度测试
echo -e "${YELLOW}[5/5] 下载速度测试${NC}"
echo "---"
echo "下载 YouTube 首页 (限时 ${TIMEOUT}秒)..."

SPEED_RESULT=$(curl --tlsv1.2 -o /dev/null -s -w "Downloaded: %{size_download} bytes\nSpeed: %{speed_download} bytes/sec\nTime: %{time_total}s\n" -m $TIMEOUT https://$TEST_DOMAIN 2>&1 || echo "FAILED")

if echo "$SPEED_RESULT" | grep -q "Downloaded"; then
    BYTES=$(echo "$SPEED_RESULT" | grep "Downloaded" | awk '{print $2}')
    SPEED=$(echo "$SPEED_RESULT" | grep "Speed" | awk '{print $2}')
    TIME=$(echo "$SPEED_RESULT" | grep "Time" | awk '{print $2}')

    # 转换为 KB
    KB=$((BYTES / 1024))
    SPEED_KB=$(echo "scale=2; $SPEED / 1024" | bc)

    if [ "$KB" -gt 100 ]; then
        echo -e "${GREEN}✓${NC} 下载成功"
        echo "  大小: ${KB} KB"
        echo "  速度: ${SPEED_KB} KB/s"
        echo "  耗时: ${TIME}s"
    else
        echo -e "${YELLOW}⚠${NC} 下载不完整"
        echo "  大小: ${KB} KB (可能不完整)"
    fi
else
    echo -e "${RED}✗${NC} 下载失败"
    echo "$SPEED_RESULT"
fi
echo ""

# 总结
echo "========================================="
echo "  测试总结"
echo "========================================="
echo ""

# 生成建议
echo "📊 诊断建议:"
echo ""

if echo "$DNS_RESULT" | grep -q "Address: $SNI_PROXY"; then
    echo -e "${GREEN}✓${NC} DNS 配置正确"
else
    echo -e "${RED}✗${NC} 检查 SmartDNS 配置"
fi

if echo "$PING_RESULT" | grep -q "packets transmitted"; then
    AVG_PING_NUM=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | sed 's/ms//')
    if [ "$(echo "$AVG_PING_NUM > 200" | bc)" -eq 1 ]; then
        echo -e "${YELLOW}⚠${NC} 延迟偏高 (${AVG_PING_NUM}ms) - 考虑优化 VPN 路由"
    else
        echo -e "${GREEN}✓${NC} 延迟正常 (${AVG_PING_NUM}ms)"
    fi
fi

if echo "$CURL_RESULT" | grep -q "HTTP/2 200"; then
    echo -e "${GREEN}✓${NC} HTTPS 连接正常"
else
    echo -e "${RED}✗${NC} 检查 SNI Proxy 配置和日志"
fi

echo ""
echo "详细方案请查阅: docs/YOUTUBE_ACCESS_SOLUTION.md"
echo ""
