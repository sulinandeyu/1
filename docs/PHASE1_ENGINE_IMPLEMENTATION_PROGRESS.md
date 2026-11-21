# Phase 1 摄影引擎实施进度

更新时间：2026-11-20
当前分支：`codex/automatic-photography-director-v2-20261114`
实施基线：`50d545777712eafec95232d6eea617d3248c5685`

## Task 1：原图安全保存闭环

状态：**APPLE_CI_VERIFIED / DEVICE_VERIFICATION_PENDING**

已完成的代码行为：

- AVFoundation 得到有效 JPEG 后创建稳定 `captureID`，原始 JPEG 字节不重编码。
- 普通拍照在进入 `PhotoProcessingPipeline` 前，先写入 App 私有 Application Support 目录；临时文件经 SHA-256 校验后原子改名。
- manifest 独立采用临时写入、解码校验及替换；启动协调会恢复“图片已完成但 manifest 未完成”的孤立原图。
- 同一 `captureID` 和相同哈希重复暂存/保存不会创建额外副本；哈希冲突会拒绝覆盖。
- Photos 写入前持久化 `committing`。若 App 在 Photos 成功与本地 receipt 确认之间中断，重启后转为 `needsReconciliation`，在 `.addOnly` 权限下不会静默重试。
- 后期成功时仅保存通过质量检查的正式 B；后期失败时只展示和保存原图，不创建与原图相同的假 AI 成片。
- 私有暂存失败时停止 AI 后期，保留内存抢救路径，并明确说明该路径不具备跨崩溃 exactly-once 保证。
- App 重启后可发现待恢复原图，主界面提供最小恢复入口。
- `isDiagnosticImport == true` 不进入新拍摄原图暂存；诊断导入仍仅在用户明确点击保存时写入相册。
- 未自动删除任何尚未确认保存成功的原图。
- 冷启动协调与日常 UI 刷新已分离：只有 `reconcileAfterColdLaunch()` 会处理上个进程遗留的 committing；日常 `recoverySnapshot()` 只读，不会干扰当前 Photos 事务。
- manifest 损坏时保留原始损坏副本；可校验 JPEG 恢复为 `needsReconciliation`，不再自动降级为 `staged`。
- Photos 写入前重新以 manifest、capture ID、外部 receipt、待保存字节和私有暂存文件执行完整 SHA-256 交叉校验；Photos 使用重新读取的权威暂存字节。
- 已确认保存且超过 30 天的本地原图可在冷启动后清理；未保存、等待权限、保存失败、committing、needsReconciliation 均永久排除在自动清理之外。

## 状态流

`JPEG received → staged → committingToPhotoLibrary → committedToPhotoLibrary`

异常分支：

- 权限拒绝：`staged → awaitingPhotoLibraryPermission`
- Photos 明确失败：`committing → saveFailed`，原图仍可恢复
- Photos 结果未知或确认 manifest 写入失败：`committing → needsReconciliation`（启动协调后）
- 私有存储失败：`memoryOnly`，仅允许显式的当前进程抢救
- manifest 中断：扫描完整 `.jpg` 文件名、capture ID、时间和哈希后重建索引

## 修改范围

- `MasterCamera/Storage/OriginalPhotoRetentionStore.swift`：新增持久存储 actor、manifest、恢复协调、Photos 幂等提交协调器及可注入接口。
- `MasterCamera/Camera/PhotoCaptureService.swift`、`CameraManager.swift`：稳定 capture ID 和采集时间传递。
- `MasterCamera/Models/CapturedPhoto.swift`、`SaveState.swift`：retention receipt 与原图/成片分离状态。
- `MasterCamera/ViewModels/CameraViewModel.swift`：先暂存、后处理；失败保留原图；重启恢复。
- `MasterCamera/Storage/PhotoLibraryManager.swift`：正常拍照和诊断保存隔离；原图/B 独立提交和幂等状态。
- `MasterCamera/Views/CameraView.swift`、`PhotoPreviewView.swift`：最小恢复入口及原图-only 失败状态。
- `MasterCamera/Processing/PhotoProcessingPipeline.swift`：只透传 capture ID/receipt；摄影参数与正式 B 输出逻辑未修改。
- `Package.swift`、`MasterCamera.xcodeproj/project.pbxproj`：纳入新文件和纯 Swift 测试。
- `MasterCameraDecisionCoreTests/OriginalPhotoRetentionStoreTests.swift`：新增故障注入测试。

