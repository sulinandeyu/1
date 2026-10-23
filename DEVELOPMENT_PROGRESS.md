# MasterCamera 开发进度

更新时间：2026-10-24

## 2026-10-24 AI Autonomous Photographer 第一阶段

- 完成新产品定位的代码级审计与五阶段实施方案，见
  `docs/AI_AUTONOMOUS_PHOTOGRAPHER_AUDIT.md`。
- 在现有决策引擎外建立 `PhotographyDirector` 系统入口；摄影决策新增最终观感、光线设计、
  分区目标和人物保护策略，实际像素执行仍由已连通的 `AutomaticEditingRecipe` 与
  `CoreImageRenderer` 完成。
- 修正人物原则冲突：所有场景与风格规则执行完毕后，强制清零人脸专属曝光；只允许在可靠
  人物蒙版内调整整个人物与背景关系，并限制人像降噪、锐化、局部对比和橙色明度改变。
- 人像质检新增脸部相对背景的亮度/色彩变化和脸部纹理能量检查；异常进入一次有边界的修正，
  修正后仍不可靠则拒绝输出 AI 成片。
- 对 7 张用户提供的真实摄影参考图完成本地数值测量；将秋季夜路、城市夜景、暖光室内和蓝调
  人像作为不同摄影语言，不把参考图混成固定预设。
- 新增决策契约测试：真实参考测量驱动夜景与工作区生成不同方案；人物场景必须满足零人脸专属
  提亮、零几何/生成式修改和皮肤纹理保护。

## 2026-10-22 场景自适应根因修复

- 用旧对话找回的清晨城市、晴天广场、阴天海边三组真实 App 对比截图做像素方向复核；
  晴天广场与阴天海边均出现绿蓝通道、饱和度和冷暖混合代理同步上升，确认“统一青蓝感”并非主观错觉。
- 找到 `semanticScene` 泛化标签优先级、公共 cinematic standard 调色下限、固定天空档位与
  最终修正版配方未回写诊断四个文件/函数级原因。
- `SceneStrategy` 改为先消费多标签 `PhotographyContext`；海岸、建筑、工作区等具体证据不再被
  `outdoor` 抢占。
- 不重写 Core Image 渲染器；只按摄影语境限制公共电影调色，并把天空参数改为依据当前图片统计连续计算。
- 新增完整分析/配方/渲染/最终配方日志，以及 Swift 决策契约测试；CI 在 iOS 构建前运行 `swift test`。
- 详细证据、数值、修复范围和真机验收方法见 `docs/SCENE_ADAPTATION_AUDIT.md`。

## 当前阶段

MasterCamera 已完成 Phase 1–13 的 MVP 主链路原型，包括相机拍摄、本地照片分析、摄影问题诊断、摄影风格与处理策略、Core Image 自动成片、人物/人脸局部补光、质量检查、安全回退、预览对比、相册保存状态和诊断面板。

Phase 14 TestFlight 发布链路和首轮内部真机验证均已完成。build `1.0 (4)` 已通过 TestFlight 安装；相机权限、拍照、前后摄像头切换和基础成片链路正常。首轮真机发现的默认取景倍率观感约为 1.5×、缺少倍率控制，以及自动成片偏向统一提亮等问题，均已在本地进入针对性修复；新的场景决策、局部处理和问题诊断代码尚未推送。

## 本轮完成

### 苹果原生逐像素皮肤蒙版（本地开发，尚未推送）

- 相机配置会查询当前摄像头支持的 `AVSemanticSegmentationMatte` 类型；支持 `.skin` 时在启动拍摄会话前启用，切换前后摄像头后重新查询。
- 每次拍摄按需请求皮肤 matte，从 `AVCapturePhoto` 读取一通道蒙版，并根据照片 EXIF 方向校正。
- 新增 `PhotoCaptureResult`，在保持 JPEG 原图不变的同时，把轻量 8-bit 皮肤蒙版传入 `CapturedPhoto`、照片分析和渲染链路。
- `SkinTextureProtectionProcessor` 优先使用逐像素皮肤蒙版；设备不支持、没有检测到皮肤或蒙版无效时，自动退回上一轮额头/双颊保护。
- 皮肤蒙版仅用于内存中的局部纹理保护，不额外写入相册，不影响原图保存。
- 诊断面板新增皮肤蒙版尺寸，可在真机判断设备是否实际提供该能力。

