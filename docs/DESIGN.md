# Tandem iOS 设计说明（Apple HIG）

> 对应 PRD v1.4  
> Figma：[Tandem iOS Design](https://www.figma.com/design/5wmtldOSN7EznnnpjIRDnD)  
> 画板基准：**iPhone 16 / 393×852**，圆角设备框仅用于展示

---

## 1. 设计原则（对齐 Human Interface Guidelines）

| 原则 | 在 Tandem 中的体现 |
|------|-------------------|
| **清晰 Clarity** | 片库双列海报为主视觉；播放页播控与聊天分区明确；文案短句 |
| **遵从 Deference** | 内容优先：海报与影片画面占主导；系统控件克制，少用装饰 |
| **深度 Depth** | 「我的 / 换片 / 字幕同步 / 配置」使用 **Sheet**（圆角 + Grabber），背后内容变暗 |
| **直接操作** | 片名 ▾ 换片、进度条拖动、字幕步进按钮；反馈在按下时出现 |
| **一致性** | 使用系统语义色、Inset Grouped 列表、导航栏左右动作模式 |

**不做：** 底部 Tab（PRD 为 SPA）、过度渐变/霓虹、非系统紫主题、卡片阴影堆叠。

---

## 2. 视觉规范

### 2.1 颜色（Light，语义对齐 UIKit）

| Token | Hex | 用途 |
|-------|-----|------|
| `systemBlue` | `#007AFF` | 主按钮、链接、选中勾 |
| `systemGroupedBackground` | `#F2F2F7` | 片库 / 配置 / Sheet 背景 |
| `secondarySystemGroupedBackground` | `#FFFFFF` | 列表组、输入底 |
| `label` | `#000000` | 主文案 |
| `secondaryLabel` | `#3C3C43` @ 60% | 次要文案、年份 |
| `tertiaryLabel` | `#3C3C43` @ 30% | 占位符 |
| `separator` | `#3C3C43` @ 29% | 行分割 |
| `systemRed` | `#FF3B30` | 退出登录 |
| Watch 背景 | `#000000` | 沉浸播放 |

暗色模式：播放页已是暗色；片库/设置可在实现期跟随 `UIUserInterfaceStyle`（设计稿本期以 Light + Watch Dark 为主）。

### 2.2 字体

- **生产：** SF Pro / SF Pro Display（大标题）  
- **Figma 稿：** Inter 临时代替（环境限制）；实现时换回 SF  
- 字号阶梯：大标题 28–34、导航标题 17 Semibold、正文 15–17、说明 12–13  

### 2.3 圆角与间距

| 元素 | 值 |
|------|-----|
| 设备示意框 | 40 |
| Sheet 顶角 | 28（连续圆角感） |
| 主按钮 | 14 |
| 列表组 / 输入 | 12 |
| 海报卡 | 12 |
| 头像 | 圆形 |
| 水平边距 | 16–20 |
| 双列网格间距 | 12 |

### 2.4 控件

- 主按钮：满宽、`systemBlue` 底、白字、高度约 50  
- 输入：白底、圆角 12、内边距 14–16（类 `UITextField` 表单）  
- 列表：Inset Grouped（白卡片组 + 分组标题 13pt secondary）  
- Sheet：顶部 Grabber 36×5  

---

## 3. 屏幕清单

| # | 画板名 | 说明 |
|---|--------|------|
| 01 | Login | 无注册；「服务配置」文字按钮 |
| 02 | Library (SPA) | 主壳；**右上角头像 = 我的** |
| 03 | Me Sheet | 头像/昵称/服务配置/退出 |
| 04 | Service Config | IM + 七牛；分享与导入列表行；测试连接 |
| 05 | Watch | 沉浸播放器、成员、「+」邀请、聊天 |
| 06 | Switch Movie | 换片 Sheet |
| 07 | Subtitle Sync | ±0.5s 时间轴校准 |
| 08 | Subtitle Panel | 字幕选择 |
| 09 | Online Subtitle Search | 在线搜字幕结果 |
| 10 | Login Unconfigured | 未配置引导 |
| 11 | Share Config | 加密深链分享（链接优先 + QR） |
| 12 | Paste Import | 粘贴配置链接 |
| 13 | Import Confirm | 脱敏确认导入 |
| 14 | Invite Sheet | 分享/复制邀请 |
| 15 | Watch Member | 成员视角 + Toast |
| 16 | Switch Confirm | 换片二次确认 |
| 17 | Watch Landscape | 横屏全屏 |
| 18 | Library Empty | 片库空态 |
| 19 | Library Error | 片库失败 |
| 20 | Subtitle Search Empty | 搜字幕无结果 |
| 21 | Logout Confirm | 退出确认 |

---

## 04. 关键交互标注

### 登录

- 未配置时点登录 → Alert 引导「服务配置」  
- 主按钮 Loading 态：标题改为 Activity Indicator（实现）  

### 片库 SPA

- 无 Tab；右上角 36pt 圆形头像  
- 下拉刷新（标准 `UIRefreshControl`）  
- 点海报 → 全屏 Push/Cover 进 Watch  

### 我的 Sheet

- 中大 Sheet，可下滑关闭  
- 「完成」或下滑均关闭  
- 退出保留云配置  

### 服务配置

- 导航：返回 | 标题 | 保存  
- **分享与导入**分组：列表行「粘贴导入 / 分享配置」（图标 + 标题 + 副文案 + ›）  
- **分享配置**：加密徽章 → 说明 → 链接二维码 → 链接卡片（复制）→ 风险条 → 主按钮复制 / 次按钮系统分享+存相册  
- **导入配置**：绿标引导 → 虚线粘贴框 → 从剪贴板 → 继续解析  
- **确认导入**：绿 chip「加密链接已解析」+ 覆盖警告 + 脱敏卡片  

### 播放页

- 沉浸黑底；导航：返回 | 片名 | 换片 | 更多  
- 播放器顶/底工具栏：**5 秒无操作自动隐藏**；点击画面再次显示  
- **全屏**：底栏全屏按钮进入/退出；进入后自动横屏，退出回竖屏；全屏时返回先退出全屏  
- **房主可拖动进度条** Seek（全员同步）；成员进度条只读  
- 仅房主换片；成员 Toast「仅房主可切换影片」  
- 成员条：「N 人」+ 同步文案；横向头像，**外圈环形进度条**（进度 = 该成员播放进度 / 片长；轨道透明度 0.3；房主进度色为粉、成员为系统蓝）  
- 输入区贴底，避开 Home Indicator  

### 换片 / 字幕同步

- 标准 Sheet + Grabber  
- 换片保留房间与聊天  
- 字幕偏移仅本机；字幕面板分区：当前 / 内嵌 / 片库外挂 / 在线搜索 / 字幕同步  
- 字幕同步：±0.5s / ±0.1s / 重置；完成关闭  

---

## 5. 动效建议（实现）

| 场景 | 建议 |
|------|------|
| Sheet 呈现 | spring，damping ≈ 0.8–1.0，response ≈ 0.3s；可中断 |
| 按钮按下 | scale 0.97，~100ms |
| 换片 Loading | 播放器区短暂蒙层 + Progress |
| 进度校正 | 避免生硬跳帧，小偏差平滑追赶 |

遵循「按下即反馈、手势可打断、弹簧连续」（见 Apple *Designing Fluid Interfaces*）。

---

## 6. 无障碍

- 右上角头像：`accessibilityLabel = "我的"`  
- 片名换片按钮：标明「切换影片」  
- 对比度：蓝底白字、黑底白字满足常规正文对比  
- Dynamic Type：列表与聊天优先支持  

---

## 7. 交付与下一步

- Figma 文件已含 7 个主流程画板 + Cover  
- 可选增强：接入 **iOS 26 UI Kit** 的 Liquid Glass Button / Toolbar 实例替换自绘按钮；补齐「在线搜字幕」结果列表画板、导出二维码全屏页  
- 开发对照：本文件 + PRD + Figma 三者一致后再开 SwiftUI 骨架  

**Figma：** https://www.figma.com/design/5wmtldOSN7EznnnpjIRDnD  

### 已知修正（2026-07-27）

| 问题 | 修正 |
|------|------|
| 登录页「Tandem / 一起看电影」未水平居中 | Body / Brand 设置 `counterAxisAlignItems: CENTER`，标题 `textAlignHorizontal: CENTER` 且横向 FILL |
| Library 卡片列宽不齐、文案撑破 | 双列 `FILL` 等分；海报 `aspect 2:3`；标题单行省略；简介两行截断 |

本地预览（推荐，含全部页面修正）：[`design-preview/index.html`](./design-preview/index.html)  
仅登录+片库：[`design-preview/login-library-fixed.html`](./design-preview/login-library-fixed.html)  
回写 Figma 脚本：[`design-preview/figma-fix-login-library.js`](./design-preview/figma-fix-login-library.js)

