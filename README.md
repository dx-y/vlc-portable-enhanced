# VLC Enhanced Portable（Windows x64 自编译增强版）

跟随 VLC 上游 **3.0.x** 自动构建的个人增强便携版。上游一发布新版本，本仓库的 GitHub Actions 会自动拉取官方源码、套用自制补丁、完成 Windows x64 交叉编译并把产物发布到 Releases，无需人工介入。

## 本版优化点

- **竖屏播放无左右黑边**：修复宽高比过高的竖屏视频（如 9:16）在横屏显示器窗口模式下出现大面积左右黑边的问题。窗口会按视频比例等比缩放并自动钳制在屏幕范围内，不再越界。
- **窗口内单击播放 / 暂停**：在视频画面上单击即可切换播放与暂停，双击全屏等原有行为不受影响。
- **官方简体中文界面**：内置官方中文语言包，默认即为简体中文 UI。

## 自动构建机制

- 每天定时检查上游 `videolan/vlc` 是否发布新的 `3.0.x` 正式版
- 检测到新版本且本仓库尚无对应 Release 时，自动执行：下载官方源码 → 应用 `patches/` 下的补丁 → 使用官方预编译 contrib → MinGW-w64 交叉编译 → 打包 → 发布 Release
- 补丁若因上游改动无法应用，构建会失败并自动开 Issue 提醒，届时需要更新 `patches/` 下的补丁

### 手动触发

仓库 Actions 页面选择 `Build VLC Enhanced Portable` → Run workflow：

| 输入项 | 说明 |
| --- | --- |
| `vlc_version` | 指定版本号（如 `3.0.24`），留空自动取 3.0 分支最新正式版 |
| `contrib_url` | 预编译 contrib 包地址，留空使用默认值 |
| `mode` | `full` 完整构建并发布；`probe` 仅验证环境到 configure 结束 |

## 使用说明

1. 解压压缩包（`bin` 与 `share` 两个目录为运行所需）。
2. 双击运行 `bin\vlc.exe`，绿色便携，无需安装、不写注册表。
3. 如希望设为默认播放器：右键视频文件 → 打开方式 → 选择此 `vlc.exe`。

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