### 天空蒙版技术结论（本地调研）

- 苹果普通 JPEG/HEIF 拍照输出只提供人物相关语义 matte，没有通用天空 matte。
- `CIRAWFilter.semanticSegmentationSkyMatte` 只能从包含对应辅助数据的 RAW 输入中取得；并非所有设备和 RAW 照片都保证存在。
- 不采用“每次强制 RAW 只为天空蒙版”的方案，避免增加随手拍延迟、内存占用、文件体积并损失设备兼容性。
- 不采用蓝色阈值伪造天空；下一阶段需要选择许可清晰、可离线运行且真机性能合格的天空语义分割模型。

### 人像肤质保护（本地开发，尚未推送）

- 新增 `SkinTextureProtectionProcessor`，在全局降噪和锐化之后对人像肤质做独立保护。
- 保护区基于 Vision 已确认的人脸位置，只覆盖羽化的额头和双颊区域；眼睛、嘴唇与头发继续保留正常细节处理。
- 保护方式是混回部分经过曝光、色彩和曲线处理但尚未降噪/锐化的真实纹理，不做磨皮、不改变五官、不生成皮肤细节。
- 普通人像和逆光人像使用不同保护强度，并继续受配方最终范围限制。
- 诊断面板新增最终肤质保护强度，便于真机对比皮肤纹理是否自然。
- 明确不使用肤色阈值伪造皮肤蒙版；当前属于保守的人脸区域保护，逐像素皮肤语义分割仍需可靠模型。

### 独立摄影问题诊断（本地开发，尚未推送）

- 新增 `PhotoProblemDetector` 与可追踪的 `PhotoProblemReport`，把“找问题”从摄影决策引擎中拆为独立步骤。
- 当前可识别整体欠曝/过亮、高光溢出、暗部堵塞、层次偏平、反差过强、非场景性冷暖/偏绿、过饱和、暗部噪点风险和逆光主体。
- 每个问题保存严重程度与测量证据；照片没有明确问题时报告为空，系统允许不做处理。
- 处理主链路调整为“照片分析 → 问题诊断 → 摄影风格与策略 → 分区域/全局渲染 → 相对原图质检 → 等待用户保存”。
- `PhotographyDecisionEngine` 的通用曝光、对比度、白平衡、饱和度和噪点处理改为由问题报告驱动，不再重复根据原始阈值自行猜测问题。
- 场景策略执行后增加问题安全边界，避免风景、美食等风格参数重新放大已经识别的高光、过饱和或噪点风险。
- 诊断面板新增“摄影问题诊断”，可查看每个问题的严重程度和检测证据。

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

### 离线天空语义分割与分区处理（已推送并发布 TestFlight）

- 接入 Apple 发布的 `DETRResnet50SemanticSegmentationF16P6` Core ML 模型，模型采用 Apache-2.0 许可，约 32 MB，完全离线运行。
- `SkySegmentationService` 把照片缩放到 448 × 448，读取模型 `semanticPredictions` 输出中的 `sky (other)` 类别，生成逐像素 8-bit 天空蒙版。
- 增加保守有效性检查：天空占比低于 0.5%、高于 82% 或未接触顶部区域时直接跳过，避免不可靠蒙版进入成片处理。
- `PhotoAnalysis` 新增天空蒙版与画面占比；诊断面板可以显示蒙版尺寸、覆盖率和最终天空参数。
- 摄影决策只在风景、明亮户外、高反差、日落或逆光人像场景中使用可靠天空蒙版；根据高光溢出与过饱和问题动态制定天空曝光、高光和饱和度参数。
- 新增 `SkyAdjustmentProcessor`，只在羽化天空蒙版内执行克制处理，不连带压暗人物和地面；无可靠蒙版时所有天空参数保持中性。
- 新增 `docs/MODEL_LICENSES.md`，记录模型来源、用途和许可；没有使用蓝色阈值或云端图片上传。

### TestFlight build 5 启动崩溃热修复

