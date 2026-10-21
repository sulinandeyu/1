# MasterCamera 开发进度

更新时间：2026-10-21

## 当前阶段

MasterCamera 已完成 Phase 1–13 的 MVP 主链路原型，包括相机拍摄、本地照片分析、摄影决策、Core Image 自动成片、人脸局部补光、质量检查、安全回退、预览对比、相册保存状态和诊断面板。

Phase 14 TestFlight 发布链路和首轮内部真机验证均已完成。build `1.0 (4)` 已通过 TestFlight 安装；相机权限、拍照、前后摄像头切换和基础成片链路正常。真机发现默认取景倍率观感约为 1.5×、缺少倍率控制，以及自动成片偏向统一提亮、场景差异不足。当前开始修复相机倍率，随后进入场景自适应成片模块。

## 本轮完成

### 场景自适应摄影决策（本地开发，尚未推送）

- 自动成片基线改为真正中性：默认曝光、色温、饱和度、自然饱和度、降噪和锐化均不再强制增加；均衡照片允许基本不处理。
- 照片分析新增亮度分位数动态范围、暗部占比、高光占比、平均饱和度和 Vision 本地场景语义标签。
- 场景策略扩展为普通人像、逆光人像、风景、夜景、美食、建筑、日落、室内和通用场景。
- 每个场景生成独立动态审美目标及曝光、高光、阴影、色温、色调、曲线、色彩、降噪、锐化、暗角和人脸补光参数。
- 渲染器新增白平衡、动态 Tone Curve 和轻微暗角执行能力；零强度降噪/锐化会直接跳过，避免中性照片仍被改变质感。
- 质检新增相对原图的高光溢出、暗部死黑和过饱和检查。
- 新增 `docs/PHOTOGRAPHER_DECISION_SYSTEM.md`，记录三层架构、场景策略和“参考摄影原则而非复制大师风格”的技术边界。

### 人物与显著主体局部补光（本地开发，尚未推送）

- 照片分析新增 Vision 整个人物分割蒙版和基于注意力的显著主体蒙版，统一保存为轻量 8-bit 灰度数据。
- 图像引擎新增通用像素蒙版转换、边缘柔化和局部曝光混合能力。
- 局部光照顺序调整为“人物/主体小幅补光 → 人脸精细补光 → 全局色调处理”，避免背景和天空跟随人物一起升曝光。
- 修正配方最终截断范围，允许高光 `1.0` 与阴影 `0.0` 的 Core Image 真正中性值通过，确保“无需处理”的照片不会在末端被强制改动。
- 普通偏暗人像只进行轻微人物补光；逆光人像使用更明确的人物补光并保留背景高光；美食场景可使用显著主体蒙版做极轻微主体强调。
- 诊断面板新增人物/主体蒙版尺寸与最终主体、人脸补光 EV，便于真机确认蒙版方向和实际决策。

### 第一轮真机验证与相机倍率控制

- TestFlight build `1.0 (4)` 已在真实 iPhone 安装并启动。
- 拍照链路正常，前后摄像头切换正常。
- 相机配置时显式重置硬件 `videoZoomFactor` 为 `1.0`，切换摄像头后同样回到 1×。
- 取景区域由全屏裁切改为与照片一致的 4:3；避免 `resizeAspectFill` 在细长屏幕上裁掉画面两侧，造成硬件 1× 看起来接近 1.5×。
- 相机页底部新增 0.1× 步进的倍率滑杆，范围为 1× 到设备能力上限（产品侧最高限制为 5×）。
- 当前倍率和设备可用上限由 `CameraManager` 发布并同步至 `CameraViewModel`，避免 UI 显示值与真实硬件倍率脱节。

### TestFlight 真实签名接入

