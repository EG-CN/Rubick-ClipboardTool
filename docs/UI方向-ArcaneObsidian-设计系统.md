# UI 方向：Arcane Obsidian（Stitch 生成 · 候选）

> Stitch 为拉比克界面焕新生成的设计系统，配置完整可直接翻译为 RubickTheme 代码。
> 预览图：build/ui-stitch/Stitch-ArcaneObsidian.png

## 设计语言
"秘黑奥术仪盘"：深黑水晶悬浮 HUD + 祖母绿荧光 + 玻璃拟态 + 机械键帽。冷静、超聚焦、现代神秘感。

## 核心色板
- 面板底 Deep Obsidian: rgba(11,15,20,.88) + backdrop blur
- 嵌套卡片 Midnight Slate: #121820 @ 60%
- 交互态: #18222D
- 祖母绿主色: #10B981 / 荧光 secondary: #34D399 / 深绿 tertiary: #059669
- 文字亮: #F1F5F9 / 弱: #94A3B8 / 暗提示: #475569
- 描边: rgba(255,255,255,.07)；聚焦荧光边: rgba(16,185,129,.28)

## 字体三件套
- 品牌标题: Newsreader（衬线，神秘学气质）
- 界面正文: Plus Jakarta Sans
- 数据/键帽: JetBrains Mono

## 结构（750×480 面板，可扩至 600 高）
- 头部区 52px：全局搜索 + 范围标签
- 主-详分栏：45% 列表 + 55% 富预览（毛线分隔）
- 底部动作轨 36px：快捷键命令
- 行高 44px 三列微网格：类型图标/预览文本/时间戳+快捷键槽
- 选中态：祖母绿渐变填充 + 左缘 2px 强调条

## 层级
- L1 主体: rgba(11,15,20,.88) + 1px 白内缘 + 环境阴影
- L2 嵌套: rgba(18,24,32,.6)，激活项祖母绿底光
- L3 浮层: #121820 + 深阴影

## 键帽徽章 <Kbd>
高 ≥20px，keycap 字体，底 rgba(255,255,255,.05)，边 rgba(255,255,255,.12) + 1px 黑底缘模拟键深。

（完整 designMd 存于 Stitch 项目：RubickBoard UI Refresh — 拉比克界面焕新）
