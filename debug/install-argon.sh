#!/usr/bin/env bash
# install-argon.sh — 在 QEMU OpenWrt VM 中安装 Argon 三件套
#
# 该脚本在 Mac 上运行，通过以下步骤安装：
#   1. 从 codeload.github.com 下载源码 tarball（国内可访问）
#   2. 用 Python 构建并通过 SSH tar 管道直接安装到 VM
#
# 用法:
#   bash debug/install-argon.sh
#
# 依赖: ssh, python3
# VM 需提前启动: bash debug/start.sh

set -euo pipefail

ROUTER="root@127.0.0.1"
PORT=2222
SSH="ssh -p $PORT -o StrictHostKeyChecking=no $ROUTER"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

THEME_TAG="v2.3.1"
CONFIG_TAG="v0.9"

echo "=== Argon 三件套安装脚本 ==="
echo "Build dir: $BUILD_DIR"

# ------  确认 VM 可达  ------
echo ""
echo "[检查] 连接 VM..."
$SSH "echo VM_OK" > /dev/null || { echo "ERROR: 无法连接到 VM，请先运行 bash debug/start.sh"; exit 1; }
echo "  VM 连接正常"

# ------  下载源码 tarball  ------
echo ""
echo "[下载] luci-theme-argon $THEME_TAG ..."
curl -s -L "https://codeload.github.com/jerrykuku/luci-theme-argon/tar.gz/refs/tags/$THEME_TAG" \
  | tar -xz -C "$BUILD_DIR"
echo "  OK"

echo "[下载] luci-app-argon-config $CONFIG_TAG ..."
curl -s -L "https://codeload.github.com/jerrykuku/luci-app-argon-config/tar.gz/refs/tags/$CONFIG_TAG" \
  | tar -xz -C "$BUILD_DIR"
echo "  OK"

THEME_DIR="$BUILD_DIR/luci-theme-argon-${THEME_TAG#v}"
CONFIG_DIR="$BUILD_DIR/luci-app-argon-config-${CONFIG_TAG#v}"

# ------  通过 Python 构建 tar.gz 并 SSH 管道安装  ------
python3 - "$THEME_DIR" "$CONFIG_DIR" "$PORT" "$ROUTER" << 'PYEOF'
import tarfile, gzip, io, os, subprocess, sys

THEME_DIR = sys.argv[1]
CONFIG_DIR = sys.argv[2]
PORT      = sys.argv[3]
ROUTER    = sys.argv[4]
SSH       = ['ssh', '-p', PORT, '-o', 'StrictHostKeyChecking=no', ROUTER]

def make_tar_gz(base_dir, file_map):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w:', format=tarfile.USTAR_FORMAT) as tar:
            for src_rel, dst in file_map:
                src_full = os.path.join(base_dir, src_rel)
                if os.path.isdir(src_full):
                    for root, dirs, files in os.walk(src_full):
                        dirs.sort()
                        for fname in sorted(files):
                            fpath = os.path.join(root, fname)
                            arcname = dst + fpath[len(src_full):]
                            ti = tar.gettarinfo(fpath, arcname=arcname)
                            ti.uid = ti.gid = 0; ti.uname = ti.gname = 'root'
                            with open(fpath, 'rb') as fp:
                                tar.addfile(ti, fp)
                elif os.path.isfile(src_full):
                    ti = tar.gettarinfo(src_full, arcname=dst)
                    ti.uid = ti.gid = 0; ti.uname = ti.gname = 'root'
                    if 'uci-defaults' in dst or 'libexec' in dst:
                        ti.mode = 0o755
                    with open(src_full, 'rb') as fp:
                        tar.addfile(ti, fp)
    return buf.getvalue()

def ssh_cmd(cmd):
    r = subprocess.run(SSH + [cmd], capture_output=True)
    if r.returncode != 0:
        err = '\n'.join(l for l in r.stderr.decode().splitlines() if not l.startswith('** '))
        print(f'CMD FAIL: {cmd[:60]}\n{err}'); sys.exit(1)
    return r.stdout.decode()

def ssh_tar(data, dest='/'):
    r = subprocess.run(SSH + [f'tar -xzf - -C {dest}'], input=data, capture_output=True)
    if r.returncode != 0:
        err = '\n'.join(l for l in r.stderr.decode().splitlines() if not l.startswith('** '))
        print(f'TAR FAIL: {err}'); sys.exit(1)

print('\n[1/3] 安装 luci-theme-argon...')
ssh_cmd('mkdir -p /www/luci-static/argon /usr/lib/lua/luci/view/themes/argon '
        '/etc/uci-defaults /usr/libexec/argon')
ssh_tar(make_tar_gz(THEME_DIR, [
    ('htdocs/luci-static/argon',               'www/luci-static/argon'),
    ('htdocs/luci-static/resources/menu-argon.js', 'www/luci-static/resources/menu-argon.js'),
    ('luasrc/view/themes/argon',               'usr/lib/lua/luci/view/themes/argon'),
    ('root/etc/uci-defaults/30_luci-theme-argon', 'etc/uci-defaults/30_luci-theme-argon'),
    ('root/usr/libexec/argon',                 'usr/libexec/argon'),
]))
print('  OK')

print('[2/3] 安装 luci-app-argon-config...')
ssh_cmd('mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi '
        '/usr/lib/lua/luci/view/argon-config /etc/config /usr/share/rpcd/acl.d')
ssh_tar(make_tar_gz(CONFIG_DIR, [
    ('luasrc/controller/argon-config.lua',     'usr/lib/lua/luci/controller/argon-config.lua'),
    ('luasrc/model/cbi/argon-config.lua',      'usr/lib/lua/luci/model/cbi/argon-config.lua'),
    ('luasrc/view/argon-config',               'usr/lib/lua/luci/view/argon-config'),
    ('root/etc/config/argon',                  'etc/config/argon'),
    ('root/etc/uci-defaults/luci-argon-config','etc/uci-defaults/luci-argon-config'),
    ('root/usr/share/rpcd/acl.d/luci-app-argon-config.json',
     'usr/share/rpcd/acl.d/luci-app-argon-config.json'),
]))
print('  OK')

print('[3/3] 安装中文翻译...')
ssh_cmd('mkdir -p /usr/lib/lua/luci/i18n')
ssh_tar(make_tar_gz(CONFIG_DIR, [
    ('po/zh-cn/argon-config.po', 'usr/lib/lua/luci/i18n/argon-config.zh-cn.po'),
]))
print('  OK')

print('\n[激活] 设置默认主题...')
print(ssh_cmd('''
  uci set luci.main.mediaurlbase='/luci-static/argon'
  uci commit luci
  sh /etc/uci-defaults/30_luci-theme-argon 2>/dev/null || true
  sh /etc/uci-defaults/luci-argon-config 2>/dev/null || true
  rm -f /tmp/luci-indexcache* /tmp/luci-modulecache*
  /etc/init.d/rpcd restart 2>/dev/null || true
  echo "DONE"
''').strip())
PYEOF

echo ""
echo "=== 安装完成 ==="
echo "浏览器访问: http://localhost:8080"