- 已注册显式 App ID `com.sulinandeyu.mastercamera` 并创建对应的 App Store Connect App 记录。
- 已创建 Apple Distribution 证书与 `MasterCamera AppStore` Provisioning Profile；本地验证 Team ID、Bundle ID、证书公钥和有效期全部匹配。
- 已创建 Developer 权限的 App Store Connect Team API Key，并验证 `.p8` 私钥格式。
- GitHub 仓库已配置 workflow 所需的 7 个 Repository Secrets。
- `TestFlight Release #2` 已通过 Secrets、P12、API Key 和 Provisioning Profile 安装及一致性检查。
- 首次 Archive 暴露工程自动签名默认选择 `iOS Development`；发布 workflow 现已明确覆盖 `CODE_SIGN_IDENTITY=Apple Distribution`。
- `TestFlight Release #3` 已成功使用 Apple Distribution 证书和 App Store Profile 完成编译签名，但 Archive 校验发现自定义 `Info.plist` 缺少标准 Bundle 元数据。
- `Info.plist` 已补齐 Bundle Identifier、可执行文件、版本、包类型、启动配置和 iPhone/iPad 支持方向，以满足归档与后续 App Store 校验。
- `TestFlight Release #4` 已成功完成 Archive、Export IPA 和 App Store Connect 上传，build number 为 `4`。

### TestFlight 签名材料预检

- 发布前检查 7 个必需 GitHub Secrets 是否存在，但不输出任何 Secret 内容。
- Provisioning Profile 解码后检查 Bundle ID 和 Team Identifier 是否与发布配置一致。
- 发布日志会显示 Profile 名称和过期时间，便于定位失效材料。
- `.p12` 导入过程继续作为证书内容和密码的实际校验。

### TestFlight 自动 build number

- `TestFlight Release` 默认使用 GitHub Actions `run_number` 覆盖归档的 `CURRENT_PROJECT_VERSION`。
- workflow 支持可选的纯数字 build number 手动覆盖，以兼容 App Store Connect 中已经存在的更大编号。
- 发布开始前会验证 build number，并在日志中输出 Bundle ID 和最终编号。
- 发布文档已补充自动编号、手动覆盖和重新运行规则。

### AppIcon 与资源目录

- 新增 `Assets.xcassets`，并将其加入 MasterCamera target 的 Resources Build Phase。
- 新增 Xcode 16 通用 iOS AppIcon set，提供不透明的 1024 × 1024 App Store 主图。
- Debug 和 Release 配置均指定 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。
- 图标采用无文字的镜头光圈与冷暖光线视觉，避免系统裁切前预制圆角。

### 照片处理错误传播

- `PhotoProcessingPipeline.process` 改为抛出分析、初次渲染和初次质量检查错误，不再静默返回原始照片。
- `CameraViewModel` 捕获处理错误、结束处理状态并向相机页显示中文错误信息。
- 处理失败时不再进入预览页，也不会把未经处理的原图标记为“AI 成片”。
- 如果初版成片已经生成，但安全回退渲染失败，保留带质量诊断的初版成片，而不是丢弃整个处理结果。
- 用户重新拍照时会清除上一次处理错误，避免旧错误遮罩干扰新的拍摄流程。

## 验证记录

- `git diff --check`：通过。
- 处理管线调用点检查：通过，当前唯一调用点已显式处理抛出的错误。
- Xcode 工程引用检查：通过，修改的两个 Swift 文件仍在 Sources Build Phase 中。
- AppIcon 文件检查：1024 × 1024、24-bit RGB、不含 Alpha 通道。
- Asset Catalog JSON 解析检查：通过。
- AppIcon target 引用检查：通过，已进入 Resources Build Phase，Debug/Release 均指定 `AppIcon`。
- GitHub Actions `iOS Build #5`：通过；提交 `e14739e` 已完成 iOS Simulator Debug 构建。
- GitHub Actions `iOS Build #8`：通过；提交 `31a1a0f` 的签名预检 workflow 修改未影响应用编译。
- `TestFlight Release #1`：预检按设计失败；仓库尚未配置 7 个必需 GitHub Secrets，因此归档、导出和上传均被安全跳过。
- `TestFlight Release #2`：签名材料安装与 Profile 一致性检查通过；Archive 因 Xcode 默认查找 `iOS Development` 证书失败，已定位并修复为明确使用 `Apple Distribution`。
- `TestFlight Release #3`：Apple Distribution 编译与签名通过；Archive 因自定义 `Info.plist` 缺少 `CFBundleIdentifier` 失败，已补齐标准 Bundle 元数据。
- `iOS Build #11`：通过；补齐标准 Bundle 元数据后模拟器 Debug 编译正常。
- `TestFlight Release #4`：通过；真实 Apple Distribution 归档、IPA 导出与 TestFlight 上传全部成功。
- `iOS Build #13`：通过；真实 1×、4:3 无裁切取景和 0.1× 步进倍率滑杆已完成 iOS Simulator Debug 编译。
- 本地 Xcode 编译：当前 Windows 主机没有 `xcodebuild`；云端真实归档已通过，仍需在 iPhone 上完成真机验证。