## 测试证据

已在 Apple/Swift 环境执行并通过的 **28 项** Task 1 测试覆盖：

1. 正常暂存、原始字节与 SHA-256 一致。
2. 同 capture ID 暂存幂等。
3. 后期失败后原图及重启恢复。
4. Photos 权限拒绝。
5. Photos 明确写入失败。
6. 重复点击保存、B 资产幂等及原图/B 字节原样传递。
7. 并发保存请求合并。
8. Photos 成功但 receipt 未确认。
9. Photos writer 返回未知确认状态。
10. 私有存储/空间写入失败。
11. manifest 写入中断后的孤立文件恢复。
12. 真实文件持久层跨实例字节一致。
13. 诊断导入不进入普通拍照暂存策略。
14. 延迟 Photos writer 下，日常刷新不改变正在提交的原图状态。
15. 延迟 Photos writer 下，日常刷新不改变正在提交的正式 B 状态。
16. manifest 损坏前原图已 committed 的保守恢复。
17. manifest 损坏前正式 B 已 committed 的保守恢复。
18. manifest 损坏时 Photos 正在 committing 的保守恢复。
19. 待保存原图字节与 manifest 哈希不一致时拒绝 Photos 写入。
20. 伪造 capture ID/receipt 不能绕过权威 manifest。
21. 私有暂存 JPEG 损坏时拒绝标记保存成功。
22. 自动清理只删除过期且已确认提交的本地原图。
23. 损坏 manifest 副本及原始 JPEG 均被保留。
24. 等待授权及正式 B 待协调状态的本地原图不会被自动清理。
25. 同 capture ID、不同原图 SHA-256 的并发请求不会共享 active save。
26. 同 capture ID、不同正式 B SHA-256 的并发请求不会共享 active save。
27. 已确认 Photos 原图清理本地缓存后不会重建原图资产，且仍可保存正式 B。
28. 未提交原图缺少私有暂存文件时仍严格拒绝 Photos 写入。

Windows 当前验证：

- `git diff --check`：通过（仅存在工作区行尾提示，无空白错误）。
- Xcode 工程已引用新增 Swift 文件。
- 禁止修改的摄影决策、分析、Core Image 参数文件没有本轮差异。
- 当前 Windows 环境没有 `swift` / `xcodebuild`；本地未将静态检查冒充 Apple 验证。
- `.github/workflows/ios-build.yml` 无需改动，已实际运行 `swift test` 和 iOS Simulator `xcodebuild build`。

Apple CI 真实证据（2026-11-20）：

- Git 提交：`29b63082616f71e2a216f73a80a23c9b684e4c62`。
- GitHub Actions：`iOS Build #121`，run ID `44723230359`，<https://github.com/sulinandeyu/1/actions/runs/44723230359>。
- `OriginalPhotoRetentionStoreTests`：28 项通过，0 失败。
- 完整 `swift test`：137 项通过，0 失败。
- 两项最终边界：同 capture ID 数据身份冲突的并发请求拒绝测试通过；已确认原图清理本地缓存后不重复创建 Photos 原图、仍可保存正式 B 的回归测试通过。
- iOS Simulator：`xcodebuild build` 完成，日志结果为 `BUILD SUCCEEDED`。
- 该证据仅支持 `APPLE_CI_VERIFIED`；没有执行真实 iPhone、锁屏、低存储或强制终止验收，不能标记为 `DEVICE_VERIFIED`。

## 尚待 iPhone 验证

- 真机验证 Data Protection、低存储、强制终止、重启恢复、权限拒绝和连续点击保存。
- 使用真实拍照验证原始 JPEG 哈希、正式 B 像素与基线一致。
- `.addOnly` 下的 `needsReconciliation` 用户提示流程；不扩大照片读取权限。

## 对正式 B 的影响

正式 B 的摄影决策、参数、Core Image 算子和质量门槛未修改。管线只增加 capture ID 与 retention receipt 的透传。正式 B 像素不变仍需 Apple 环境回归测试确认，当前不能声称已真机通过。

## 回滚边界

