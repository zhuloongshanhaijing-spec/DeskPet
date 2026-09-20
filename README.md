<h1 align="center">
  <br>
  DeskPet
  <br>
</h1>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0-blue">
</p>

> 📸 截图 / 预览图暂缺：欢迎通过 PR 贡献你自己拍摄或制作、无版权风险的素材。

---

**DeskPet** 是一款 macOS 桌面宠物应用，让你的菜单栏刘海住进一只活灵活现的小宠物 🐾。支持任意序列帧素材换肤——猫、狗、兔子，任何你喜欢的宠物形象都可以。

它基于 [boring.notch](https://github.com/TheBoredTeam/boring.notch) 构建，在保留原版刘海动态岛功能（音乐控制、日历、文件暂存、HUD 替换）的基础上，新增了完整的**桌面宠物系统**：

- 🐾 **序列帧动画引擎** — 支持 24fps 高帧率动画，部分帧预缓存 + 流式补齐，内存占用极低（~200MB）
- 🏠 **回窝/出窝** — 宠物可以回刘海里睡觉，拖到刘海区域松手即瞬间进窝
- 🚶 **行为 AI** — 自主走动、打哈欠、睡觉、开心蹦跳，活动频率可自定义
- 🎵 **音乐联动** — 播放音乐时宠物会跳舞（需提供跳舞素材）
- 🖱️ **丰富交互** — 单击戳一戳、双击回窝/出窝、拖拽拎起走动、拖到刘海自动打开宠物面板
- 🎨 **可换肤** — 任意序列帧素材即可作为皮肤（支持 seeDance 等 AI 视频抽帧）
- ⚙️ **可调节** — 活动频率（Chill/Normal/Hyper + 自定义）、宠物大小、音效音量
- 🐱 **可选 BongoCat Live2D 宠物** — 自行安装 [BongoCat](https://github.com/ayangweb/BongoCat) 同款 Live2D 资源后可获得：头部跟随鼠标、按键时猫爪落在真实键位上、鼠标点击反馈（见 [可选 Live2D 资源](docs/OPTIONAL_LIVE2D_SETUP.md)）

## 📋 功能一览

### 桌面宠物（本项目新增）

| 功能 | 说明 |
|------|------|
| 序列帧动画 | PNG 序列帧，24fps，部分帧缓存 + 流式解码 |
| 行为状态机 | idle / walk / sleep / yawn / happy / hurt / drag / fall |
| 待机变体轮换 | 多套待机动画随机切换，不单调 |
| 拖拽投放刘海 | 拖宠物到刘海区域 → 自动打开宠物面板，松手瞬间进窝 |
| 回窝节能 | 回窝后卸载所有活动动画帧，内存降至 ~120MB |
| 音效系统 | 每个动作可配独立音效，音量独立可调 |

> 公开仓库不附带默认角色素材：请把序列帧皮肤放到 `~/Pictures/BoringPet/` 或在设置中指定目录（见 [PET.md](PET.md)）。

### BongoCat Live2D 宠物（实验性，需自备资源）

基于 Live2D（Cubism Core + pixi.js + easy-live2d）在 WKWebView 中渲染，与官方 BongoCat 显示模式同架构（无猫场景底图 + 活模型 + 键位爪贴图，同一相机坐标系逐像素对齐）：

| 功能 | 说明 |
|------|------|
| 头部跟随 | 猫头和瞳孔实时跟随鼠标移动 |
| 键盘联动 | 按键时白色猫爪叠加在对应键帽上（需授权输入监控） |
| 鼠标联动 | 鼠标移动拖尾、左右键点击反馈 |
| 官方场景 | 键盘为 BongoCat 官方素材，透视斜置，爪贴图与键位原生对齐（需自行安装可选资源） |
| 呼吸动画 | 待机呼吸、眨眼等 Live2D 原生动画 |

> 所需资源不随本仓库分发（授权受限）。安装步骤见 **[docs/OPTIONAL_LIVE2D_SETUP.md](docs/OPTIONAL_LIVE2D_SETUP.md)**；未安装时 Bongo 自动降级为禁用状态并给出提示。

### 原版刘海功能（继承自 boring.notch）

- 🎧 音乐播放控制 + 实时可视化
- 📆 日历 / 提醒事项集成
- 📚 文件暂存架（支持 AirDrop）
- 🎚️ 系统 HUD 替换（音量 / 亮度 / 键盘背光）
- 🔋 充电指示器
- 📷 镜子（摄像头预览）

---

## 安装

本仓库是源码发行（GPLv3），暂不提供官方预编译下载，请从源码构建。

### 系统要求（版本口径统一）

| 项 | 要求 | 依据 |
|---|---|---|
| 运行（最低部署目标） | macOS **14 Sonoma** 或更高（Apple Silicon / Intel） | 工程 `MACOSX_DEPLOYMENT_TARGET = 14.0`；未在全部 14.x/15.x 实机回归 |
| 媒体控制功能 | macOS **15.4+** 通过 [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter) 完整可用；更早版本该功能可能受限，其余功能不受影响 | 依赖系统私有框架在 15.4+ 的可用性 |
| 构建 | **Xcode 16.4 或更高** | 已在 Xcode 16.4（Build 16F6，MacOSX15.5 SDK，宿主 macOS 27.0）完整验证 Release 与 Debug 构建；更高版本预期兼容但未逐一验证。CI（cicd.yml）动态选择 runner 可用的最新 Xcode，不锁定版本 |

> 如需下调最低运行版本或支持旧版 Xcode，请先在目标环境完整回归后提交 PR 说明。

### 从源码构建

```bash
git clone https://github.com/zhuloongshanhaijing-spec/DeskPet.git
cd DeskPet
open deskpet.xcodeproj
```

在 Xcode 中按 `Cmd + R` 构建运行。

> 也可以用命令行构建：
> ```bash
> xcodebuild -project deskpet.xcodeproj -scheme deskpet \
>   -configuration Release -destination 'generic/platform=macOS' \
>   CODE_SIGNING_ALLOWED=NO build
> ```

### 未签名分发的限制

本项目没有 Apple 开发者签名。自己构建的应用直接运行没有问题；但如果你把构建产物分发给他人（或从他人处获取），首次打开会被 macOS Gatekeeper 拦截，需要收件方在终端解除隔离（只需一次）：

```bash
xattr -dr com.apple.quarantine /Applications/deskpet.app
```

### 不适用于 Mac App Store

DeskPet 使用的部分能力（如通过私有框架读取系统媒体信息、刘海窗口/空间管理）不符合 App Store 审核要求，**无法上架 Mac App Store**，只能以源码或开发者自行签名的方式分发。

---

## 使用

### 桌面宠物

- **单击宠物**：戳一戳（心情好会开心蹦跳，心情差会委屈）
- **双击宠物**：回窝睡觉 / 出窝活动
- **拖拽宠物**：拎起来走动；拖到刘海区域松手 → 瞬间进窝 + 打开宠物面板
- **宠物面板**（刘海展开后 Pet 标签页）：查看心情/清洁度、抚摸、召回/出窝、调节音效音量

### 刘海动态岛

- 鼠标悬停刘海 → 展开查看音乐/日历/文件架
- 点击菜单栏图标 → 打开设置
- 拖文件到刘海 → 自动打开文件架

---

## 权限与隐私

DeskPet 只在本机运行，**不含遥测、不上传任何数据，也不内置自动更新器**。以下权限仅在对应功能开启时请求：

| 权限 | 用途 | 说明 |
|---|---|---|
| 输入监控（Input Monitoring） | Bongo 键盘联动（可选） | 只读取按键/鼠标的**事件时序**用于猫爪动画，**不记录也不上传按键内容** |
| 日历 / 提醒事项 | 刘海日历面板 | 只读取本机日历与提醒 |
| 摄像头 | 镜子功能（可选） | 画面仅本地渲染，不存储、不上传 |
| 媒体与自动化（AppleScript） | 音乐控制 / 正在播放 | 读取正在播放的信息并控制播放 |

**网络访问**：应用只访问 HTTPS 服务（音乐服务 API 等）；YouTube Music 控制器会连接本机 `http://localhost:<端口>` 的本地辅助进程。已在 Info.plist 用 `NSAllowsLocalNetworking` 将明文连接限定为仅本机回环——**未开启** `NSAllowsArbitraryLoads`，不放开任意明文流量。

---

## 桌面宠物素材

宠物素材放在 `~/Pictures/BoringPet/` 目录下，每个动作是一个子文件夹（编号 PNG 序列帧）。

详见 **[PET.md](PET.md)** 和 **[docs/DESIGN.md](docs/DESIGN.md)**。

支持用 seeDance 等 AI 工具生成视频后抽帧作为皮肤。

## 可选 Live2D 资源（Bongo）

Bongo 模式依赖的 Live2D 资源（Cubism Core、示例模型、键帽素材等）因授权限制**不随仓库分发**，需要你自行从官方渠道取得并通过 `tools/setup_optional_live2d.sh` 安装。完整说明：**[docs/OPTIONAL_LIVE2D_SETUP.md](docs/OPTIONAL_LIVE2D_SETUP.md)**。

---

## ⚠️ 已知限制

- **未签名分发**：无 Apple 开发者签名，他人构建的产物首次打开需解除隔离（见上文）
- **不可上架 App Store**：使用 MediaRemote 等私有框架
- **不内置素材**：桌面宠物皮肤与 Bongo Live2D 资源均需自行提供（见 [PET.md](PET.md) / [docs/OPTIONAL_LIVE2D_SETUP.md](docs/OPTIONAL_LIVE2D_SETUP.md)）
- **无自动更新**：公开源码构建不包含更新检查
- **系统版本**：最低部署目标 macOS 14，实际仅在 macOS 15.x 开发与验证；媒体控制在 15.4+ 完整可用
- **CI 签名构建**：`manual_build` 工作流需维护者自备证书 secrets，默认未配置（不影响源码构建）

## 🤝 贡献与反馈

- **贡献代码 / 文档**：阅读 [CONTRIBUTING.md](CONTRIBUTING.md)（PR 目标分支为 `main`）
- **报告 Bug / 功能建议**：使用仓库 Issue 模板（Bug Report / Feature Request 表单）
- **安全漏洞**：**请勿公开提 Issue**——按 [SECURITY.md](SECURITY.md) 通过 GitHub 私密漏洞报告（Private Vulnerability Reporting）提交
- **行为准则**：[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

---

## 🛣️ Roadmap

### 桌面宠物
- [x] 序列帧动画引擎 + 行为 AI
- [x] 回窝/出窝 + 拖拽投放刘海
- [x] 部分帧预缓存 + 流式补齐（低内存）
- [x] 多套待机变体轮换
- [x] 活动频率 / 音效音量自定义
- [x] BongoCat Live2D 宠物（键鼠联动 + 官方键盘场景，需自备资源）
- [ ] 更多行为（吃东西、玩耍、互动小游戏）
- [ ] 皮肤市场 / 社区分享
- [ ] 多宠物同屏

### 继承自原版
- [x] 音乐控制 + 可视化
- [x] 日历 / 提醒 / 文件架 / HUD 替换
- [ ] 蓝牙设备活动
- [ ] 天气集成

---

## 📜 许可与资源授权

本项目代码基于 [boring.notch](https://github.com/TheBoredTeam/boring.notch)（GPLv3）构建，因此**代码部分遵循 GPLv3 开源**：任何人都可以免费使用、修改和分发（包括商业用途，无"仅个人使用"之类的限制），但衍生作品必须同样以 GPLv3 开源并保留署名。

名称与品牌另行处理：**代码按 GPLv3 发布；"DeskPet" 名称、官方 Logo 与官方发布身份不随 GPLv3 自动授权**，使用规范见 [TRADEMARK_POLICY.md](TRADEMARK_POLICY.md)（该政策不限制 GPLv3 授予的任何代码权利）。

以下内容**不属于 GPLv3 授权范围**：

- **项目名称与品牌**：DeskPet 名称、官方 Logo 与官方发布身份不随 GPLv3 自动授权，使用规范见 [TRADEMARK_POLICY.md](TRADEMARK_POLICY.md)；该政策不限制 GPLv3 授予的任何代码权利（包括商业使用）。
- **可选 Live2D 资源**：Cubism Core、Live2D 示例模型与 BongoCat 键帽素材不随仓库分发，由用户自行取得并自行遵守其许可（见 [docs/OPTIONAL_LIVE2D_SETUP.md](docs/OPTIONAL_LIVE2D_SETUP.md)）。
- **官方签名构建**：发布到官网 / 分发渠道的官方签名版本。
- **商业支持与定制**：优先响应、功能定制、集成支持等服务。

商业合作请联系项目维护者（通过 GitHub Issues / Discussions）。捆绑与引用的第三方开源组件许可见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。

---

## 🤝 致谢

本项目基于开源项目 **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** 构建，感谢原项目作者 [TheBoredTeam](https://github.com/TheBoredTeam) 的杰出工作。

### 依赖的开源项目
- **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** — 刘海动态岛核心（GPLv3）
- **[BongoCat](https://github.com/ayangweb/BongoCat)**（ayangweb，MIT）— Live2D 参数对接参考实现；配套的键盘场景与键位爪贴图素材**不随本仓库分发**
- **easy-live2d**（npm 包，MPL-2.0，Panzer-Jack；其前身工作 [pixi-live2d-display](https://github.com/guansss/pixi-live2d-display) 为 MIT）— Live2D 渲染封装
- **[pixi.js](https://github.com/pixijs/pixijs)**（MIT）— WebGL 渲染引擎
- **Live2D Cubism Core** — Live2D Inc. 专有运行时，不随本仓库分发，用户自行取得
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — macOS 15.4+ 媒体控制
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — 文件架功能参考

本项目继承 GPLv3 协议开源。第三方许可汇总见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)；可选 Live2D 资源的授权与安装见 [docs/OPTIONAL_LIVE2D_SETUP.md](docs/OPTIONAL_LIVE2D_SETUP.md)。

---

<p align="center">
  Made with 🫶🏻 for pet lovers
</p>