## 重要技术决策

- 只有分析、初次渲染或初次质量检查无法完成时，整次照片处理才视为失败。
- 安全回退属于质量优化步骤；回退失败不应覆盖或丢弃已经成功生成的初版成片。
- UI 层负责呈现处理错误，图像处理管线不再通过返回原始照片隐藏错误。
- 保持现有 MVVM、Service 和 Engine 分层，不在当前模块中同时重构配置、方向或存储系统。
- TestFlight build number 由发布 workflow 在归档时注入，工程中的默认值继续保留为本地开发基线。
- 签名材料必须在归档前完成存在性和身份一致性检查，避免在较晚的 archive/export 阶段才暴露配置错误。

## 已知问题

- TestFlight build `1.0 (4)` 已完成内部真机验证；倍率修复需要发布新 build 再次真机确认。
- 当前场景判断只使用全局曝光、对比度、色偏和人脸矩形；缺少天空、植物、建筑、食物、夜景等语义识别，无法形成足够明显的场景差异。
- 默认配方固定包含正向曝光，容易让用户感知为“只增加曝光”；需要改为真正的中性基线，并按场景生成不同的色调、局部光照、降噪和滤镜方案。
- 人像目前只有人脸区域补光和保守色彩控制，尚无皮肤区域保护、背景分离或自然肤色映射。
- Vision 通用场景标签需要使用真实样张验证准确率；语义置信度不足时会回退到曝光/对比规则，而不会强行猜测场景。
- 人物和显著主体蒙版已实现，但尚需通过新 TestFlight build 验证蒙版方向、边缘和不同设备性能。
- 天空与皮肤区域分割尚未实现；当前不使用颜色阈值伪造天空蒙版，避免蓝色衣服、墙面等区域被误判。
- 当前 Windows 环境无法直接运行 Xcode；本轮本地代码尚未推送，因此还未执行云端 Xcode 编译。
- 照片 EXIF 方向、Vision 人脸框和 Core Image mask 坐标尚未通过真机验证。
- `ProcessingConfiguration` 尚未接入分析、决策和质量检查模块，阈值仍为硬编码。
- 原图保存通过 `UIImage` 写入相册，尚不能保证原始 JPEG 字节和完整元数据不变。
- 尚无 XCTest target、单元测试或固定样张回归测试。
- 当前 Windows 环境没有 `xcodebuild`，需要通过 GitHub Actions 或 Mac 执行真实编译。

## 下一步计划

1. 编译并发布包含真实 1× 和可调倍率控制的新 TestFlight build，在同一台 iPhone 复测取景与成片视角。
2. 将自动成片的固定曝光基线改为中性基线，先消除“所有照片统一提亮”的问题。
3. 扩展本地场景分析，优先实现人像、风景、夜景/弱光三类可靠策略，并为每类建立独立配方和诊断信息。
4. 为场景策略增加固定样张回归测试，比较曝光、动态范围、噪点、肤色和饱和度，避免只凭主观滤镜效果发布。
5. 再扩展天空、植物、建筑、食物等场景；大师作品只用于抽象色调、层次和光影原则，不直接复制具体作品风格。