可按文件撤销 Task 1 修改并从 Xcode/Package 移除新增文件；App 私有目录中的既有原图和 manifest 不应随代码回滚自动删除。回滚前必须先为仍处于 recoverable/needsReconciliation 的原图保留恢复工具。

## Task 1 结束时记录的下一任务入口（历史状态）

Task 2 从 `CoreImageRenderer.swift`、`AutomaticEditingRecipe.swift` 与 `CinematicImagingEngines.swift` 的隔离渲染表达能力验证开始。不得在 Task 1 未完成 Apple 编译与真机存储验收前切换正式 B。

## Task 2-A：专业电影影调渲染表达能力

状态（2026-11-20）：

- `SOURCE_IMPLEMENTED`
- `APPLE_PIXEL_TEST_VERIFIED`
- `IPHONE_RENDER_VERIFIED = PENDING`
- `HUMAN_AESTHETIC_APPROVED = PENDING`

本轮只实现隔离诊断渲染表达能力，没有开始 Task 3 自动摄影目标选择，也没有改变正式 B 的参数、决策或正常拍照保存流程。

### 已完成源码

- `AutomaticEditingRecipe.swift`
  - 新增三通道独立七锚点 RGB 曲线，支持 identity、单调约束和显式强度。
  - HSL 从橙/黄/绿/青/蓝扩展为红/橙/黄/绿/青/蓝/紫/洋红八色域；各色域均有 Hue/Saturation/Luminance。
  - 新增阴影/中间调/高光显式色向结构；色向与亮度调整分离。
  - 所有新增字段默认 identity/neutral；现有 B 配方不设置这些字段。
  - 新增 `task2ACinematicExpression`，仅由诊断 M 入口使用。它是人工声明的渲染表达探针，不是自动摄影目标，也不读取参考 T。
- `CinematicImagingEngines.swift`
  - 新增 `ProfessionalRGBCurveProcessor`：在 extended-linear sRGB 工作链中显式转换至 encoded sRGB 执行摄影 RGB 曲线，再转换回 linear。
  - `ProfessionalHSLProcessor` 已真正执行八色域连续色相权重，保留低色度中性色 chroma guard。
  - `CinematicColorGradingEngine` 新增显式三段色彩分级：柔和亮度权重、去亮度色向、低色度/高光中性色保护；可同时表达冷阴影与克制暖高光，不使用统一冷色 LUT。
- `CoreImageRenderer.swift`
  - 在七段亮度曲线之后接入独立 RGB 曲线；HSL 和三段分级随后进入同一全分辨率 Core Image 链。
  - Task 2-A 手动诊断使用显式 `extendedLinearSRGB + RGBAh` 工作合同并编码为 sRGB JPEG。
  - Task 2-A 只复制 EXIF/GPS/IPTC/TIFF 等非色彩元数据，不把原输入 ICC 重新附到 sRGB 像素；正式 B 仍保留既有 context/编码方法，避免未经基线验证改变正式成片。
  - 新增红通道曲线、洋红 HSL、冷阴影/暖高光单参数探针与结构化执行模块记录。
- `ProcessingConfiguration.swift`、`PhotoProcessingPipeline.swift` 既有 M 链
  - 诊断导入的 M 现在使用 Task 2-A 人工表达参数；仍经过全分辨率真实渲染、区域执行回执和既有技术质检，不替换 B/D/V2。
- 真机诊断准备
  - `CameraView.swift` / `CameraViewModel.swift` 增加按顺序选择 A、T 的本机 Task 2-A 入口。
  - 只有 A 进入 `PhotoProcessingPipeline`；T 只在处理结束后交给本地证据导出器，不能影响分析、参数、蒙版或像素。
  - `DiagnosticBundleExporter.swift` 导出 A、正式 B、M/R-I、用户明确选择的本地 T、参数/质检/设备/Git 证据以及 `task2a-comparison.html`。T 不进入 App 资源、公开仓库或 CI。

### 色彩与执行合同

- 既有七段亮度曲线保留原来的 extended-linear sRGB 工作域数学，避免本轮改变正式 B；新增 RGB 曲线、八色域 HSL 与三段色彩分级才在 encoded-sRGB 感知域求值，并在各自算子边界显式完成线性/编码转换。

