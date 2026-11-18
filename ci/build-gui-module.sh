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
[ -f modules/gui/qt/main_interface.cpp ] || { echo "::error::源码目录不完整，缺少 modules/gui/qt/main_interface.cpp"; exit 5; }
echo "源码体积: $(du -sh "$SRC" | cut -f1)"
step "2/6 应用增强补丁"
if [ -f /build/patch.diff ]; then
    if git apply --reverse --check /build/patch.diff >/dev/null 2>&1; then
        echo "补丁已存在于缓存源码中，跳过应用（保持对象文件时间戳不变）"
    else
        git init -q . 2>/dev/null || true
        git add -A >/dev/null 2>&1 || true
        git -c user.email=ci@local -c user.name=ci commit -qm "upstream $VLC_VER" >/dev/null 2>&1 || true
        if git apply --3way --verbose /build/patch.diff; then
            echo "补丁应用成功"
        else
            echo "::warning::3way 应用失败，尝试重置源码后重新应用"
            git checkout -- . >/dev/null 2>&1 || true
            if git apply --verbose /build/patch.diff; then
                echo "重置后补丁应用成功"
            else
                echo "::error::补丁应用失败，需更新 patches/ 下的补丁"
                exit 2
            fi
        fi
    fi
else
    echo "未提供补丁，跳过"
fi

# ---------------------------------------------------------------- 3. 构建工具
step "3/6 检查 autotools"
cd "$SRC"
need_tools=0
for t in autoconf automake libtoolize pkg-config msgfmt; do
    if ! command -v "$t" > /dev/null 2>&1; then
        echo "缺失: $t"
        need_tools=1
    fi
done
echo "autoconf:  $(autoconf --version 2>/dev/null | head -1)"
echo "automake:  $(automake --version 2>/dev/null | head -1)"
echo "libtoolize:$(libtoolize --version 2>/dev/null | head -1)"

if [ "$need_tools" -eq 1 ]; then
    step "3b/6 回退编译 extras/tools"
    cd "$SRC/extras/tools"
    if [ ! -f Makefile ]; then
        echo "extras/tools 未配置，执行 bootstrap"
        ./bootstrap > /tmp/tools-boot.log 2>&1 || { echo "::error::extras/tools bootstrap 失败"; tail -30 /tmp/tools-boot.log; exit 9; }
    fi
    set +e
    make -j"$(nproc)" > /tmp/tools-make.log 2>&1
    TRC=$?
    set -e
    if [ $TRC -ne 0 ]; then
        echo "::error::extras/tools 编译失败 (rc=$TRC)"
        tail -40 /tmp/tools-make.log
        exit 9
    fi
    cd "$SRC"
    export PATH="$SRC/extras/tools/build/bin:$PATH"
fi

# ---------------------------------------------------------------- 4. 预编译 contrib
# 注意：官方镜像内没有 curl/wget，下载一律在 runner 侧完成，容器只负责使用。
step "4/6 部署官方预编译 contrib"
mkdir -p "contrib/$SHORTARCH"
cd "contrib/$SHORTARCH"

if [ -d "../$CONTRIB_PREFIX/lib/pkgconfig" ] || [ -d "../$CONTRIB_PREFIX/include" ]; then
    echo "contrib 已就位，跳过"
elif [ -d /build/work/contrib-extract ]; then
    CB=$(find /build/work/contrib-extract -maxdepth 3 -type d -name "$CONTRIB_PREFIX" 2>/dev/null | head -1 || true)
    if [ -z "$CB" ]; then
        if [ -d /build/work/contrib-extract/include ] || [ -d /build/work/contrib-extract/lib ]; then
            CB=/build/work/contrib-extract
        fi
    fi
    if [ -z "$CB" ]; then
        echo "::error::宿主解包的 contrib 结构无法识别"
        ls -la /build/work/contrib-extract | head -20
        exit 4
    fi
    echo "使用宿主 contrib: $CB"
    cp -aT "$CB" "../$CONTRIB_PREFIX"
