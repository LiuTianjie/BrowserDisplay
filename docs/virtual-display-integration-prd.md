# PRD: Web 端虚拟显示器集成

## 1. 背景

当前 MirrorDisplay 已支持 Mac 端捕获已有屏幕或窗口，并通过 WebRTC 推送到 iPhone Safari WebViewer。现有体验更接近“远程看屏”，用户需要在 Mac 现有桌面上选择一个显示器或窗口作为画面来源。

下一阶段希望把产品体验推进到“iPhone 变成一块可用的扩展显示器”：Mac 系统中出现一块专用显示器，用户可以把窗口拖到这块显示器上，再由 WebViewer 显示和控制。

macOS 浏览器侧无法创建系统级虚拟显示器；原生 Mac 端可借助外部虚拟显示器工具实现。经调研，BetterDisplay 具备最清晰的 CLI/集成能力，适合作为 MVP 外部依赖；DeskPad 更适合作为开源技术参考，不适合作为可控外部服务；SimpleDisplay 可控性较强，但 GPL-3.0 与私有 API 风险不适合直接集成到当前产品主线。

## 2. 产品目标

### 2.1 核心目标

让用户无需购买 dummy plug，就能通过 MirrorDisplay 在 Mac 上创建一块专用虚拟屏，并在 iPhone WebViewer 中低延迟查看和操作。

### 2.2 用户价值

- 将 iPhone 临时变成 Mac 的第二块屏幕。
- 给演示、直播、远程协作提供一块干净、专用、可分享的工作区。
- 避免捕获主屏时暴露隐私窗口、通知和桌面内容。
- 为后续触控板、键盘、快捷键、激光笔等控制能力提供稳定画面目标。

### 2.3 成功指标

- 用户能在 60 秒内完成虚拟屏创建、自动选择、开始传输。
- 虚拟屏创建成功率在已安装 BetterDisplay 的设备上达到 90% 以上。
- 停止扩展屏后，MirrorDisplay 创建的虚拟屏能被可靠清理，不误删用户其他虚拟屏。
- WebViewer 端首帧时间不显著劣于捕获真实显示器。
- 用户能清楚理解 BetterDisplay 是外部依赖，而不是 MirrorDisplay 自带系统驱动。

## 3. 目标用户与场景

### 3.1 目标用户

- 想把 iPhone 临时当副屏使用的 Mac 用户。
- 需要演示专用屏幕的会议、教学、直播用户。
- 经常在移动场景下工作，但不想携带便携显示器的用户。
- 对配置容忍度较高的早期高级用户。

### 3.2 主要场景

场景 A：临时副屏

用户打开 Mac Host，点击“创建虚拟屏”，系统出现一块 MirrorDisplay 虚拟显示器。用户把聊天、文档或调试窗口拖过去，iPhone Safari 打开 WebViewer 后观看。

场景 B：演示专用工作区

用户在虚拟屏上准备演示内容，WebViewer 或投屏设备只显示虚拟屏，主屏上的通知、笔记、控制窗口不会被暴露。

场景 C：远程控制实验模式

用户在 WebViewer 上使用触控板模式控制虚拟屏中的内容，形成“屏幕 + 输入”的闭环。

## 4. 范围

### 4.1 MVP 范围

- 检测本机是否安装 BetterDisplay。
- 提供“创建虚拟屏”入口。
- 通过 BetterDisplay CLI 或 BetterDisplay app executable 创建虚拟屏。
- 为虚拟屏生成唯一名称，例如 `MirrorDisplay-<短 UUID>`。
- 等待 ScreenCaptureKit 枚举到新显示器。
- 自动选择该虚拟屏作为捕获源。
- 开始/停止传输时保留现有 WebRTC 链路。
- 提供“移除虚拟屏”入口，只移除 MirrorDisplay 创建的虚拟屏。
- 在 UI 中展示外部依赖、权限、失败原因和手动恢复指引。

### 4.2 非 MVP 范围

- 不内置 BetterDisplay 安装包。
- 不绕过 BetterDisplay 授权限制。
- 不使用私有 `CGVirtualDisplay` API 自研虚拟屏。
- 不支持 Mac App Store 分发承诺。
- 不做多虚拟屏管理。
- 不承诺跨公网连接。
- 不做完整远程桌面安全模型，仅支持局域网实验控制。

## 5. 产品体验

### 5.1 Mac Host 新增入口

在当前 Mac Host 右侧控制区域新增“扩展屏”面板。

状态分为：

- 未检测到 BetterDisplay
- BetterDisplay 未运行
- 可创建虚拟屏
- 正在创建
- 虚拟屏已就绪
- 正在移除
- 创建失败
- 清理失败

主要操作：

- 检测 BetterDisplay
- 打开安装说明
- 创建虚拟屏
- 自动选择并开始传输
- 移除虚拟屏
- 打开显示器设置

### 5.2 推荐文案

面板标题：`扩展屏实验模式`

未安装说明：

> 需要 BetterDisplay 创建 macOS 虚拟显示器。MirrorDisplay 会捕获这块专用屏幕并发送到 iPhone。