`输入 JPEG/HEIC（读取 orientation/ICC） → 方向标准化 → extended-linear sRGB → 动态范围/亮度曲线 → encoded-sRGB 定义的 RGB 曲线（输出回 linear） → 白平衡/全局颜色 → encoded-sRGB 八色域 HSL（输出回 linear） → 三段色彩分级 → 可靠语义蒙版区域调整 → 细节/镜头 → sRGB JPEG`。

普通 JPEG/HEIC 不使用 Log 视频 LUT。本轮没有新增 3D LUT。区域处理继续依赖现有真实蒙版及羽化；蒙版不可用时明确跳过该区域，不伪造执行。

### A/T 本地证据状态

已确认本地文件真实存在（未加入 Git）：

- `output/inverse_solver/autumn_street/A_source.jpg`，SHA-256 `7A6C4F182538C5C5FB7A3F3C090E034CF13F47D6A83595D51C15D5DE96220402`
- `T_target_original.jpg`，SHA-256 `B5944CDA017CA89E3DA4D5691B331EF37B0B0044FF1ACCA34CF2E53CDBC53F59`
- `T_target_registered.jpg`，SHA-256 `ED8DD35913ACB0167B07F516C7F20B8507BFC33B72F8855718F4B0EBF77EFE60`

Windows 无法执行 Apple Core Image，因此本轮没有生成并冒充 R-I。真实 R-I 必须由后续 Apple/iPhone 运行产生。

### Apple 像素测试证据

- `MasterCameraDecisionCoreTests/CinematicRenderingPixelTests.swift`：数学审查后扩展为 11 项 macOS Core Image 像素测试，覆盖正式配方新增控制保持 identity、像素 identity、RGB 曲线锚点间 identity/单调性、八色域 HSL lightness 的色相/饱和稳定性、extended-linear 超范围高光残差、1024 级梯度断层、冷阴影/暖高光、高光肩部/暗部方向和局部蒙版。旧五色域继续使用 legacy HSV-value，Task 2-A 显式使用 perceptual HSL，避免改变正式 B。
- `MasterCameraAppTests/CoreImageRendererHostedTests.swift`：5 项 app-hosted 测试，覆盖真实 renderer 的尺寸/方向/RGB 输出、Task 2-A 全分辨率及模块回执、P3 输入不被错误作为输出 ICC 重新附着、重新解码色差、A/T 实际编码扩展名和无可靠蒙版时区域明确跳过。
- Xcode 工程新增 `MasterCameraAppTests` target；共享 scheme 与 `iOS Build` 工作流已准备动态选择可用 iPhone Simulator 并执行 `xcodebuild test`。
- GitHub Actions `iOS Build #126`（run ID `44861631662`，<https://github.com/sulinandeyu/1/actions/runs/44861631662>）在提交 `4d3dfa6f934bf697621dff6c116e84e240401db5` 上实际运行：完整 `swift test` 148/148 通过，其中 `CinematicRenderingPixelTests` 11/11；iOS Simulator app-hosted `CoreImageRendererHostedTests` 5/5；最终 Simulator build 为 `BUILD SUCCEEDED`。
- 首轮 CI 暴露并修复了区域调色 `traceSummary` getter 的漏 return；后续 CI 发现原 HDR 测试色块被输入构造先钳为 1.0、8-bit 采样抹平小幅阴影变化，已改用真实 `.RGBAf` extended-linear 输入和 Float 像素采样，没有降低断言或画质阈值。
- 上述证据支持 `APPLE_PIXEL_TEST_VERIFIED`，但它仍不是 iPhone、性能或摄影审美证据。

### 正式 B 隔离

- 新字段的默认值严格为 identity/neutral，现有正式配方没有启用。
- 正式 B 仍使用原有 `CIContext` 与 `metadataPreservingJPEG`；Task 2-A 的半浮点工作格式和安全 ICC 输出合同只在 `renderManualEdit` 诊断路径启用。
- 没有修改 `PhotographyDecisionEngine`、`AutomaticPhotographyDirectorV2`、正式 B 参数、质量阈值、Task 1 存储机制或正常照片保存逻辑。

### 下一步（本轮不执行）

Apple 像素验证已经完成。后续仍需 TestFlight 明确授权，才能在真实 iPhone 选择 A/T、生成 R-I、导出 A/T/R-I，并由人工检查冷暖、黑位、道路纹理、黄绿分离、空间深度、中性色和蒙版边缘。未完成这些步骤前不得标记 `IPHONE_RENDER_VERIFIED` 或 `HUMAN_AESTHETIC_APPROVED`。

