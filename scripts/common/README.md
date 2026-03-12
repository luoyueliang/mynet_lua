# 架构列表使用指南

## 概述

`scripts/common/arch_list.txt` 是整个项目的架构定义唯一来源(Single Source of Truth)。

所有组件都应该基于这个文件,包括:
- `install.sh` - 安装脚本
- `updater.go` - GNB/WireGuard 下载器
- `arch.go` - 运行时架构检测
- `release_linux.sh` - 构建脚本

## 文件格式

```
canonical_name|alias1,alias2,alias3|description
```

- **canonical_name**: 规范名称(以 GNB 命名为准)
- **aliases**: 别名列表,逗号分隔
- **description**: 架构描述

### 示例

```
mipsel|mipsle,mips32le|MIPS 32-bit little-endian hard-float
```

表示:
- 规范名称: `mipsel` (GNB 使用的名称)
- 别名: `mipsle` (Go 使用), `mips32le`
- 描述: MIPS 32-bit little-endian hard-float

## Shell 解析示例

```bash
# 读取所有架构
while IFS='|' read -r canonical aliases desc; do
    [[ "$canonical" =~ ^#.*$ || -z "$canonical" ]] && continue
    echo "架构: $canonical"
    echo "别名: $aliases"
    echo "描述: $desc"
done < scripts/common/arch_list.txt

# 查找别名对应的规范名称
find_canonical() {
    local search="$1"
    while IFS='|' read -r canonical aliases desc; do
        [[ "$canonical" =~ ^#.*$ || -z "$canonical" ]] && continue

        # 匹配规范名称
        [[ "$canonical" == "$search" ]] && echo "$canonical" && return 0

        # 匹配别名
        if [[ -n "$aliases" ]]; then
            IFS=',' read -ra alias_array <<< "$aliases"
            for alias in "${alias_array[@]}"; do
                [[ "$alias" == "$search" ]] && echo "$canonical" && return 0
            done
        fi
    done < scripts/common/arch_list.txt
    return 1
}

# 使用示例
canonical=$(find_canonical "mipsle")  # 返回 "mipsel"
```

## Go 解析示例

```go
package platform

import (
    "bufio"
    "embed"
    "strings"
)

//go:embed arch_list.txt
var archListFS embed.FS

type ArchDefinition struct {
    Canonical   string
    Aliases     []string
    Description string
}

// 加载架构列表
func LoadArchList() (map[string]*ArchDefinition, error) {
    file, err := archListFS.Open("arch_list.txt")
    if err != nil {
        return nil, err
    }
    defer file.Close()

    archMap := make(map[string]*ArchDefinition)
    scanner := bufio.NewScanner(file)

    for scanner.Scan() {
        line := strings.TrimSpace(scanner.Text())

        // 跳过注释和空行
        if strings.HasPrefix(line, "#") || line == "" {
            continue
        }

        parts := strings.Split(line, "|")
        if len(parts) != 3 {
            continue
        }

        canonical := strings.TrimSpace(parts[0])
        aliasesStr := strings.TrimSpace(parts[1])
        description := strings.TrimSpace(parts[2])

        var aliases []string
        if aliasesStr != "" {
            for _, alias := range strings.Split(aliasesStr, ",") {
                aliases = append(aliases, strings.TrimSpace(alias))
            }
        }

        def := &ArchDefinition{
            Canonical:   canonical,
            Aliases:     aliases,
            Description: description,
        }

        // 规范名称映射
        archMap[canonical] = def

        // 别名映射
        for _, alias := range aliases {
            archMap[alias] = def
        }
    }

    return archMap, scanner.Err()
}

// 查找规范名称
func FindCanonical(arch string) string {
    archMap, err := LoadArchList()
    if err != nil {
        return ""
    }

    if def, ok := archMap[arch]; ok {
        return def.Canonical
    }
    return ""
}

// 获取所有别名
func GetAliases(arch string) []string {
    archMap, err := LoadArchList()
    if err != nil {
        return nil
    }

    if def, ok := archMap[arch]; ok {
        result := []string{def.Canonical}
        result = append(result, def.Aliases...)
        return result
    }
    return nil
}
```

