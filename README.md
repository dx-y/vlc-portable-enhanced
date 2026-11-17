# VLC Enhanced（Windows x64 自编译增强版）

跟随 VLC 上游 **3.0.x** 自动构建的个人增强版。上游一发布新版本，本仓库的 GitHub Actions 会自动拉取官方源码、套用自制补丁、完成 Windows x64 交叉编译，并把**便携包**与**安装包**一并发布到 Releases，无需人工介入。

## 产物形态（按需选一个）

| 产物 | 适合谁 | 特点 |
| --- | --- | --- |
| `vlc-<版本>-win64.exe` | 日常主力使用 | NSIS 安装包。安装时注册文件关联与右键菜单、创建桌面/开始菜单快捷方式、可在「应用和功能」中卸载。**装完双击视频就直接打开，不用再手动设默认播放器。** |
| `vlc-<版本>-win64.7z` / `.zip` | 绿色免安装、放 U 盘、多版本共存 | 解压即用，运行 `bin\vlc.exe`，不写注册表。**不会自动关联视频文件**，需要自己右键「打开方式」指定。 |
| `vlc-<版本>-win64.msi` | 批量部署 / 组策略分发 | 标准 Windows Installer 包，支持静默安装。 |

> 一句话：想省事就下 `.exe`；不想动系统就下 `.7z`。

## 本版优化点

- **竖屏播放无左右黑边**：修复宽高比过高的竖屏视频（如 9:16）在横屏显示器窗口模式下出现大面积左右黑边的问题。窗口会按视频比例等比缩放并自动钳制在屏幕范围内，不再越界。
- **窗口内单击播放 / 暂停**：在视频画面上单击即可切换播放与暂停，双击全屏等原有行为不受影响。
- **官方简体中文界面**：内置官方中文语言包，默认即为简体中文 UI。

## 自动构建机制

- 每天定时检查上游 `videolan/vlc` 是否发布新的 `3.0.x` 正式版
- 检测到新版本且本仓库尚无对应 Release 时，自动执行：下载官方源码 → 应用 `patches/` 下的补丁 → 使用官方预编译 contrib → MinGW-w64 交叉编译 → 生成 7z/zip 便携包 + NSIS 安装包 + MSI → 发布 Release
- 补丁若因上游改动无法应用，构建会失败并自动开 Issue 提醒，届时需要更新 `patches/` 下的补丁

### 手动触发

仓库 Actions 页面选择 `Build VLC Enhanced Portable` → Run workflow：

| 输入项 | 说明 |
| --- | --- |
| `vlc_version` | 指定版本号（如 `3.0.24`），留空自动取 3.0 分支最新正式版 |
| `contrib_url` | 预编译 contrib 包地址，留空使用默认值 |
| `mode` | `full` 完整构建并发布；`probe` 仅验证环境到 configure 结束 |

## 使用说明

### 方式一：安装包（推荐日常使用）

1. 下载 `vlc-<版本>-win64.exe`，双击运行。
2. 一路下一步装完（默认路径即可，建议勾选「创建桌面快捷方式」）。
3. 装完直接双击任意视频文件即可用本版打开，文件关联、右键菜单、卸载入口都已注册，**不需要再手动设置默认播放器**。

### 方式二：便携包（不动系统）

1. 解压 `vlc-<版本>-win64.7z`（`bin` 与 `share` 两个目录为运行所需，需保持同级）。
2. 双击运行 `bin\vlc.exe`，绿色便携，无需安装、不写注册表。
3. 如希望设为默认播放器：右键视频文件 → 打开方式 → 选择这个 `vlc.exe`（便携版不做自动关联）。

## 源码与改动说明

本项目基于 VLC 官方源码的自编译改版，遵循上游 GPLv2+ 许可，完整许可文本见仓库内 `COPYING.txt`。

代码改动仅涉及 Qt 界面两处源文件，全部改动以补丁形式存放在 `patches/`：

- `modules/gui/qt/main_interface.cpp` —— 竖屏视频按可用屏幕等比缩窗（消除左右黑边），窗口越界后自动钳制回屏幕内
- `modules/gui/qt/components/interface_widgets.cpp` —— 视频窗口内单击播放/暂停（双击或拖动自动取消，不影响原交互）

本地复现（以 VLC 3.0.24 为例）：

```bash
curl -LO https://download.videolan.org/pub/videolan/vlc/3.0.24/vlc-3.0.24.tar.xz
tar xf vlc-3.0.24.tar.xz && cd vlc-3.0.24
git init -q . && git add -A && git commit -qm base
git apply -p1 --3way ../patches/0001-qt-enhancements.patch
./extras/package/win32/build.sh -a x86_64 -p -r -i r
cd win64
make package-win32-release   # 瘦身 7z
make package-win32-exe       # NSIS setup.exe（需 makensis）
make package-msi             # MSI（需 wixl/msitools）
```

对应的完整源码可由「上游官方发布包 + `patches/` 补丁」完整还原。

## 构建信息

- 上游项目：[videolan/vlc](https://github.com/videolan/vlc)，跟随 3.0.x 分支
- 工具链：MinGW-w64 交叉编译（`x86_64-w64-mingw32`），官方预编译 contrib
- 开源协议：GPLv2+

## 完整性校验

Release 附件 `SHA256SUMS.txt` 提供各文件 SHA-256 校验值，Windows 下核对：

```
certutil -hashfile <下载的文件> SHA256
```

输出与 `SHA256SUMS.txt` 中对应行一致，即确认文件完整、未被篡改。