## Task 2-B：真实摄影成片证据闭环

状态（2026-11-21）：

- `SOURCE_IMPLEMENTED`
- `APPLE_PIXEL_TEST_VERIFIED`
- `IPHONE_RENDER_VERIFIED = PENDING`
- `HUMAN_AESTHETIC_APPROVED = PENDING`

本阶段没有新增摄影风格、没有进入 Task 3，也没有改变正式 B。它只补全 Task 2-A 隔离 M/R-I 候选从“声明参数”到“实际像素、区域影响、技术安全和人工审片”的可追溯证据。

### 已完成的证据闭环

- M/R-I 仍由 `PhotoProcessingPipeline.evaluateManualCandidate` 调用生产 `CoreImageRenderer.renderManualEdit` 生成全分辨率 JPEG；A 是唯一渲染输入，T 只在用户明确选择后交给本地导出器。
- 候选记录分别保留 planned、executed、rejected、fallback、unavailable；只有存在真实预览且阶段匹配时，导出器才写入 `M_manual_render.jpg`。
- 实际执行证据增加输出影调分区（shadow/midtone/highlight/black/white）、对比度、饱和度、中性色覆盖/色度/冷暖偏移、肤色覆盖/色差/暖偏和区域蒙版影响；这些字段来自渲染后 `QualityCheckService` 重新测量，不是计划参数。
- `task2a-comparison.html` 以原始比例提供 A/B/T/R-I 放大对照，显示执行状态、技术质检与参数来源；人工状态默认且强制为 `pending_human_review`，仅允许人工导出 reached / partially_reached / not_reached / pending_human_review。
- ZIP inventory 记录每个真实文件的 SHA-256、编码 UTI、尺寸、方向、色彩模型/配置；A/T 使用实际编码扩展名。T 不存在或 R-I 未执行时只记录 unavailable，不使用 A、B 或旧预览顶替。
- macOS Core Image 11 项测试与 iOS app-hosted 5 项测试覆盖 RGB 曲线、八色域 HSL、三段色彩分级、高光残差、中性色、区域蒙版、JPEG/ICC/方向及真实 renderer 模块回执。它们是技术像素证据，不是摄影审美结论。
- Task 2-B 最终源码提交 `6392953114d4e5f1f1468c2ce6e91b5861227f9c` 已由 GitHub Actions `iOS Build #127`（run ID `44863011941`，<https://github.com/sulinandeyu/1/actions/runs/44863011941>）复验：完整 `swift test`、app-hosted Core Image 测试和 iOS Simulator build 三个步骤均成功。

### 仍需真实设备完成

- 在 iPhone 上选择本地 A/T，生成全分辨率 R-I，并导出同次运行 A/B/T/R-I 与执行证据。
- 核对设备型号、iOS、真实耗时和内存；macOS/Simulator 数据不得冒充 iPhone 性能。
- 由用户检查道路纹理、冷暖层次、黄绿分离、天空/白色车辆中性色、人物 100% 纹理与蒙版边缘；未评价前审美状态保持 pending。

## Task 2-C：内部 TestFlight 与真实 iPhone A/T/R-I 验证

状态（2026-11-21）：

- `INTERNAL_TESTFLIGHT_READY`
- `IPHONE_RENDER_VERIFIED = PENDING`
- `HUMAN_AESTHETIC_APPROVED = PENDING`

发布事实：

- 发布源码固定为分支 `codex/automatic-photography-director-v2-20261114` 的 `a0a7931057a58c35000c2a672e47bf114e83f925`；它与成功的 Apple CI `iOS Build #128` 完全一致。
- `TestFlight Release #51`（run ID `44865402355`，<https://github.com/sulinandeyu/1/actions/runs/44865402355>）使用版本 `1.0`、Build `38` 完成 Release archive、签名、IPA 导出与一次正常上传；上传日志为 `UPLOAD SUCCEEDED`。
- `TestFlight Release #52`（run ID `44865759191`，<https://github.com/sulinandeyu/1/actions/runs/44865759191>）只执行状态核验：App Store Connect `processingState=VALID`、`internalBuildState=IN_BETA_TESTING`、内部测试组数量为 1，因此 Build 38 已可供现有内部测试组安装。
- Release 中保留正式 B、Task 1 原图保留和普通拍照路径；Task 2-A 按钮只处理用户本机选择的 A，并将 T 作为本地 ZIP 的独立评价参考。私人 A/T、诊断 ZIP、`output/` 和工作区未跟踪资料均未提交或上传到 GitHub。

