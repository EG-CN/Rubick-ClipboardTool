# 拉比克 RubickBoard · macOS 剪贴板+截图钉图工具

菜单栏常驻的剪贴板历史 + 截图 + 桌面钉图工具（对标 Windows `Win+V` + Snipaste）。
对应功能清单：`../剪贴板截图工具-功能清单-v1.md`（修订 v1.1）；交互原型：`../剪贴板工具原型/`。

- 技术栈：Swift + SwiftUI（原生，macOS 14+）
- 当前版本：**v1.1.0**（Stitch 设计系统已还原：祖母绿主题/搜索/筛选/发光卡片/侧边栏设置；应用已更名「拉比克」）

## 快速开始

```bash
# 方式一：命令行直接运行（开发调试）
swift run

# 方式二：打包成 .app
./scripts/make-app.sh
open "build/拉比克.app"
```

> 用 Xcode 开发：直接打开本目录的 `Package.swift` 即可。
> 首次运行会请求 **辅助功能** 权限（自动粘贴/模拟 ⌘V 需要）。截图走系统 `screencapture` 交互框选，无需屏幕录制权限。

## 常见问题：辅助功能授权「勾了也没用」

**原因**：ad-hoc 签名每次构建指纹都会变，系统把新版本当成另一个 App，之前的授权自动失效。

**一次性解决**（之后永久有效）：

```bash
./scripts/setup-signing.sh      # 生成固定签名证书「ClipboardTool Dev」并导入钥匙串
./scripts/make-app.sh           # 用固定身份重新打包
open "build/拉比克.app"
```

然后到 系统设置 → 隐私与安全性 → 辅助功能：先选中旧的「剪贴板工具」条目按 **−** 删除，再按 **+** 添加新包（或等它弹窗），重启应用即可。设置 → 通用 里有实时授权状态显示（绿勾 = 已生效）。

## 已实现（骨架阶段）

| 模块 | 状态 | 说明 |
|------|------|------|
| 菜单栏常驻 | ✅ | 剪贴板图标 + 菜单（面板/截图/清空/设置/退出），不占 Dock（LSUIElement），**单实例运行** |
| 剪贴板监听 | ✅ | 0.5s 轮询 changeCount；文字 + 图片；去重；上限裁剪（默认 50）；**忽略密码管理器**（org.nspasteboard.ConcealedType 等） |
| 持久化 | ✅ | `~/Library/Application Support/ClipboardTool/`：history.json 索引 + images/ 存 PNG，重启保留（后续可迁移 SQLite） |
| 历史面板 | ✅ | 悬浮置顶 NSPanel；点击条目 = 复制 + 模拟 ⌘V 粘贴（可关）；键盘导航；失焦/点击外部自动关闭；关闭后**焦点还原到原输入框**；悬停删除/钉图按钮；空态提示 |
| 快捷键（全部可配置） | ✅ | 全局：⌘⇧V 面板 / ⌘⇧A 截图 / ⌘, 设置；面板内：↑↓ 选择 / ↵ 粘贴 / ⎋ 关闭 / ⌫ 删除 / P 钉图 / ⌘1–9 快选——设置页录制、冲突检测（含面板内↔全局交叉冲突）、系统保留组合提示、恢复默认，面板底部提示实时联动 |
| 区域截图 | ✅ | 调用系统 `screencapture -i -c`（免权限，功能清单 7.3 方案 B），确认后自动入历史 |
| 截图后直接钉图 | ✅ | 截图确认后弹出操作条「已复制并存入历史 · 钉图」，6 秒自动消失（功能清单 3.5） |
| 钉图 | ✅ | 置顶 NSPanel；拖拽移动；滚轮缩放（窗口随缩放自适应）；**双击取消**；多贴图共存；不抢焦点；**右键菜单**（复制图片 / 另存为 PNG / 关闭贴图） |
| 设置 | ✅ | 通用（开机自启 SMAppService / 点选自动粘贴开关）；快捷键（全局 3 + 面板内 7，全部可录制）；历史（上限步进、忽略密码开关、清空）；关于 |

## 代码结构（Sources/ClipboardTool/）

```
main.swift                 入口（NSApplicationMain）
AppDelegate.swift          菜单栏状态项 + 单实例 + 服务装配
Models.swift               ClipboardItem 模型 + HistoryStore（JSON 持久化）
ClipboardMonitor.swift     剪贴板轮询监听 + 隐私过滤
HotkeyManager.swift        Carbon 全局快捷键 + 录制辅助函数
PanelKeys.swift            面板内快捷键配置（全部可配置）
HistoryPanel.swift         历史面板窗口 + SwiftUI 视图
ScreenshotController.swift 系统 screencapture 封装
ShotActionBar.swift        截图后「钉图」操作条
PinController.swift        钉图窗口（拖拽/缩放/双击取消/右键菜单）
SettingsController.swift   设置窗口 + 快捷键录制器（全局+面板内）
Utilities.swift            剪贴板写入 / 模拟粘贴 / 权限引导 / 另存 PNG
```

## 已知边界（后续迭代项）

1. 截图走系统交互框选（体验与自绘选框有差异），自绘选框（ScreenCaptureKit）在路线图上（功能清单 7.3 方案 A）；
2. Carbon 快捷键 API 在 macOS 14+ 标记 deprecated（仍正常工作），后续可迁移 CGEventTap；
3. 钉图透明度调节未做（功能清单 P2）；
4. 深浅色：跟随系统（SwiftUI 原生 Material 自动适配）；
5. ~~产品名占位~~ 已定名「拉比克」，Info.plist 与界面文案均已更新。

## 分发与共享（GitHub Releases）

1. 在 GitHub 新建空仓库（如 `sunrunyu/ClipboardTool`），不要勾选 README；
2. 推送本仓库：
   ```bash
   git remote add origin git@github.com:<你的用户名>/ClipboardTool.git
   git push -u origin main
   ```
3. 打 tag 自动发版（Actions 会构建 Intel + Apple Silicon 通用安装包并挂到 Release 页面）：
   ```bash
   git tag v1.1.0 && git push origin v1.1.0
   ```
   也可以手动触发：仓库 → Actions → Build Release → Run workflow。

好友安装：解压 → 拖入「应用程序」→ 首次打开**右键 → 打开**（本应用为 ad-hoc 签名，系统会提示一次）→ 系统设置里授权**辅助功能**。详细步骤见包内 `安装说明.txt`。

> 无缝体验（双击即开、无任何提示）需要 Apple Developer 账号（$99/年）做 Developer ID 签名 + 公证；届时把证书放进 Actions secrets，工作流改两行即可自动签名公证。

## 下一步建议

1. 真机体验一轮：`./scripts/make-app.sh` 后日常用一天，收集交互问题；
2. 打磨项：截图自绘选框（ScreenCaptureKit）、钉图透明度调节、忽略指定 App（P2）；
3. 正式命名 + 图标设计；
4. 分发已可用（GitHub Releases 自动构建通用安装包，见下）；如需「双击即开、零提示」的无缝体验，再开通 Developer ID（$99/年）签名公证。