创建按钮：

> 创建虚拟屏

创建成功：

> 虚拟屏已就绪。把窗口拖到 MirrorDisplay 屏幕，然后开始传输。

风险提示：

> 这是实验功能。虚拟屏由 BetterDisplay 提供，部分能力可能受 BetterDisplay 授权或 macOS 版本影响。

### 5.3 WebViewer 体验

MVP 不需要 WebViewer 大改，但应在 toolbar 或状态层显示：

- 当前来源：`MirrorDisplay 虚拟屏`
- 连接状态
- 画质
- 全屏按钮

后续控制能力开启时，WebViewer 增加：

- 触控板模式
- 键盘按钮
- 快捷键面板
- 局部放大镜

## 6. 功能需求

### 6.1 BetterDisplay 检测

系统应按以下路径检测：

- `/Applications/BetterDisplay.app`
- 用户 Applications 目录
- `betterdisplaycli` 是否存在于常见 PATH

验收标准：

- 已安装 BetterDisplay 时，UI 显示可用。
- 未安装时，UI 显示安装指引。
- BetterDisplay 未运行但已安装时，允许尝试启动。

### 6.2 创建虚拟屏

系统调用 BetterDisplay 创建虚拟屏，推荐参数：

- 类型：VirtualScreen
- 名称：`MirrorDisplay-<短 UUID>`
- 比例：16:9
- HiDPI：开启
- 分辨率列表：1920x1080、2560x1440

示例命令：

```bash
/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay create \
  -type=VirtualScreen \
  -virtualScreenName=MirrorDisplay-AB12 \
  -aspectWidth=16 \
  -aspectHeight=9 \
  -virtualScreenHiDPI=on \
  -resolutionList=1920x1080,2560x1440
```

验收标准：

- 创建后 macOS 显示器列表出现对应虚拟屏。
- ScreenCaptureKit 能枚举到该显示器。
- MirrorDisplay 自动选择该显示器作为 capture source。

### 6.3 虚拟屏识别

系统需要维护自己创建的虚拟屏记录：

- display name
- createdAt
- provider
- optional displayID
- cleanup status

验收标准：

- 只对名称前缀为 `MirrorDisplay-` 且由本次 app 记录创建的虚拟屏执行自动清理。
- 不删除用户已有 BetterDisplay 虚拟屏。

### 6.4 自动选择捕获源

虚拟屏创建后，系统最多轮询 10 秒 `SCShareableContent`。

匹配策略：

- 优先按 display name 匹配。
- 若无法读取名称，则按创建前后 displayID 差异匹配。
- 若仍无法匹配，提示用户手动选择新增显示器。

验收标准：

- 成功匹配时自动选中捕获源。
- 匹配失败时不阻塞用户手动使用。

### 6.5 清理虚拟屏

用户点击“移除虚拟屏”或 app 退出时，尝试调用 BetterDisplay 移除由 MirrorDisplay 创建的虚拟屏。

验收标准：

- 正常移除后，capture source 回到未选中或默认状态。
- 如果清理失败，UI 给出手动清理说明。
- app 崩溃后重启，能识别上次遗留的 MirrorDisplay 虚拟屏并提示清理。

## 7. 技术方案

### 7.1 Provider 抽象

新增虚拟显示器 provider 层：

```swift
protocol VirtualDisplayProvider {
    var name: String { get }
    func availability() async -> VirtualDisplayAvailability
    func createDisplay(request: VirtualDisplayRequest) async throws -> VirtualDisplayRecord
    func removeDisplay(record: VirtualDisplayRecord) async throws
}
```

MVP 实现：

- `BetterDisplayProvider`

预留实现：

- `SimpleDisplayProvider`
- `NativePrivateVirtualDisplayProvider`
- `DummyPlugProvider`

### 7.2 与现有模块关系

建议新增目录：

- `MacHost/VirtualDisplay/VirtualDisplayProvider.swift`
- `MacHost/VirtualDisplay/BetterDisplayProvider.swift`
- `MacHost/VirtualDisplay/VirtualDisplayStore.swift`
- `MacHost/VirtualDisplay/VirtualDisplayModels.swift`

需要改动：

- `HostViewModel`
  - 新增虚拟屏状态
  - 新增 create/remove 方法
  - 创建成功后调用 `refreshCaptureSources`
  - 自动选择新 source

- `ContentView`
  - 新增“扩展屏实验模式”面板
  - 展示 provider 状态和操作按钮

- `ScreenCaptureManager`
  - 可选新增 display metadata 返回能力
  - 支持按 displayID 或名称查找新增显示器

### 7.3 命令执行

使用 `Process` 调用 BetterDisplay 或 `betterdisplaycli`。

要求：

- 命令参数必须数组化传入，不拼接 shell 字符串。
- 设置超时。
- 捕获 stdout/stderr。
- 记录失败原因但不暴露过多内部细节给普通用户。

### 7.4 本地状态存储

使用 `UserDefaults` 或轻量 JSON 保存：

- app 创建过的虚拟屏记录
- 最后一次 provider
- 是否显示过实验功能说明

