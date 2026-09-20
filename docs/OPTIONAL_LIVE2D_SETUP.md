# 可选 Live2D 资源（Bongo）安装指南

DeskPet 的 Bongo（Live2D 模式）依赖一组**不随本仓库分发**的资源。本文说明
原因、如何自行取得安装、如何在本地运行时启用，以及未安装时的降级行为。

## 为什么这些资源不随仓库分发

DeskPet 源代码以 GPLv3 发布，但 Bongo 依赖的资源无法以兼容 GPL 的方式随仓库
再分发：

| 资源 | 授权 | 不能随仓库分发的原因 |
|---|---|---|
| `live2dcubismcore.min.js` | Live2D Proprietary Software License Agreement（专有许可） | Live2D Inc. 的专有运行时，其许可条款不允许自由再分发 |
| `model/demomodel.moc3`、`model/demomodel.1024/*.png`、`model/cat.model3.json` | Live2D 素材使用条款 | Live2D 示例模型，权利归 Live2D Inc.，不因代码许可而获得再分发的权利 |
| `keyboard/*.png`、`keyboard/left-keys/*.png` 等键帽/场景素材 | 随 BongoCat 发行包分发 | 素材授权不因 BongoCat 的 MIT 代码许可自动覆盖再分发场景 |
| `pixi-v8.js` | MIT（pixi.js v8） | MIT 本身可再分发，但与上述受限文件捆绑在同一目录，为避免混淆不随仓库提供 |
| `easy-live2d.bundle.js` | MPL-2.0 | 同上；且该 bundle 经机械改造（ESM→IIFE），来源与义务见 `THIRD_PARTY_NOTICES.md` |

结论：**GPLv3 只覆盖 DeskPet 的源代码**。以上资源必须由每位用户自行从官方
渠道取得、自行阅读并遵守其许可条款；本项目不为第三方资源的可用性或授权合规
背书，也不代任何用户接受条款。

## 你需要自行取得什么

一个完整的 Bongo 资源目录，至少包含：

```
index.html                      live2dcubismcore.min.js
bongo-companion.js              pixi-v8.js
easy-live2d.bundle.js           keyboard-overlay.js
model/cat.model3.json
model/demomodel.moc3
model/demomodel.1024/texture_00.png / texture_01.png / texture_02.png
keyboard/background.png
keyboard/cover.png
keyboard/left-keys/*.png        （Alt/AltGr/Backspace/CapsLock/Control/Delete/
                                  Escape/Fn/KeyA–KeyZ/Meta/Num0–Num9/Return/
                                  Shift/Space/Tab 等键帽图）
LICENSE-BongoCat-MIT.txt
THIRD_PARTY_NOTICES.md
```

取得渠道：[ayangweb/BongoCat](https://github.com/ayangweb/BongoCat) 的官方发布
包（或你已获授权的其他来源）。取得与使用前请自行阅读并遵守：

- BongoCat 的 MIT 许可（`LICENSE-BongoCat-MIT.txt`）；
- Live2D Cubism Core 的专有许可协议（见 [live2d.com](https://www.live2d.com/en/download/core-sdk-terms/) 发布的条款）；
- Live2D 示例模型的素材使用条款；
- 各资源的声明文件（`THIRD_PARTY_NOTICES.md`）。

## 用安装脚本装入项目（推荐）

`tools/setup_optional_live2d.sh` 是**完全离线**的本地安装工具：不联网、不下载、
不代你接受任何条款；先校验完整性，全部通过才安装。

```bash
# 复制模式：独立副本（约几十 MB）
tools/setup_optional_live2d.sh --copy ~/Downloads/BongoResources

# 链接模式：符号链接，不占额外空间
tools/setup_optional_live2d.sh --link ~/Downloads/BongoResources
```

- 资源会被装入 `deskpet/BongoResources/` —— 该目录已被 `.gitignore` 忽略，
  不会进入版本库，也不会被构建打包进应用。
- 若仓库不在脚本推断的位置，加 `--project-root <仓库根目录>`。
- 校验失败时脚本**不会写入任何文件**，并列出缺失清单；请取得完整官方发布包后重试。

## 运行时启用

`BongoResources/` 已从 Xcode 工程引用中移除，因此**源码构建出的应用包不包含
这些资源**，需要用环境变量指向本地已安装目录：

```bash
# Release 构建产物
BONGO_RESOURCES_DIR=/path/to/DeskPet/deskpet/BongoResources \
  ./deskpet.app/Contents/MacOS/deskpet
```

- 从 Xcode 调试运行：`Product > Scheme > Edit Scheme… > Run > Arguments >
  Environment Variables`，添加 `BONGO_RESOURCES_DIR = /path/to/deskpet/BongoResources`。
- 该变量也可直接指向你保存原始资源的目录（不必先装入仓库）。

随后在 DeskPet 设置中开启 Bongo 即可。

## 如何移除

```bash
rm -rf deskpet/BongoResources        # copy 模式安装的
unlink deskpet/BongoResources        # link 模式安装的（不影响源目录）
```

## 未安装资源时的降级行为

未安装资源**不是错误状态**，应用会安全降级：

- 构建照常通过（资源不是构建输入）；
- Bongo 默认关闭（`bongoEnabled` 默认值为 `false`）；
- 设置页 Bongo 区顶部显示 “Optional resources not installed” 警告；
- 强行打开 Bongo 时，内容区显示橙色徽章
  「可选 Live2D 资源未安装：Bongo 已降级。安装步骤见 docs/OPTIONAL_LIVE2D_SETUP.md」，
  不会崩溃。