- build `1.0 (5)` 在已完成上一版真机验证的设备上出现打开即崩溃。
- 天空 Core ML 模型只在拍照后的分析阶段延迟加载，不属于 App 启动路径。
- 本轮启动路径中唯一新增的高风险能力是相机会话启动前启用 `AVCapturePhotoOutput.enabledSemanticSegmentationMatteTypes`；该属性会触发耗时的拍摄渲染管线重配置，设备差异尚未验证。
- 热修复暂时关闭相机输出的原生 `.skin` matte 请求；已有的人脸额头/双颊纹理保护会自动接管，因此人像不会失去基本肤质保护。
- 天空分割、场景判断、问题诊断、人物/人脸补光、动态配方和质量检查均保留。
- 待 App 恢复启动并取得具体崩溃日志后，再以设备能力探测和独立实验方式重新启用原生皮肤 matte。

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
- `iOS Build #15`：通过；提交 `02f664c` 的场景决策、问题诊断、人物/人脸补光、皮肤 matte、天空 Core ML 模型和分区渲染已完成 iOS Simulator Debug 编译。
- `TestFlight Release #5`：通过；正式 Archive、IPA 导出和 App Store Connect 上传全部成功，build number 为 `5`。
- `iOS Build #20`：按预期发现 Phase 2.1 首版使用了当前 SDK 不支持的 `CIImageRepresentationOption.lossyCompressionQuality`，已恢复兼容的 Core Image JPEG 输出选项。
- `iOS Build #21`：通过；提交 `f0bd573` 的五类场景曲线、分区色彩分级、局部处理顺序、颗粒、元数据保存、处理日志和原始 Data 相册写入已完成 iOS Simulator Debug 编译。
- `TestFlight Release #8`：通过；提交 `f604da3` 已完成 Release Archive、IPA 导出与 App Store Connect 上传，build number 为 `8`，用于 Phase 2.1 七类真实样片验收。
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
- 当前已加入 Vision 通用语义标签，但场景识别和问题阈值尚未用固定真实样张集校准，误判率未知。
- 中性配方和按问题驱动的动态参数已实现，但尚未通过新 TestFlight build 验证不同场景是否真正摆脱“统一提亮”的观感。
- 支持的设备已接入逐像素皮肤 matte，不支持时仍退回额头/双颊区域；两条路径都需要真机验证方向、侧脸、多人和处理耗时。
- Vision 通用场景标签需要使用真实样张验证准确率；语义置信度不足时会回退到曝光/对比规则，而不会强行猜测场景。
- 人物和显著主体蒙版已实现，但尚需通过新 TestFlight build 验证蒙版方向、边缘和不同设备性能。
- 天空语义分割已经接入，但 32 MB 权重量化模型的首次加载时间、不同 iPhone 的 Neural Engine 性能和复杂边缘准确度仍需本轮真机验证。
- 当前 Windows 环境无法直接运行 Xcode；本轮已由 GitHub Actions 完成模拟器编译和正式 iOS Archive，运行时效果仍需真机验证。
- 照片 EXIF 方向、Vision 人脸框和 Core Image mask 坐标尚未通过真机验证。
- `ProcessingConfiguration` 尚未接入分析、决策和质量检查模块，阈值仍为硬编码。
- 原图与成片现已通过 `PHAssetCreationRequest.addResource(data:)` 直接写入相册；仍需在真机相册信息页核对不同设备照片的 EXIF 展示情况。
- 尚无 XCTest target、单元测试或固定样张回归测试。
- 当前 Windows 环境没有 `xcodebuild`，需要通过 GitHub Actions 或 Mac 执行真实编译。

## 下一步计划

1. 等待 App Store Connect 完成 build `1.0 (5)` 处理，在同一台 iPhone 真机复测真实 1×、倍率滑杆、皮肤/天空蒙版方向、处理速度和场景成片差异。
2. 建立固定原片样张回归框架，覆盖人像、逆光、风景、夜景、美食、建筑、日落和室内场景，并记录分析、问题、配方与质检结果。
3. 根据真实样张和盲评结果校准阈值；大师作品只用于抽象色调、层次和光影原则，不复制具体作品风格。
# TestFlight build 5/6 启动崩溃根因与修复（2026-10-21）