真实 iPhone 验收仍必须由产品负责人完成：安装 Build 38，在相机主界面底部选择“Task 2-A：依次选择 A、T 并生成本机 R-I”，按顺序选择 A、T；处理完成后通过系统分享表保存诊断 ZIP。ZIP 应包含 A、正式 B、T、真实 M/R-I、参数生命周期、区域实测、技术质检、设备/版本/Git 信息及 `task2a-comparison.html`。R-I 缺失、OOM、质量拒绝或蒙版跳过时必须保留失败证据，不得用 A/B 顶替。

## 正式 B 测量驱动自动摄影接线（PT-PRODUCTION-001）

状态（2026-11-21）：

- `SOURCE_IMPLEMENTED`
- `WINDOWS_STATIC_CHECK_PASSED`
- `APPLE_COMPILE_AND_TEST = VERIFIED`
- `APPLE_FORMAL_B_PIXEL_VERIFIED = VERIFIED_ON_SYNTHETIC_APP_HOSTED_INPUTS`
- `IPHONE_NORMAL_CAPTURE_VERIFIED = PENDING`
- `HUMAN_AESTHETIC_APPROVED = PENDING`

本轮已获授权改变正式 B 的自动摄影决策与渲染接线，但没有上传 TestFlight、没有提交/推送，也没有改动 Task 1 原图安全保存。

### 已完成源码

- `PhotographyTargetProfile.measuredProduction` 只从当前照片的曝光、低色度环境、暖色重点、可靠区域、混合光、噪声及人物证据选择“测量自然”或“测量冷暖分离”目标；不读取场景固定参数、参考 T、图片哈希或反求答案。
- `PhotoProcessingPipeline.process` 的正式 B 现在把 `StructuredPhotographyDiagnosis` 与 production target 传入 `PhotographyDecisionEngine`，并启用现有 `AestheticPhotographyPlanner`、`AdaptivePhotographyParameterSolver` 与 `AdaptiveRegionalTonePlanner`。
- 低分辨率候选、最终全分辨率渲染、一次质量反馈重渲染、阶段预览和诊断回执均传递同一 `adaptiveRegionalTonePlan`，不再出现“计划已记录但区域像素未执行”的接线断点。
- `AdaptivePhotographyParameterSolver` 在当前图证据支持时生成 perceptual 八色域 HSL、独立 RGB 七锚点曲线及显式阴影/中间调/高光色彩分级；显式三段分级启用后关闭旧分级，避免重复应用。人物证据存在时这些全局颜色表达保持 identity/neutral，继续只允许安全摄影影调。
- 场景分类失败或不确定不再自动等于弱调色：当中性色或可靠区域像素证据存在时保留测量驱动决定；没有独立像素证据时仍执行安全降级。
- 候选“保真”评分不再把接近原图本身当成主要奖励；真实裁切、中性色、人物、细节和区域风险继续由未降低阈值的 `QualityCheckService` 排除。
- 参数证据已覆盖专业 RGB/HSL/三段分级实际值，并关联稳定规则 `PT-PRODUCTION-001`。

### 本轮验证边界

- `git diff --check` 通过；Windows 当前没有 Swift/Apple Core Image 运行时，不能执行 `swift test`、iOS Simulator 或真实 Core Image。
- 新增 Swift 决策测试覆盖：有充分当前图证据时选择测量冷暖分离并产生 RGB/HSL/三段分级和区域计划；证据不足时选择测量自然；人物关闭全局颜色表达；规则来源可追踪。
- 新增 app-hosted 正式 B 端到端像素测试：第一项从非诊断 `CapturedPhoto` 直接运行 `PhotoProcessingPipeline.process`，要求候选选择、最终配方、区域计划和重新渲染像素一致；第二项使用无场景标签但具备可靠地面/植被测量的合成照片，要求 `PT-PRODUCTION-001` 选择测量冷暖分离、动态区域计划非空且真实改变 Core Image 像素。测试输入为代码生成的合成图，不含私人照片，也不代表摄影审美通过。
- 历史 Apple CI 只证明 Task 2-A/2-B 算子本身可运行，不能证明本轮正式 B 新接线已经编译或产生正确成片。
- 秋季道路及其他场景尚未由本轮源码重新产生 Apple Core Image 正式 B；因此没有新图片可被诚实地标记为摄影改善证据，审美结论保持 `PENDING`。