else
    echo "::error::宿主未提供预编译 contrib（预期 /build/work/contrib-extract）"
    exit 4
fi
[ -d "../$CONTRIB_PREFIX/include" ] || { echo "::error::contrib 目录不完整"; exit 4; }
echo "contrib 文件数: $(find "../$CONTRIB_PREFIX" -type f | wc -l)"
cd "$SRC"
export PATH="$SRC/contrib/$CONTRIB_PREFIX/bin:$PATH"
# 关键：让 pkg-config 只认 contrib 里的 .pc，否则 faad/flac/theora 等全部判为缺失
export PKG_CONFIG_LIBDIR="$SRC/contrib/$CONTRIB_PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH="$SRC/contrib/$CONTRIB_PREFIX/lib/pkgconfig"
echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
ls "$PKG_CONFIG_LIBDIR" 2>/dev/null | wc -l

# Qt5 的 moc/rcc/uic 是宿主工具，configure 依赖它们在 PATH 里
QTBIN=""
for d in "$SRC/contrib/$CONTRIB_PREFIX/bin" "$SRC/contrib/$CONTRIB_PREFIX/lib/qt5/bin"; do
    [ -d "$d" ] && QTBIN="$d:$QTBIN"
done
QT_MOC=$(find "$SRC/contrib/$CONTRIB_PREFIX" -maxdepth 5 -type f \( -name 'moc' -o -name 'moc.exe' -o -name 'moc-qt5' \) 2>/dev/null | head -1 || true)
if [ -n "$QT_MOC" ]; then QTBIN="$(dirname "$QT_MOC"):$QTBIN"; fi
if [ -n "$QTBIN" ]; then export PATH="$QTBIN$PATH"; fi
echo "QTBIN=$QTBIN"
echo "--- contrib/bin 内容 ---"
ls "$SRC/contrib/$CONTRIB_PREFIX/bin" 2>/dev/null | head -30 || echo "(无 bin 目录)"
for t in moc rcc uic; do printf "%s: " "$t"; command -v "$t" || echo MISSING; done

# configure.sh 内部会重置 PATH，导致 AC_CHECK_PROGS 找不到宿主 Qt 工具，
# 直接以环境变量显式指定（autoconf 优先采用环境变量）
export MOC="$SRC/contrib/$CONTRIB_PREFIX/bin/moc"
export RCC="$SRC/contrib/$CONTRIB_PREFIX/bin/rcc"
export UIC="$SRC/contrib/$CONTRIB_PREFIX/bin/uic"
echo "MOC=$MOC RCC=$RCC UIC=$UIC"

# ---------------------------------------------------------------- 5. 配置
# configure.sh 内部按 $(dirname $0)/../../../configure 定位，必须在源码根目录执行
step "5/6 configure（复用官方 configure.sh）"
cd "$SRC"
if [ -f config.mak ] && [ -f Makefile ] && [ -f modules/Makefile ]; then
    echo "configure 产物已在缓存中，跳过重跑（避免刷新 config.mak 触发全量重编）"
    grep -E "^(CFLAGS|CXXFLAGS)=" config.mak | head -2 || true
else
    if [ ! -x ./configure ]; then
        echo "源码根缺少 configure（git 仓库不自带），执行 bootstrap 生成"
        set +e
        ./bootstrap > /tmp/boot.log 2>&1
        BRC=$?
        set -e
        tail -25 /tmp/boot.log
        if [ $BRC -ne 0 ] || [ ! -x ./configure ]; then
            echo "::error::源码 bootstrap 失败 (rc=$BRC)"
            exit 6
        fi
        echo "bootstrap 完成"
    fi
    set +e
    ./extras/package/win32/configure.sh \
        --host="$TRIPLET" \
        --with-contrib="$SRC/contrib/$CONTRIB_PREFIX" \
        --disable-lua \
        --disable-faad \
        --disable-flac \
        --disable-theora \
        --disable-avcodec \
        --disable-merge-ffmpeg \
        --disable-mpc \
        --disable-libass \
        --disable-live555 \
        --disable-shout \
        --disable-goom \
        --disable-libcddb \
        --disable-zvbi \
        --disable-nls \
        > /tmp/cfg.log 2>&1
    RC=$?
    set -e
    tail -70 /tmp/cfg.log
    if [ $RC -ne 0 ]; then
        echo "::error::configure 失败 (rc=$RC)"
        grep -iE "error|cannot|not found|No package" /tmp/cfg.log | tail -30 || true
        exit 6
    fi
    echo "configure 完成"; grep -E "^(CFLAGS|CXXFLAGS)=" config.mak | head -2 || true
    echo "--- configure 中 qt 相关判定 ---"
    grep -iE "qt|moc|uic|rcc" /tmp/cfg.log | tail -25 || true
    echo "--- config.mak 中 QT 变量 ---"
    grep -iE "qt" config.mak | head -15 || true