## 各组件使用方式

### 1. install.sh

```bash
# 在 detect_system() 函数中
source "$(dirname "${BASH_SOURCE[0]}")/../common/arch_helper.sh"

# 检测架构后转换为规范名称
detected_arch="armv7"  # 从 FPU 检测得到
canonical_arch=$(find_canonical "$detected_arch")  # 返回 "armv7-hardfp"
```

### 2. updater.go

```go
// 在 SelectArtifactNew() 中
import "mynet/internal/common/platform"

func SelectArtifactNew(arch string, artifacts []Artifact) *Artifact {
    // 获取所有别名
    aliases := platform.GetAliases(arch)

    // 使用别名匹配
    for _, artifact := range artifacts {
        for _, alias := range aliases {
            if strings.Contains(artifact.Name, alias) {
                return &artifact
            }
        }
    }
    return nil
}
```

### 3. arch.go

```go
// 在 GetRuntimeArch() 返回前
func GetRuntimeArch() string {
    // ... 检测逻辑 ...

    // 转换为规范名称
    detected := "armv7"  // 从 runtime.GOARCH 得到
    canonical := platform.FindCanonical(detected)
    if canonical != "" {
        return canonical
    }
    return detected
}
```

## 维护规则

### 添加新架构

1. 在 `arch_list.txt` 添加新行
2. 确定规范名称(优先使用 GNB 的命名)
3. 添加所有已知别名(包括 Go 的 GOARCH)
4. 写清楚描述

示例:
```
loongarch64|loong64|LoongArch 64-bit
```

### 修改现有架构

1. **只修改 `arch_list.txt`**
2. 其他代码自动生效(通过解析这个文件)
3. 不要在代码中硬编码架构名称

### 测试

修改后测试所有组件:

```bash
# 1. 测试 install.sh
bash scripts/install/install.sh --dry-run

# 2. 测试 Go 代码
go test -v internal/common/platform/
go test -v internal/tools/updater/

# 3. 测试实际下载
DEBUG=1 ./mynet upgrade gnb
```

## 命名规则

### 规范名称选择

1. **优先**: GNB 使用的名称
2. **次选**: 行业标准名称
3. **最后**: Go 的 GOARCH

### 为什么不用 Go GOARCH?

因为我们主要下载 GNB,而 GNB 的命名与 Go 不完全一致:

| 架构 | Go GOARCH | GNB 命名 | 我们的选择 |
|------|-----------|----------|-----------|
| MIPS LE | `mipsle` | `mipsel` | `mipsel` (GNB) |
| ARM v7 HF | `arm` | `armv7-hardfp` | `armv7-hardfp` (GNB) |

## 常见问题

### Q: 为什么 mipsel 不是 mipsle?

**A**: GNB 使用传统的 `mipsel` (MIPS Endian Little),而 Go 使用 `mipsle`。我们以 GNB 为准,在别名中包含 `mipsle` 以兼容 Go。

### Q: 为什么 ARM 使用连字符格式?

**A**: GNB 使用 `armv7-hardfp` 和 `armv7-softfp` 明确区分 hard/soft float,我们遵循这个命名。历史格式(armv7, armv7sf)作为别名保留。

### Q: 如何验证架构映射是否正确?

**A**:
1. 查看 GNB 实际文件名
2. 确保规范名称能匹配这些文件
3. 测试下载功能

```bash
# 查看 GNB 文件
ls ~/.mynet/downloads/gnb_*

# 测试下载
DEBUG=1 ./mynet upgrade gnb
```

## 相关文档

- [docs/TECHNICAL_IMPLEMENTATION_STANDARDS.md](../../docs/TECHNICAL_IMPLEMENTATION_STANDARDS.md) - 架构与实现规范
- [docs/QUICK_REFERENCE.md](../../docs/QUICK_REFERENCE.md) - 快速参考