### Apple CI 首次正式 B 验证（2026-11-21）

- 源码提交 `948aa94329628d4c4bf8ff62ebea680f0f510b0e` 触发 `iOS Build #129`（run ID `44887859318`，<https://github.com/sulinandeyu/1/actions/runs/44887859318>）。150 项 Swift 测试中 149 项通过；唯一失败是历史契约 `testRecognitionFailureKeepsMeasuredMaskBackedRegions` 同时要求保留可靠蒙版区域又要求 HSL 完全 neutral，与本轮“场景标签失败但可靠像素证据仍可驱动有界颜色调整”的规则冲突。没有删除测试或降低画质阈值，而是把断言改为验证 perceptual HSL 的绿色调整必须为正、且饱和度/明度均不超过 `0.03`，红/蓝仍保持 neutral；相邻的无可靠证据降级测试保持不变。
- 修复提交 `49ed45b4a4b674f90fa3bce98649847351773642` 通过 `iOS Build #130`（run ID `44888093794`，<https://github.com/sulinandeyu/1/actions/runs/44888093794>）：完整 `swift test` 150/150，包含 macOS `CinematicRenderingPixelTests` 11/11；iOS Simulator app-hosted `CoreImageRendererHostedTests` 7/7；最终 Simulator build 为 `BUILD SUCCEEDED`。
- 两项新增 app-hosted 正式 B 测试均真实执行 Core Image：`testFormalBPipelineRendersTheRecordedFinalRecipe` 从非诊断 `CapturedPhoto` 运行完整 `PhotoProcessingPipeline.process`，确认正式候选已选择、`PT-PRODUCTION-001` 证据存在、最终 B 与记录配方/区域计划复渲染一致且没有在候选选择后被清零；`testFormalBMeasuredRegionalPlanChangesRenderedPixels` 在没有场景标签、但具有可靠地面/植被测量时选择 measured-color-separation，并证明动态区域计划相对同配方的全局-only 渲染产生可测像素差异和 `executed` 回执。

### 近中性与弱调色偏好审查结论

- `measured-natural` 仍会在暖色重点 `< 0.34`、低色度环境 `< 0.22`、可用区域少于 2 个或综合色彩分离证据 `< 0.34` 时选择。这不是强制 neutral：曝光、端点、影调曲线和可靠局部关系仍由当前图测量求解；但若照片本身没有可测技术问题且没有可靠区域/颜色证据，结果可以合理地接近原图。当前尚无真实 iPhone 跨场景证据证明这些门槛不会过度选择自然目标。
- 候选选择已不再对小像素差异给额外奖励；`preservationScore` 只对超过安全包络的大幅全图位移、技术问题和色彩完整性风险扣分，未达到问题改善且没有区域审美进展的候选会被额外扣分。合成 app-hosted 测试证明最终选中配方未被清零，但不能证明真实照片上工程代理一定选中最美候选。
- 质量反馈只在首轮技术质检 `failed` 时触发，并只在一次修正版的技术状态更好时采用；真实损伤仍会拒绝输出。颜色/人物/中性色问题会有界收回相关参数，因此可能削弱初始摄影表达，但不会因“与原图差异大”单独触发。是否在秋季道路、建筑或人物上过度收回，仍须正常快门真机证据核对。

### 下一次正常拍照取证条件

工程条件已具备：正常 `CameraView → PhotoProcessingPipeline → measuredProduction → PhotographyDirector/solver → 候选 → 全分辨率 Core Image → 质量反馈 → 正式 B` 已通过 Apple 编译和合成像素验证。下一步必须在真实 iPhone 正常快门链记录 A/B、自动方向、候选分数/拒绝原因、初始与最终配方、RGB/HSL/三段分级、区域执行及质量反馈，并先复验秋季道路，再验证至少两类不同场景。私人样片不得上传公开 CI；在取得真实成片与用户审片前，专业摄影审美仍为 `PENDING`。