fi

# ---------------------------------------------------------------- 6. 只编 GUI 模块
step "6/6 编译 libvlccore + Qt GUI 插件"

# libvlccore 链接依赖 compat 静态库，必须先编 compat
set +e
make -j"$(nproc)" -C compat > /tmp/mk_compat.log 2>&1
CRC=$?
set -e
tail -10 /tmp/mk_compat.log
if [ $CRC -ne 0 ]; then
    echo "::error::compat 编译失败 (rc=$CRC)"
    grep -iE "error|Error [0-9]" /tmp/mk_compat.log | tail -30 || true
    exit 7
fi
echo "compat 编译完成"

set +e
make -j"$(nproc)" -C src > /tmp/mk_core.log 2>&1
RC=$?
set -e
tail -25 /tmp/mk_core.log
if [ $RC -ne 0 ]; then
    echo "::error::libvlccore 编译失败 (rc=$RC)"
    grep -iE "error|Error [0-9]" /tmp/mk_core.log | tail -40 || true
    exit 7
fi
echo "libvlccore 编译完成"

# qt 模块依赖 po 生成的 .qm 翻译
set +e
make -j"$(nproc)" -C po > /tmp/mk_po.log 2>&1
PIRC=$?
set -e
[ $PIRC -eq 0 ] || echo "::warning::po 构建跳过 (rc=$PIRC)"

echo "对象文件数: $(find . -name '*.o' 2>/dev/null | wc -l)"
# VLC 3.0 的 modules 是非递归 automake，没有 modules/gui/qt/Makefile，
# 需在源码根按 .la 目标构建 Qt 插件
echo "Makefile 中 libqt_plugin 目标数: $(grep -c libqt_plugin Makefile || true)"
QT_OK=0
for T in "modules/gui/qt/libqt_plugin.la" "libqt_plugin.la" "modules/libqt_plugin.la"; do
    echo "--- 尝试目标: $T"
    set +e
    if [ "${T#modules/}" != "$T" ]; then
        make -j"$(nproc)" -C modules "$(basename "$T")" > /tmp/mk_qt.log 2>&1 || \
        make -j"$(nproc)" "$T" > /tmp/mk_qt.log 2>&1
        RC=$?
    else
        make -j"$(nproc)" "$T" > /tmp/mk_qt.log 2>&1
        RC=$?
    fi
    set -e
    tail -25 /tmp/mk_qt.log
    if [ $RC -eq 0 ]; then
        echo "Qt GUI 插件编译成功: $T"
        QT_OK=1
        break
    fi
    echo "--- 目标失败 (rc=$RC): $T"
done

if [ "$QT_OK" -ne 1 ]; then
    echo "::error::Qt GUI 模块编译失败"
    grep -iE "error|Error [0-9]|No rule|No targets" /tmp/mk_qt.log | tail -40 || true
    echo "--- 关键上下文 ---"
    grep -nE "moc|uic|rcc|qmake|fatal" /tmp/mk_qt.log | tail -20 || true
    exit 8
fi

step "收集产物"
mkdir -p /build/out
FOUND=0
for f in modules/.libs/libqt_plugin.dll modules/gui/qt/.libs/*.dll modules/gui/qt/*.dll src/.libs/libvlccore.dll; do
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
