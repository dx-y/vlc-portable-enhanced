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
    HAVE_VER=$(grep -m1 -oE "AC_INIT\(\[?vlc\]?, *\[?[0-9.+]+" "$SRC/configure.ac" 2>/dev/null | grep -oE "[0-9]+\.[0-9]+(\.[0-9]+)?" | head -1 || true)
    if [ -n "$HAVE_VER" ] && [ "$HAVE_VER" != "$VLC_VER" ]; then
        echo "!! 缓存源码版本为 $HAVE_VER，与目标 $VLC_VER 不符，清空重建"
        rm -rf "$SRC"
    else
        echo "源码已存在（版本 ${HAVE_VER:-未知}），跳过"
    fi
fi
if [ -d "$SRC/extras/package/win32" ]; then
    echo "复用现有源码树"
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
echo "--- 源码身份诊断 ---"
grep -m1 "AC_INIT" configure.ac || true
git -C "$SRC" describe --tags 2>/dev/null || echo "(无 git 描述)"
echo "cpp 行数: $(wc -l < modules/gui/qt/components/interface_widgets.cpp)"
echo "cpp 中 MouseHook 命中: $(grep -c MouseHook modules/gui/qt/components/interface_widgets.cpp || true)"
echo "hpp 中 MouseHook 命中: $(grep -c MouseHook modules/gui/qt/components/interface_widgets.hpp || true)"
sed -n '145,150p' modules/gui/qt/components/interface_widgets.cpp || true
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
# 官方 contrib 的 Qt 宿主工具需求新 glibc，容器自带 glibc 较旧 -> 用 /opt/glibc 里的动态链接器包装
QTWRAP=/tmp/qtwrap
mkdir -p "$QTWRAP"
NEWLD=$(find /opt/glibc -name 'ld-linux-x86-64.so.2' -type f 2>/dev/null | head -1 || true)
if [ -n "$NEWLD" ] && [ -x "$NEWLD" ]; then
    LIBDIR="$(dirname "$NEWLD")"
    LIBS="$LIBDIR:/opt/glibc/lib/x86_64-linux-gnu:/opt/glibc/usr/lib/x86_64-linux-gnu"
    echo "--- 使用新 glibc: $NEWLD"
    for t in moc rcc uic; do
        cat > "$QTWRAP/$t" <<WRAPEOF
#!/bin/sh
exec $NEWLD --library-path $LIBS $SRC/contrib/$CONTRIB_PREFIX/bin/$t "\$@"
WRAPEOF
        chmod +x "$QTWRAP/$t"
    done
    echo "--- 包装后的 moc 自检 ---"
    "$QTWRAP/moc" -v 2>&1 | head -3 || echo "MOC 包装失败"
    export MOC="$QTWRAP/moc"
    export RCC="$QTWRAP/rcc"
    export UIC="$QTWRAP/uic"
else
    echo "!! 未找到 /opt/glibc 动态链接器，回退直用 contrib 工具"
    export MOC="$SRC/contrib/$CONTRIB_PREFIX/bin/moc"
    export RCC="$SRC/contrib/$CONTRIB_PREFIX/bin/rcc"
    export UIC="$SRC/contrib/$CONTRIB_PREFIX/bin/uic"
fi
# AC_CHECK_PROGS 不读 MOC 环境变量，但读 autoconf 缓存变量 ac_cv_prog_*
export ac_cv_prog_MOC="$MOC"
export ac_cv_prog_RCC="$RCC"
export ac_cv_prog_UIC="$UIC"
# mingw 缺 WaitOnAddress 导入库时回退到 VLC 自带的等待实现
export ac_cv_func_WaitOnAddress=no
echo "MOC=$MOC RCC=$RCC UIC=$UIC"
echo "--- 容器系统 ---"; cat /etc/os-release 2>/dev/null | head -3
QTBASE="$SRC/contrib/$CONTRIB_PREFIX/include"
QTINC="-I$QTBASE"
for q in "$QTBASE"/Qt*; do
    [ -d "$q" ] && QTINC="$QTINC -I$q"
done
echo "Qt 头目录: $(echo "$QTINC" | tr ' ' '\n' | wc -l) 个"
ls "$QTBASE" 2>/dev/null | grep -i qt | tr '\n' ' '; echo
ls "$SRC/contrib/$CONTRIB_PREFIX/lib" 2>/dev/null | grep -iE "libQt5(Svg|Widgets|Gui)\.a" | tr '\n' ' '; echo
export CXXFLAGS="${CXXFLAGS:-} $QTINC"
export CFLAGS="${CFLAGS:-} $QTINC"
echo "CXXFLAGS=$CXXFLAGS"
echo "--- 官方 configure.sh 的关键行 ---"
grep -nE "PATH|MOC|qt|OPTIONS" "$SRC/extras/package/win32/configure.sh" | head -20 || true

# mingw 的 WaitOnAddress 需要 synchronization 导入库（仅在 src 链接时追加，避免干扰 configure 探测）
SYNCLIB=/opt/gcc-x86_64-w64-mingw32/x86_64-w64-mingw32/lib/libsynchronization.a
[ -f "$SYNCLIB" ] || SYNCLIB=""
echo "SYNCLIB=$SYNCLIB"

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

