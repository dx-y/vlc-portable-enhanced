# VLC 3.0.24-beta1 便携版（Windows x64 自编译）

个人基于 VLC 官方 3.0.24-beta1 源码、使用 MSYS2/MinGW-w64 工具链自编译的绿色便携版。

## 本版优化点

- **竖屏播放无左右黑边**：修复宽高比过高的竖屏视频（如 9:16）在横屏显示器窗口模式下出现大面积左右黑边的问题。窗口会按视频比例等比缩放并自动钳制在屏幕范围内，不再越界，也不会有大片无效黑边。
- **窗口内单击播放 / 暂停**：在视频画面上单击即可切换播放与暂停，双击全屏等原有行为不受影响。
- **官方简体中文界面**：内置完整官方中文语言包，默认即为简体中文 UI，无需额外配置。

## 使用说明

1. 解压压缩包（本包里 `bin` 与 `share` 两个目录为运行所需）。
2. 双击运行 `bin\vlc.exe`，绿色便携，无需安装、不写注册表。
3. 如希望设为默认播放器：右键 video 文件 -> 打开方式 -> 选择此 vlc.exe 即可。

## 验证环境

- Windows 11 x64
- 经典界面 + Qt 默认窗口模式，实测竖屏视频 535x1036 等比缩窗正常，无黑边、无越界。

## 构建信息

- 上游源码：[VLC 官方 3.0.24-beta1](https://github.com/videolan/vlc/releases/tag/3.0.24-beta1)（GitHub 镜像；官方自托管见 [code.videolan.org](https://code.videolan.org/videolan/vlc/-/tree/3.0.24-beta1)）
- 工具链：MSYS2 MinGW-w64 (x86_64)
- 开源协议：GPLv2+（沿用 VLC 上游协议，源码基于官方开源代码自行编译）

## 源码与改动说明

本版为基于 VLC 官方源码（3.0.24-beta1）的自编译改版，遵循上游 GPLv2+ 许可，完整许可文本见仓库内 `COPYING.txt`。

代码改动仅涉及 Qt 界面两处源文件，改动能以统一补丁形式在 Release 附件获取（`vlc-3.0.24-beta1.mod.patch`）。配合 VLC 官方对应版本源码即可完整复现本版二进制：

```
cd vlc-3.0.24-beta1            # VLC 官方源码根目录
git apply --3way vlc-3.0.24-beta1.mod.patch
```

- `modules/gui/qt/main_interface.cpp` —— 竖屏视频按可用屏幕等比缩窗（消除左右黑边），窗口越界后自动钳制回屏幕内
- `modules/gui/qt/components/interface_widgets.cpp` —— 视频窗口内单击播放/暂停（双击或拖动自动取消，不影响原交互）

## 完整性校验

Release 附件 `SHA256SUMS.txt` 提供各文件 SHA-256 校验值，Windows 下核对方法：

```
certutil -hashfile vlc-3.0.24-beta1-win64.zip SHA256
```

对比输出与 `SHA256SUMS.txt` 中对应行一致，即确认下载文件完整、未被篡改。
