#!/bin/bash
# 在官方 vlc-debian-win64 容器内，只编译 Qt GUI 插件模块（libqt_plugin.dll）
# 复用官方预编译 contrib，不自编 Qt / contrib / 全量模块。
set -euo pipefail

VLC_VER="${VLC_VER:-3.0.24}"
CONTRIB_URL="${CONTRIB_URL:-https://artifacts.videolan.org/vlc-3.0/win64/vlc-contrib-x86_64-w64-mingw32-910cc9cada6080dd777fbafb2ebdd0c24f702c30.tar.zst}"
WORK="${WORK:-/build/work}"
SHORTARCH=win64
TRIPLET=x86_64-w64-mingw32
CONTRIB_PREFIX=$TRIPLET
SRC="$WORK/vlc-$VLC_VER"

mkdir -p "$WORK"

step() { echo; echo "===== [$(date -u +%H:%M:%S)] $* ====="; }

# ---------------------------------------------------------------- 1. 源码
step "1/6 获取 VLC 源码 $VLC_VER"
if [ -d "$SRC/extras/package/win32" ]; then
    echo "源码已存在，跳过"
else
    if git clone --depth 1 --branch "$VLC_VER" https://github.com/videolan/vlc.git "$SRC" 2>/dev/null; then
        echo "git clone 成功"
    else
        echo "git clone 失败，改用官方 tarball"
        curl -fL --retry 3 "https://download.videolan.org/pub/videolan/vlc/${VLC_VER}/vlc-${VLC_VER}.tar.xz" -o /tmp/vlc.tar.xz
        mkdir -p "$SRC"
        tar -xJf /tmp/vlc.tar.xz -C "$SRC" --strip-components=1
    fi
fi
cd "$SRC"

# ---------------------------------------------------------------- 2. 打补丁
step "2/6 应用增强补丁"
if [ -f /build/patch.diff ]; then
    git init -q . 2>/dev/null || true
    git add -A >/dev/null 2>&1 || true
    git -c user.email=ci@local -c user.name=ci commit -qm "upstream $VLC_VER" >/dev/null 2>&1 || true
    if git apply --3way --verbose /build/patch.diff; then
        echo "补丁应用成功"
    else
        echo "::error::补丁应用失败，需更新 patches/ 下的补丁"
        exit 2
    fi
else
    echo "未提供补丁，跳过"
fi

# ---------------------------------------------------------------- 3. 构建工具
step "3/6 准备 extras/tools"
cd "$SRC/extras/tools"
if [ -x ./configure ] || [ -f Makefile ]; then
    make -j"$(nproc)" >/dev/null 2>&1 || make -j"$(nproc)" || true
else
    ./bootstrap >/dev/null 2>&1 && make -j"$(nproc)" >/dev/null 2>&1 || true
fi
cd "$SRC"

# ---------------------------------------------------------------- 4. 预编译 contrib
step "4/6 部署官方预编译 contrib"
mkdir -p "contrib/$SHORTARCH"
cd "contrib/$SHORTARCH"

if [ -d "../$CONTRIB_PREFIX/lib/pkgconfig" ] || [ -d "../$CONTRIB_PREFIX/include" ]; then
    echo "contrib 已就位，跳过下载"
else
    if [ -f contrib-config.mak ] || [ -f config.mak ]; then
        echo "bootstrap 已执行"
    else
        ../bootstrap --host="$TRIPLET" --prefix="../$CONTRIB_PREFIX" --disable-debug
    fi
    if make prebuilt PREBUILT_URL="$CONTRIB_URL"; then
        echo "make prebuilt 成功"
    else
        echo "::warning::make prebuilt 失败，尝试手工解包"
        curl -fL --retry 3 "$CONTRIB_URL" -o /tmp/contrib.tar.zst
        rm -rf /tmp/cx && mkdir -p /tmp/cx
        tar -I zstd -xf /tmp/contrib.tar.zst -C /tmp/cx
        # 若内层仍是压缩包则再解一层
        INNER=$(find /tmp/cx -maxdepth 2 -type f \( -name '*.tar.zst' -o -name '*.tar.bz2' -o -name '*.tar.gz' \) 2>/dev/null | head -1 || true)
        if [ -n "$INNER" ]; then
            tar -xf "$INNER" -C /tmp/cx
        fi
        # 定位含 include/lib 的目录
        BASE=$(dirname "$(find /tmp/cx -maxdepth 3 -type d -name pkgconfig 2>/dev/null | head -1)")
        BASE=$(dirname "$BASE")
        echo "contrib 根目录: $BASE"
        rm -rf "../$CONTRIB_PREFIX"
        cp -a "$BASE" "../$CONTRIB_PREFIX"
    fi
fi
cd "$SRC"
export PATH="$SRC/contrib/$CONTRIB_PREFIX/bin:$PATH"

# ---------------------------------------------------------------- 5. 配置
step "5/6 configure（复用官方 configure.sh）"
rm -rf "build-gui" && mkdir -p "build-gui"
cd "build-gui"
../extras/package/win32/configure.sh \
    --host="$TRIPLET" \
    --with-contrib="../contrib/$CONTRIB_PREFIX" \
    2>&1 | tail -40
echo "configure 完成"

# ---------------------------------------------------------------- 6. 只编 GUI 模块
step "6/6 编译 libvlccore + Qt GUI 插件"
make -j"$(nproc)" -C src 2>&1 | tail -20
echo "libvlccore 编译完成"

# qt 模块依赖 po 生成的 .qm 翻译，先尝试构建 po
make -j"$(nproc)" -C po >/dev/null 2>&1 || echo "::warning::po 构建跳过"

make -j"$(nproc)" -C modules/gui/qt 2>&1 | tail -40

step "收集产物"
mkdir -p /build/out
FOUND=0
for f in modules/gui/qt/.libs/*.dll modules/gui/qt/*.dll; do
    [ -f "$f" ] || continue
    cp -v "$f" /build/out/ && FOUND=1
done
if [ "$FOUND" = "0" ]; then
    echo "::error::未找到编译产物 DLL"
    find . -name "*.dll" -newermt '-2 hours' 2>/dev/null | head -20
    exit 3
fi
ls -la /build/out/
echo "OK"