- 用户提供的 `MasterCamera-2026-10-21-091823.ips` 确认崩溃发生在主线程。
- 异常为 `EXC_BREAKPOINT / SIGTRAP`，栈顶是 SwiftUI `Normalizing.init(min:max:stride:)` 和 `Slider.init`。
- 根因是 App 首次布局时 `maximumZoomFactor` 尚为 `1.0`，代码却创建了范围为 `1.0...1.0`、步长为 `0.1` 的 Slider。iOS 26.2 会对这个无有效跨度的范围直接断言崩溃，即使 Slider 同时设为 disabled。
- 修复方式：只有在设备报告的最大倍率大于 `1.0` 时才构造 Slider；相机配置完成前显示无交互的占位轨道。
- build 6 与 build 5 包含同一个 Slider 初始化问题；上一次禁用皮肤语义蒙版与此崩溃无关。

## 人脸/背景分区测光与动态补光（2026-10-21）

- 成片质量复盘发现：已有的人脸和人物蒙版只用于渲染，而逆光判断与补光强度仍主要依赖全图平均亮度，不足以模拟摄影师对主体和背景的分开测光。
- PhotoAnalyzer 现在对 Vision 人脸框内缩后测光，并独立计算非人脸背景的平均亮度。
- 逆光人像只在“人脸明显暗于背景”且背景较亮或存在明显高光时成立，避免仅因画面同时存在暗部和高光就误判。
- 人脸和人物补光从固定数值改为根据目标脸部亮度、实测脸部亮度和人脸/背景亮度差动态计算，并保留安全上限。
- 诊断页增加人脸测光、背景测光和亮度差，便于下一轮真机样张校准。

## Phase 2.1 摄影成片效果强化（2026-10-21）

- 确认成片显示和保存链路实际使用 `editedImageData`，并非通过 UI 或低质量预览伪造差异；效果偏弱的核心是通用曲线幅度保守、没有实际色彩分级，以及局部补光在全局处理之前执行而被后续步骤削弱。
- `AutomaticEditingRecipe` 增加曲线类型、暗部冷调、高光暖调、色彩分级强度与颗粒参数，所有字段均进入实际 Core Image 像素处理。
- 色调曲线拆分为 neutral、portrait、landscape、cinematic 和 softHighlights 五种目标曲线，并按强度在恒等曲线与场景目标之间插值，避免全场景固定滤镜。
- 人像/逆光、风景、夜景、美食、建筑、日落、室内及曝光/对比降级场景均设置独立曲线与调色策略；夜景才使用轻颗粒，优秀原片不会被无条件套用重风格。
- Pipeline 调整为曝光与动态范围 → 曲线 → 白平衡 → 基础色彩 → 分区色彩分级 → 主体/人脸补光 → 天空保护 → 降噪/锐化 → 肤质保护 → 暗角/颗粒 → sRGB 全分辨率 JPEG。
- 输入读取显式应用 EXIF 方向；工作空间使用 extended linear sRGB，输出为 sRGB；AI 成片复制可用原始元数据并把已烘焙方向写为 1。
- 相册保存改为直接写入 Original 与 AI Edited 的原始 Data，避免先解码成 `UIImage` 再次压缩；原图字节与元数据可保留。
- 增加分析、决策、渲染、质检/回退和总耗时日志，并记录实际执行模块、输出尺寸、JPEG 大小和降级原因；诊断页可查看场景曲线与摄影调色参数。
- 新增 `docs/PHOTO_QUALITY_VALIDATION.md`，定义七类真实 iPhone 样片和逐项验收标准。仓库当前没有真实照片，不能把编译成功表述为摄影效果已完成真机验证。
# 2026-10-21 — MasterCamera V2 摄影级自动成片引擎专项升级（代码完成，待真机样片验收）