### 下一验证入口（本轮不执行）

Apple CI 已完成。下一阶段只需用同源秋季道路、建筑、阴天植被与人物在真实 iPhone 正常快门链生成正式 B，检查道路/植被层级、中性色、肤色、暗部、高光和蒙版边缘。只有用户实际审片认可后才能标记摄影审美通过。

## 正式 B 正常快门内部 A/B 取证（2026-11-21）

当前状态：

- `SOURCE_IMPLEMENTED`
- `APPLE_CI_VERIFICATION = VERIFIED`
- `INTERNAL_TESTFLIGHT_READY = VERIFIED_BUILD_39`
- `IPHONE_NORMAL_CAPTURE_EVIDENCE = PENDING`
- `HUMAN_AESTHETIC_APPROVED = PENDING`

本轮只补齐正常快门正式 B 的内部取证缺口，没有修改摄影分析、参数求解、Core Image 渲染、质量阈值、Task 1 原图保存或 Photos 保存行为。

- `PhotoPreviewView` 的成片信息面板在显式 `XIAOSU_INTERNAL_CAPTURE_EVIDENCE` 编译条件下，为非诊断且处理完成的正常快门照片显示“导出本次正常拍照 A/B 取证 ZIP”。普通 Release 不编译该按钮；不能用 `DEBUG` 误开 TestFlight 功能。
- `DiagnosticBundleExporter.makeProductionCaptureArchive` 直接封装该 `CapturedPhoto` 已持有的 A 原始字节和正式 B 实际字节，不重新分析、不重新渲染、不调用 Photos 保存。ZIP 记录同一 capture ID、A/B SHA-256、最终目标、完整 RGB 曲线、八色域 HSL、三段分级、区域计划/执行回执、候选评分与选择依据、质量回退、阶段耗时、Git/build/设备/iOS。
- 正常快门包不生成或包含 M、V2、T 等研究候选；只在设备临时目录生成，由用户主动打开 iOS 系统分享菜单后才会离开本机。
- `testflight-release.yml` 仅对内部 TestFlight archive 显式定义该编译条件；普通 Release 配置保持无条件。`ios-build.yml` 将分别编译普通 Release 和内部取证 Release，以验证边界。
- app-hosted 回归测试已加入 capture ID、A/B SHA、ZIP 内实际字节、执行 JSON 标记以及“导出前后 B 字节不变”的检查；默认 CI 构建同时断言内部取证策略关闭。

Windows 当前没有 Swift/Xcode，无法在本机运行 Apple 测试；`git diff --check` 已通过。源码提交 `1e1279d54f72ef31dab1494e90036965544795da` 已通过 GitHub Actions `iOS Build #132`（run ID `44918084530`，<https://github.com/sulinandeyu/1/actions/runs/44918084530>）：完整 Swift 150/150（其中 macOS Core Image 11/11）、iOS app-hosted 8/8、Debug Simulator build、普通 Release build 及显式内部取证 Release build 均成功。新增 app-hosted 取证断言在正式 B 端到端管线结果上确认同一 capture ID、A/B SHA、ZIP 内逐字节 A/B、执行证据标记以及导出前后正式 B 字节不变。

同一源码提交随后由 `TestFlight Release #53`（run ID `44919066585`，<https://github.com/sulinandeyu/1/actions/runs/44919066585>）以版本 `1.0`、Build `39` 完成签名、Release archive、IPA 导出和上传。只读状态核验 `TestFlight Release #54`（run ID `44919392927`，<https://github.com/sulinandeyu/1/actions/runs/44919392927>）确认 App Store Connect `processingState=VALID`、`internalBuildState=IN_BETA_TESTING`、内部组数量 `1`，因此现有内部测试组可以安装。

尚未完成的是实际 iPhone 正常快门验收：需要分别拍摄秋季道路、室内自然光、室外风景/城市建筑，打开预览右上角信息按钮，通过“导出本次正常拍照 A/B 取证 ZIP”保存本次 A/B 与完整决策证据。未取得这些真实照片和人工审片前，`IPHONE_NORMAL_CAPTURE_EVIDENCE` 与 `HUMAN_AESTHETIC_APPROVED` 必须保持 `PENDING`。
