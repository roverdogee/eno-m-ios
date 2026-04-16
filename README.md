# ENO-M iOS

ENO-M iOS 是一个面向 iPhone 的 B 站音乐播放器实验项目。它把原本偏浏览器/桌面插件形态的 ENO-M，整理成了一个可以在 Xcode 中直接打开、构建和安装的原生 iOS App。

这个项目最特别的一点是：整个 App 的代码实现由 Codex 完成。项目所有功能、界面调整、问题排查和工程整理，都是由用户提出需求、Codex 直接阅读代码、修改代码、构建验证并持续迭代完成的。用户没有写一行代码，只负责描述想要的体验、指出问题、做产品判断和实际测试。

## 这个 App 能做什么

- 搜索 B 站视频，并把视频作为音乐条目播放。
- 支持 B 站网页登录和二维码登录。
- 登录成功后保存本地登录状态，新的登录成功前不会误清掉原有账号。
- 支持播放、暂停、上一首、下一首、进度拖动。
- 支持列表循环、单曲循环、随机播放模式切换。
- 支持后台播放、锁屏控制、锁屏显示歌曲信息和封面。
- 支持收藏音乐。
- 支持收藏 UP 主，并查看 UP 主空间里的视频列表。
- 支持最近播放。
- 支持自定义播放列表、新建、重命名、删除和添加歌曲。
- 支持首页搜索结果和 UP 主视频列表加载更多。
- 支持底部迷你播放栏和全屏正在播放页面。
- 支持播放页手势：滑动返回、切歌等。
- 支持设置页清空数据、退出登录等危险操作的系统确认弹窗。
- 使用本地持久化保存收藏、最近播放、播放列表和界面状态。

## 界面设计

ENO-M iOS 采用深色界面，围绕手机上的音乐播放体验重新设计，而不是简单把网页塞进 App。

主要界面包括：

- 首页：搜索、推荐和搜索结果。
- 收藏：收藏的音乐和收藏的 UP 主。
- 列表：我的收藏、最近播放和自定义播放列表。
- 设置：登录、登录态、平台信息、本地数据管理。
- 正在播放：封面、歌曲信息、播放进度、播放控制、循环模式和收藏入口。

界面经过多轮真实设备截图反馈调整，包括：

- 顶部标题和标签栏固定。
- 搜索列表滚动不穿过顶部区域。
- 底部播放栏避免遮挡页面内容。
- Toast 通知改为类似 iOS 桌面横幅，不再把页面顶下去。
- 输入法跟随 App 使用暗色模式。
- 按钮、列表、封面和播放栏的尺寸针对 iPhone 屏幕反复微调。

## 实现方式

这个项目没有依赖 Node，也不需要前端构建工具。打开 Xcode 就能运行。

整体结构是：

- SwiftUI 作为 App 入口和原生容器。
- `WKWebView` 加载本地 `EnoMusicIOS/Web/index.html` 作为主要界面。
- JavaScript 通过 `window.enoPlatform.invoke(...)` 调用 Swift 原生能力。
- Swift 侧负责 B 站接口、登录、Cookie、音频播放、锁屏控制和系统弹窗。
- Web 侧负责页面状态、列表交互、播放队列、收藏和播放列表 UI。

这种方式让界面迭代速度接近 Web，同时把 iOS 必须原生处理的能力交给 Swift：

- `AVPlayer` 负责真实音频播放。
- `MPNowPlayingInfoCenter` 负责锁屏信息。
- `MPRemoteCommandCenter` 负责锁屏播放控制。
- `WKWebView` bridge 负责 JS 与 Swift 通信。
- Keychain/UserDefaults 负责本地状态保存。

## 与原项目的关系

本项目参考了两个已有项目的思路：

- ENO-M 插件项目：https://github.com/Cteros/eno-music
- ENO-M macOS 桌面项目：https://github.com/Cteros/eno-m-desktop

iOS 版本不是直接套壳复制，而是根据手机使用场景重新组织了登录、搜索、播放、收藏、播放列表、手势和设置页面。

## Codex 完成了什么

Codex 在这个项目中承担了完整工程实现工作，包括：

- 创建 iOS 工程结构。
- 编写 SwiftUI/WKWebView 容器。
- 实现 JS 到 Swift 的桥接。
- 参考原项目修复 B 站搜索参数和播放参数。
- 实现网页登录、二维码登录和 Cookie 保存。
- 实现原生音频播放、后台播放、锁屏信息和远程控制。
- 实现收藏、最近播放、UP 主收藏、自定义播放列表。
- 设计和反复调整移动端 UI。
- 根据真机/模拟器截图修复遮挡、白边、滚动、动画、输入法暗色等问题。
- 生成 App 图标并导入 Xcode 资源。
- 打包可用于 AltStore 测试的 IPA。
- 整理 Git 仓库和 README。

用户没有直接修改代码。整个过程是一次自然语言驱动开发：用户不断描述「我想要什么」「这里不对」「这样更自然」，Codex 负责把这些需求落到代码里。

## 打开项目

用 Xcode 打开：

```sh
open EnoMusicIOS.xcodeproj
```

或者在命令行构建：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project EnoMusicIOS.xcodeproj -scheme EnoMusicIOS -destination 'generic/platform=iOS' -derivedDataPath ./Build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

如果要安装到真机，需要在 Xcode 中配置自己的 Team 和签名。

## 当前状态

这个 App 已经可以作为一个可测试的 iOS 音乐播放器使用。它仍然是个人实验项目，不是 B 站官方客户端，也不包含任何官方授权关系。

请只在个人学习和测试范围内使用，并遵守相关平台规则。