- 确认比较页分别读取 `originalImageData` 与 `editedImageData`，未发现 UI 将两者错误复用。
- 定位横向旋转根因：捕获连接此前没有使用设备方向设置 `videoRotationAngle`；现已接入 `AVCaptureDevice.RotationCoordinator`，并在按下快门时写入当前 horizon-level capture angle。
- 新增 `ImageProcessingDiagnosticsService`：记录原图/成片 SHA-256 短标识、编码/解码尺寸、EXIF Orientation、色彩模型/ICC、RGB/亮度/色度 MAE、变化像素比例、平均亮度、平均 RGB 和 16 档亮度直方图。
- 新增 5 倍差异可视化，以及 Original → 曝光动态范围 → 曲线白平衡 → 摄影调色 → 局部材质 → Final Edited 的逐阶段像素预览。
- 新增真实样片导入复测入口；导入文件走与真机拍照相同的分析、决策、渲染、质检和诊断流程。
- 新增独立 `workspace` 场景与室内/桌面专属 Tone Curve，强化可恢复高光、有效阴影、黑位、局部材质对比、克制的白平衡和细节处理。
- 图像引擎新增真实作用于像素的 black point 与大半径局部对比模块，模块清单会写入诊断日志。
- 4 个用户附件是对比界面截图而非原始照片；首轮观察与限制记录于 `docs/V2_REAL_SAMPLE_FINDINGS.md`。真机原始 JPEG/HEIC 复测尚待新构建。
- macOS / Xcode 的 iOS Simulator Debug 构建已在 GitHub Actions `iOS Build #26` 通过；当前提交未自动触发 TestFlight 发布。
- TestFlight Release #9 已成功完成，使用 App 构建号 9，发布提交为 `374436b`；等待 App Store Connect 完成后续处理后即可在 TestFlight 更新。
# 2026-10-21 — Cinematic Imaging Engine V3（代码完成，待真机画质验收）

- 默认成片目标升级为 CINEMATIC AUTO；新增 Natural、Standard、Dramatic 三档内部自动强度，不增加用户手动负担。
- 新增七锚点电影影调引擎，独立控制黑位、阴影卷降、低中调、中调、高中调、高光卷降和白位，并按 natural / bright / low-key 自动选型。
- 新增阴影、中间调和高光软蒙版电影色彩分级以及克制的 color contrast，替代只有冷阴影/暖高光的两段式实现。
- 新增基于可靠 Vision 人物/显著主体蒙版的空间层次处理；没有有效蒙版时自动跳过，不伪造景深。
- 新增独立镜头质感模块：高光选择性 Bloom、轻微暖色 Halation、亮度感知单色颗粒和条件暗角。
- 场景策略扩展城市街头和户外自然光；室内、工作区、人像、逆光、夜景、建筑、风景及高对比继续采用独立参数。
- V3 参数和执行模块已进入成片信息面板与逐阶段像素预览；最终仍走同一条全分辨率渲染和保存链。
- GitHub Actions `iOS Build #30` 已通过；Swift/Core Image 工程可在 iOS Simulator 目标完整编译。
- 技术说明见 `docs/CINEMATIC_ENGINE_V3.md`；真实原始样片及真机画质、耗时、内存仍待新构建验证。

# 2026-10-22 — Cinematic Imaging Engine V4（代码完成，待原始样片与真机验收）

- 基于夜间室内、夜景道路和普通客厅的六张真机对比截图开展缺陷修复；截图仅用于定位问题，不作为原始摄影样片做像素标定。
- 输入照片应用方向后统一到零原点完整画布；主要处理阶段必须覆盖原始画布，最终 JPEG 必须与解码后原图尺寸一致，否则阻止保存异常成片。
- 夜景取消强制 Dramatic，限制 Low-Key 黑位、冷阴影、暗角与局部对比，按原片暗部占比动态恢复阴影。
- Bloom 改为高阈值软蒙版隔离真实高光，缩小半径并严格限制强度；Halation 独立控制且室内默认关闭。
- 室内与工作区降低 Tone Curve、局部对比和锐化叠加，限制青色阴影偏移，保留墙面和织物的自然材质。
- 保存前质量门禁新增画布尺寸、异常黑块、高光扩散和新增青色偏移检查；严重问题触发安全配方回退。
- GitHub Actions `iOS Build #32` 已通过；六张附件为 App 界面截图，未冒充原始照片完成像素级画质验收。