不保存敏感信息。

## 8. 安全与权限

### 8.1 权限

仍需要 Screen Recording 权限，因为 MirrorDisplay 需要捕获虚拟显示器内容。

如果后续加入远程控制，需要额外引导 Accessibility 权限。

### 8.2 控制安全

虚拟屏本身不新增输入风险，但后续 WebViewer 控制会产生高风险能力。控制功能必须有：

- Mac 端确认
- PIN 或一次性 token
- 局域网限制
- 明确的“允许控制/只读观看”状态

### 8.3 外部依赖风险

BetterDisplay 是第三方 app。MirrorDisplay 不应伪装其能力为内置能力，应明确说明：

- 虚拟屏由 BetterDisplay 提供。
- 可能需要 BetterDisplay 授权。
- macOS 更新可能影响虚拟屏行为。

## 9. 竞品与参考

### 9.1 BetterDisplay

优势：

- 提供 CLI、URL scheme、HTTP、Shortcuts 等集成能力。
- 已有虚拟屏能力。
- 更接近产品级外部依赖。

风险：

- 需要用户安装。
- 部分功能可能需要 Pro。
- 版本差异需要兼容。

参考：

- https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI
- https://github.com/waydabber/betterdisplaycli

### 9.2 DeskPad

优势：

- MIT 开源。
- 使用 `CGVirtualDisplay` 创建虚拟显示器。
- 证明技术路线可行。

不足：

- 没有稳定 CLI/URL scheme。
- 启动后出现自己的窗口，不适合作为无感后台 provider。
- 基于私有 API，不适合作为短期产品主线。

参考：

- https://github.com/Stengo/DeskPad

### 9.3 SimpleDisplay

优势：

- 有 CLI 和 URL scheme。
- 支持创建、移除、重配虚拟显示器。
- 形态接近 helper。

不足：

- GPL-3.0，不适合直接复制进闭源或商业产品。
- 明确使用私有 `CGVirtualDisplay`。
- 不支持 Mac App Store。

参考：

- https://simpledisplay.app/
- https://github.com/SamuelRioTz/SimpleDisplay

## 10. 里程碑

### M1: 技术验证

目标：证明 BetterDisplay 创建的虚拟屏能被当前 ScreenCaptureKit + WebRTC 链路捕获。

任务：

- 手动安装 BetterDisplay。
- 用 CLI 创建虚拟屏。
- 验证 `SCShareableContent` 是否出现新 display。
- 手动选择该 display 并推流到 WebViewer。
- 记录 displayID、名称、分辨率行为。

### M2: Provider MVP

目标：Mac Host 内完成一键创建、自动选择、移除。

任务：

- 实现 `BetterDisplayProvider`。
- 实现状态存储。
- 实现创建后 capture source 自动匹配。
- 实现清理逻辑。
- UI 增加实验模式面板。

### M3: 产品化体验

目标：降低失败和配置成本。

任务：

- 增加安装/启动指引。
- 增加错误分级和恢复动作。
- 增加遗留虚拟屏检测。
- 增加 WebViewer 来源标识。
- 增加基础遥控入口预埋。

### M4: 控制闭环

目标：让 iPhone 不只是看虚拟屏，还能操作虚拟屏。

任务：

- WebViewer 增加触控板模式。
- Mac Host 增加 Web control message 处理。
- 使用 `CGEvent` 注入鼠标/滚动/键盘。
- 加入 PIN 配对与 Mac 端授权确认。
- 加入 Accessibility 权限引导。

## 11. 验收标准

MVP 完成时应满足：

- 在已安装 BetterDisplay 的 Mac 上，点击一次即可创建虚拟屏。
- 10 秒内自动选择虚拟屏作为捕获源，失败时有明确手动路径。
- WebViewer 能正常显示虚拟屏画面。
- 用户停止后可以一键移除虚拟屏。
- 重启 app 后能识别并清理上次遗留的 MirrorDisplay 虚拟屏。
- 不影响用户已有显示器排列和已有 BetterDisplay 虚拟屏。
- 所有失败态都有可理解文案。

## 12. 开放问题

- BetterDisplay 免费版是否足够稳定支持 CLI 创建虚拟屏，还是需要 Pro 授权。
- BetterDisplay 不同版本的 CLI 参数是否完全兼容。
- ScreenCaptureKit 是否能稳定暴露虚拟屏名称，还是只能依赖 displayID 差异。
- 虚拟屏创建后是否会改变用户窗口排列，需要怎样提示。
- 是否需要提供“只创建虚拟屏，不立即推流”的高级选项。
- 后续若自研私有 API helper，是否接受非 Mac App Store 分发路线。

## 13. 产品判断

短期不建议自研虚拟显示器。最佳路径是先把 BetterDisplay 作为外部 provider 接入，用最小成本验证用户是否真的需要“专用扩展屏”。

如果数据证明该能力是核心卖点，再评估自研 helper。届时可以参考 DeskPad 和 SimpleDisplay 的技术路线，但需要单独处理私有 API、许可证、签名、公证、系统兼容和分发策略。