# 官方预编译 contrib 的 .la/.pc 保留 @@CONTRIB_PREFIX@@ 占位符，libtool 读取
# dependency_libs 时会拿到非法路径，必须先按实际绝对路径替换
CONTRIB_ABS=$(readlink -f "$SRC/contrib/$CONTRIB_PREFIX" 2>/dev/null || echo "$SRC/contrib/$CONTRIB_PREFIX")
LACNT=0
while IFS= read -r f; do
    if grep -q "@@CONTRIB_PREFIX@@" "$f" 2>/dev/null; then
        sed -i "s|@@CONTRIB_PREFIX@@|$CONTRIB_ABS|g" "$f"
        LACNT=$((LACNT+1))
    fi
done < <(find "$CONTRIB_ABS" -type f \( -name '*.la' -o -name '*.pc' \) 2>/dev/null)
echo "contrib 路径: $CONTRIB_ABS"
echo "替换 @@CONTRIB_PREFIX@@ 的文件数: $LACNT"

# 构建系统自身（config.mak / Makefile / libtool）也可能残留占位符
MADE_CNT=0
for f in "$SRC/config.mak" "$SRC/Makefile" "$SRC/libtool" "$SRC/modules/Makefile" "$SRC/po/Makefile" "$SRC/src/Makefile"; do
    [ -f "$f" ] || continue
    if grep -q "@@CONTRIB_PREFIX@@" "$f" 2>/dev/null; then
        sed -i "s|@@CONTRIB_PREFIX@@|$CONTRIB_ABS|g" "$f"
        MADE_CNT=$((MADE_CNT+1))
        echo "已修正: $f"
    fi
done
echo "构建系统文件修正数: $MADE_CNT"
echo "--- 剩余占位符分布 ---"
grep -rIl "@@CONTRIB_PREFIX@@" "$SRC" --include=Makefile --include='*.mak' --include='*.la' --include='*.pc' 2>/dev/null | head -10 || echo "(无)"

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

cd "$SRC"
ORIG_LIBS=$(grep -m1 -E "^LIBS *=" Makefile | sed 's/^LIBS *= *//')
echo "--- 顶层 Makefile LIBS: $ORIG_LIBS"
if [ -n "$SYNCLIB" ]; then
    ORIG_LIBS="$ORIG_LIBS -lssp $SYNCLIB"
fi
echo "--- 实际链接 LIBS: $ORIG_LIBS"

set +e
make -j"$(nproc)" -C src LIBS="$ORIG_LIBS" CFLAGS="${CFLAGS:-} ${CORE_XFLAGS:-}" > /tmp/mk_core.log 2>&1
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
echo "--- config.h 中 Qt 宏 ---"
grep -iE "HAVE_QT|ENABLE_QT|QT5" config.h | head -10 || echo "(无)"
echo "--- modules/Makefile 中 qt 相关 ---"
grep -c "qt_plugin" modules/Makefile 2>/dev/null || echo "modules/Makefile 无 qt_plugin"
grep -oE "^[A-Za-z0-9_./-]*qt_plugin[A-Za-z0-9_./-]*(\.la|\.dll)?:" modules/Makefile 2>/dev/null | head -10 || true
echo "--- 含 qt 的 Makefile ---"
find . -name Makefile -path "*qt*" 2>/dev/null | head -5
echo "--- modules/Makefile 中 qt 目标样本 ---"
grep -oE "^[A-Za-z0-9_./-]+_plugin\.la:" modules/Makefile 2>/dev/null | head -10 || true
# .ui 头文件属于 BUILT_SOURCES，单独构建 .la 目标时不会自动生成，先批量用 uic 生成
QTUI="$SRC/modules/gui/qt/ui"
if [ -d "$QTUI" ]; then
    echo "--- 用 uic 预生成 .ui 头文件 ---"
    UIC_RUN=0; UIC_FAIL=0
    for ui in "$QTUI"/*.ui; do
        [ -f "$ui" ] || continue
        if "$UIC" "$ui" -o "${ui%.ui}.h" >/dev/null 2>&1; then
            UIC_RUN=$((UIC_RUN+1))
        else
            UIC_FAIL=$((UIC_FAIL+1))
            echo "uic 失败: $(basename "$ui")"
        fi
    done
    echo "uic 生成 $UIC_RUN 个，失败 $UIC_FAIL 个"
fi

# Windows 资源对象 module.rc.lo 常因 windres 缺失而无效，单独处理
if [ ! -s "$SRC/modules/module.rc.lo" ]; then
    set +e
    make -C modules module.rc.lo > /tmp/mk_rc.log 2>&1
    set -e
fi
if [ -s "$SRC/modules/module.rc.lo" ] && grep -q "libtool" "$SRC/modules/module.rc.lo" 2>/dev/null; then
    echo "module.rc.lo 有效"
else
    echo "::warning::module.rc.lo 无效，从 Makefile 中剔除该链接依赖"
    sed -i 's#[^ ]*module\.rc\.lo##g' "$SRC/modules/Makefile"
fi

QT_OK=0
for T in "gui/qt/libqt_plugin.la" "libqt_plugin.la"; do
    echo "--- 尝试目标: modules/$T"
    set +e
    make -j"$(nproc)" -C modules "$T" > /tmp/mk_qt.log 2>&1
    RC=$?
    set -e
    tail -25 /tmp/mk_qt.log
    if [ $RC -eq 0 ]; then
        echo "Qt GUI 插件编译成功: modules/$T"
        QT_OK=1
        break
    fi
    echo "--- 目标失败 (rc=$RC): modules/$T"
    grep -n "@@CONTRIB_PREFIX@@" /tmp/mk_qt.log | head -5 || true
    grep -nE "libtool:   error|undefined reference|not found" /tmp/mk_qt.log | head -12 || true
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
