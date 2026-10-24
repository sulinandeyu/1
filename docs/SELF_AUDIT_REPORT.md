# MasterCamera 全链路自检与真实出片故障诊断

- 审计时间：2026-10-24（Asia/Shanghai）
- 审计目录：`D:\MasterCamera`
- 审计方式：只读代码审计、Git 状态检查、现有测试边界检查、参考图片只读检查、静态调用链追踪
- 约束遵守：未修改业务代码，未安装依赖，未删除、覆盖或移动任何已有文件，未调用付费 API，未触发会消耗 CI/发布资源的工作流

## 结论摘要

当前代码中，“分析 → 决策 → Core Image 像素处理 → 新 JPEG → AI 成片预览/保存”的主链路是连通的。没有发现处理完成后用原图覆盖成片、异步处理尚未完成就展示成功、AI 档固定读取原图、或显式旧成片缓存复用的当前代码路径。处理或质量检查失败时，ViewModel 显示错误；保存层还会拒绝空成片和失败质检，因此不存在已确认的“静默把原图当成功成片”路径。

但是，仓库目前仍不能证明真实出片达到目标。最关键的事实是：现有自动测试只覆盖由人工构造的 `PhotoAnalysis` 到配方的决策逻辑，明确排除了真实场景识别、Core ML 分割、Core Image 渲染、质量检查、JPEG 输出、预览和保存。用户提供的 7 张图片又不是同一拍摄的“原始文件/本 App 成片”配对，无法运行要求的真实端到端验收。

代码层面已经找到三个足以解释“成片接近原图、不同场景差异弱”的高影响因素：

1. 场景语义识别和区域分割失败会仅写日志并降级为空标签/空蒙版，流水线仍可成功；识别基于通用 Vision 标签、固定 `0.12` 阈值和英文关键字，区域模型没有置信度/不确定性输出。
2. 真实局部区域调整虽然已经接入，但数值上非常保守，并且受场景 facet、有效蒙版、人物排除条件三重限制；大量照片最终主要依赖多个场景共用的全局电影影调/调色基线。
3. 质量检查只能证明低分辨率解码像素“发生了一点变化”，不能证明变化与场景匹配或达到专业后期水平；不足变化判断使用两个条件同时成立，JPEG 重编码产生的广泛微差可能绕过拦截。

因此，当前系统更准确的定位是：**有场景决策和可控 Core Image 后期的完整原型，但真实场景识别、局部蒙版质量、场景视觉差异和专业审美质量尚未经过原始文件端到端验证。**

---

## A. 项目现状

### A.1 Git 与工作区

审计开始时：

- 当前目录：`D:\MasterCamera`
- 当前分支：`main`
- `HEAD`：`281bf65 docs: record real processing audit`
- `origin/main`：审计时与 `HEAD` 一致
- 最近代码提交：
  - `8816e96 feat: apply semantic regional photo edits`
  - `0f7c20c fix: reject ineffective photo renders`
  - `4feb64c feat: add autonomous photography director safeguards`
- 已跟踪文件没有未提交修改。
- 唯一既有未跟踪内容是 `图片/`，包含 7 张 JPEG；本次未改动这些图片。
- `git diff --check`：通过。

本报告创建后，工作区会新增一个未跟踪报告文件，这是用户明确要求的唯一写入。

### A.2 技术栈、入口和运行方式

- 平台：iOS 17+
- 语言/UI：Swift、SwiftUI
- 拍照：AVFoundation
- 人脸、人物、显著主体、通用图像分类：Vision
- 全局与局部像素处理：Core Image
- 场景区域分割：随 App 打包的 Core ML 模型 `DETRResnet50SemanticSegmentationF16P6.mlpackage`
- 保存：Photos / `PHAssetCreationRequest`
- App 入口：`MasterCamera/App/MasterCameraApp.swift:3`
- 主界面：`MasterCamera/Views/CameraView.swift`
- Xcode 工程：`MasterCamera.xcodeproj`
- Bundle ID：`com.sulinandeyu.mastercamera`

模型文件真实存在，总大小约 32.39 MB；`project.pbxproj` 将 `.mlpackage` 加入 Sources build phase，构建时应编译为 `mlmodelc`。本机是 Windows，没有 `swift` 和 `xcodebuild`，所以本次无法在本机加载 iOS Vision/Core ML/Core Image，也不能独立复现真机推理。

### A.3 文档与代码一致性

较新的 `docs/REAL_IMAGE_PROCESSING_AUDIT_REPAIR.md` 与当前主链路基本一致，也明确承认缺少原始配对素材和真机验证。

存在以下文档漂移：

- `docs/PROJECT_STATUS.md:99-105` 仍称“人脸局部曝光提升”已完成；当前最终人物保护在 `PhotographyDecisionEngine.enforcePortraitProtection` 把 `faceExposureEV` 强制为 0，因此该能力代码仍在，但正常人物决策链不会启用。
- `docs/MODEL_LICENSES.md:11` 称该模型当前只读取天空类别；当前 `SkySegmentationService` 已同时读取 ground、vegetation、water、architecture 类别。
- `docs/PROJECT_STATE.md:16` 称配方每个参数都接到像素操作，表述过强。`CoreImageRenderer` 中存在未调用的旧私有 `applyColorGrading`、`applyVignette`、`applyFilmGrain`；当前实际使用的是 `CinematicImagingEngines.swift` 中的新版实现。另外 `ProcessingConfiguration.current` 目前没有调用方。

---

## B. 真实出图流程

下面的“调用”结论来自静态代码调用关系；“本次运行证据”一栏如标为无，表示本次没有在 iOS 运行时实际执行，不能把代码存在当成真机成功。

| 阶段 | 实际调用链和输入/输出 | 静态结论 | 本次运行证据 | 降级/失败行为 |
|---|---|---|---|---|
| 1. 拍照 | `CameraView` → `CameraViewModel.capturePhoto` → `CameraManager.capturePhoto` → `PhotoCaptureService.capturePhoto`；AVFoundation 输出 JPEG `Data` 和可选 skin matte | 存在并接入 | 无 iPhone | 拍照失败回调 error |
| 2. 原图对象 | `CameraManager.swift:109-118` 用 JPEG 构造 `CapturedPhoto`；`editedImageData` 初始为空 | 存在并接入 | 静态确认 | 不会预填原图为 AI 成片 |
| 3. 后台处理 | `CameraViewModel.processCapturedPhoto` 在 detached task 中调用 `PhotoProcessingPipeline.process` | 存在并接入 | 静态确认 | catch 后显示错误，不设置成功照片 |
| 4. 解码与质量分析 | `PhotoAnalyzer.analyze` 用方向属性解码，128 长边采样统计亮度、对比、RGB、饱和度、细节/噪声代理、空间亮源 | 存在并接入 | 无 Core Image 运行 | 主图无法解码会抛错 |
| 5. 人物/主体分析 | Vision 人脸矩形、人物分割、显著主体 mask | 存在并接入 | 无 Vision 运行 | 每项失败仅日志并返回空结果 |
| 6. 场景识别 | `VNClassifyImageRequest`，保留 confidence ≥ 0.12 的前 8 项 | 存在并接入 | 无 Vision 运行 | 失败仅日志，返回空标签，流水线继续 |
| 7. 场景区域分割 | `SkySegmentationService.segmentSky` 加载 bundled Core ML，448×448 推理，生成天空/地面/植被/水面/建筑 mask | 存在并接入 | 模型文件存在；未真机加载 | 加载、推理、尺寸异常均返回 nil，流水线继续 |
| 8. 摄影问题诊断 | `PhotoProblemDetector.detect` 从数值分析生成问题列表 | 存在并接入 | 决策测试有构造数据覆盖；本机未运行 | 无单独回退 |
| 9. 后期决策 | `PhotographyDirector.direct` → `PhotographyDecisionEngine.makeDecision` → `SceneStrategy.choose`，生成 `AutomaticEditingRecipe` | 存在并接入 | 仅有构造 fixture 测试，不是图片运行 | 最终 `clamped()` 限幅 |
| 10. 像素渲染 | `CoreImageRenderer.renderAutomaticEdit` → `processImage` | 存在并接入 | 本次无法执行 Core Image | 解码、画布或编码失败抛错 |
| 11. 全局处理 | 曝光 → 高光阴影 → 黑位 → 曲线 → 七段影调 → 亮度区域 → 白平衡 → 色彩控制 → vibrance → HSL → 三段分级 | 真实像素实现已接链 | 无本次像素输出 | 部分 Core Image filter 输出 nil 时返回上一步图像 |
| 12. 局部处理 | 语义区域 → 人物/主体补光 → 人脸补光代码 → 天空 → 空间分离 → 局部对比 | 真实 mask blend 已接链 | 无 mask/边缘实测 | 人物图若无可靠 person mask，会关闭语义区域处理 |
| 13. 细节/镜头 | 降噪 → 亮度锐化 → 皮肤纹理回混 → Bloom/Halation/暗角/颗粒 | 真实像素实现已接链 | 无本次像素输出 | 人物保护会限制强度 |
| 14. JPEG 输出 | `CIContext.jpegRepresentation` 生成新 JPEG，再从“已渲染 JPEG”复制图像并合并原 EXIF；验证像素尺寸 | 处理结果是编码源，不是原图 | 无本次输出文件 | 编码/尺寸异常抛错 |
| 15. 质量检查 | `QualityCheckService.check` 对原图和成片重新分析并计算影响、异常和人物完整性 | 存在并接入 | 无本次输入输出对 | 失败最多重算一次；仍失败则抛错，不输出 AI 成片 |
| 16. 预览 | `PhotoPreviewView.displayedImage` 的 `.edited` 明确返回 `photo.editedImage`；长按才返回原图 | 未发现绑定错误 | 静态确认 | 空 edited 无图，不会回退原图 |
| 17. 保存 | `PhotoLibraryManager.savePhotos` 校验完整处理后，以 `_Original.jpg` 和 `_AI_Edited.jpg` 分别写入两个 asset | 原图和成片分离 | 无 Photo Library 运行 | 空成片或失败质检拒绝保存 |

### B.1 核心渲染顺序证据

`MasterCamera/ImageEngine/CoreImageRenderer.swift:97-145` 明确把 `PhotographyDecision.recipe` 传入以下实际 Core Image 操作：

1. 曝光、高光/阴影、黑位、基础 tone curve。
2. `CinematicToneMappingEngine` 和 `LuminanceZoneProcessor`。
3. 白平衡、色彩控制、自然饱和度、HSL、三段色彩分级。
4. `LocalAdjustmentProcessor`、`SkyAdjustmentProcessor`、空间层次和局部对比。
5. 降噪、锐化、皮肤纹理保护和镜头特征。
6. 以处理后的 `finished` 作为 JPEG 编码输入。

因此，“参数只停留在 JSON/日志，完全没有进入像素处理”的假设与当前代码不符。

### B.2 最终输出链路证据

- `CapturedPhoto.swift:31-35`：未处理对象的 `editedImageData` 是空 `Data`，不是原图副本。
- `PhotoProcessingPipeline.swift:142-153`：返回对象的 edited 明确来自 `finalEdit.data`。
- `CameraViewModel.swift:127-140`：只有 pipeline 成功后才把 `processedPhoto` 赋给预览；失败只显示错误。
- `PhotoPreviewView.swift:128-134`：AI 档返回 `editedImage`，原图档返回 `originalImage`。
- `PhotoLibraryManager.swift:8-13`：空成片或不完整处理无法保存。
- `PhotoLibraryManager.swift:33-52`：原图 bytes 与成片 bytes 分别写入两个相册资源。

没有发现显式图片缓存、缓存 key、旧任务结果复用或先展示后处理的实现。不能排除 Photos/SwiftUI/iOS 系统层面未经真机复现的显示问题，但当前源码不支持“前端固定展示原图/旧图”这一根因。

---

## C. 功能真实性矩阵

状态定义沿用任务要求：

- **A**：已实现、实际调用并有执行证据。
- **B**：已实现，但未接入当前出图链路。
- **C**：只有接口、参数、注释或占位。
- **D**：当前项目没有实现。
- **E**：实际运行情况无法确认。

由于本次 Windows 环境无法运行 iOS/Core Image/Vision，像素能力即使代码已接链，仍不能虚构为 A；因此使用 E，并在“代码状态”中说明已接入。

| 功能 | 状态 | 代码状态与证据 |
|---|---:|---|
| 场景通用分类 | E | `PhotoAnalyzer.classifyScene` 已接入 Vision；本次无实际标签/置信度输出 |
| 人脸检测 | E | Vision 人脸框已接入；本次无运行结果 |
| 人物分割 | E | `VNGeneratePersonSegmentationRequest` 已接入；本次无真实 mask |
| 显著主体 | E | Vision attention saliency 已接入；本次无真实 mask |
| 天空/地面/植被/水面/建筑分割 | E | Core ML 模型及类别映射已接入；真实误分率、边缘和耗时未验证 |
| 场景驱动参数决策 | E | `SceneStrategy` 和 `PhotographyDecisionEngine` 已接入；现有测试只覆盖人工 fixture，未覆盖图片识别到最终像素 |
| 曝光/亮度 | E | `CIExposureAdjust`、`CIColorControls` 已在 `processImage` 调用；无本次像素运行证据 |
| 白平衡/色温/色调 | E | `CITemperatureAndTint` 已接链；无本次像素运行证据 |
| 高光/阴影 | E | `CIHighlightShadowAdjust` 与亮度蒙版已接链；无本次像素运行证据 |
| 对比度/黑位/曲线 | E | ColorControls、ColorPolynomial、CIToneCurve 和电影影调已接链；无本次像素运行证据 |
| HSL | E | `ProfessionalHSLProcessor` 已接链；无本次像素运行证据 |
| 三段色彩分级 | E | `CinematicColorGradingEngine` 已接链；无本次像素运行证据 |
| 天空局部调整 | E | `SkyAdjustmentProcessor` 以 sky mask 做曝光、高光、饱和度 blend；无真实 mask 输出验证 |
| 地面/植被/水面/建筑局部调整 | E | `LocalAdjustmentProcessor.applySemanticRegions` 已接链；无真实 mask 边缘/像素效果验证 |
| 主体/背景层次 | E | person/saliency mask 与 `CinematicSpatialDepthProcessor` 已接链；无真实输出验证 |
| 人脸专属补光 | B | 实现存在，但 `enforcePortraitProtection` 对任何检测到人脸的照片最终强制 `faceExposureEV = 0`；这是正确的人物保护结果 |
| 降噪 | E | `CINoiseReduction` 已接链；无真实照片质量验证 |
| 锐化 | E | `CISharpenLuminance` 已接链；无真实照片质量验证 |
| 纹理/细节保护 | E | 处理后在皮肤区域回混处理前局部图像；无人物原图/成片对验证 |
| Bloom/Halation/暗角/颗粒 | E | 新版 `CinematicLensCharacterProcessor` 已接链；无真实输出验证 |
| 旧 renderer 色彩分级/暗角/颗粒私有函数 | B | `CoreImageRenderer.swift:436,512,521` 存在，但无调用；当前链使用新版 cinematic processor |
| 镜头几何/畸变/暗角校正 | D | 未发现镜头 profile、畸变校正或 RAW lens correction 实现；现有 vignette 是风格效果，不是镜头校正 |
| RAW/ProRAW 处理 | D | 相机明确请求 JPEG；没有 CIRAWFilter/RAW 解码链 |
| 生成式 AI 局部修复/图像增强模型 | D | 唯一 Core ML 模型是语义分割；没有生成式重绘或增强模型 |
| AI 成片独立保存 | E | 源码已接入并阻止空/失败结果；本次未实际访问系统相册 |
| AI 成片预览绑定 | A（静态路径） | `.edited` 明确读取 `editedImageData`；代码路径可直接验证，不依赖图像框架运行 |

### C.1 日志真实性限制

`CoreImageRenderer.executedModuleNames` 不是逐模块运行回执，而是根据配方和“mask 是否存在”推导名称。例如 ground/vegetation/water/architecture 只要 mask 有效就会被列为执行模块，但 `LocalAdjustmentProcessor` 还可能因 scene facets 不匹配，或“有脸但无可靠 person mask”，实际跳过区域调整。因此诊断面板中的模块列表不能单独当作像素操作成功证据。

---

## D. 根因清单（按影响和证据强度排序）

### D1. 自动测试没有覆盖真实识别、渲染、质检、输出和展示（高影响，强代码证据）

**代码位置**

- `Package.swift:14-33` 明确排除 App、Camera、Models、Processing、QualityControl、Storage、Views、`PhotoAnalyzer.swift`、`SkySegmentationService.swift`、`CoreImageRenderer.swift`、各局部处理器。
- `Package.swift:35-42` 只把分析数据结构、问题检测、配方、决策和场景策略编入测试目标。
- 唯一测试文件是 `MasterCameraDecisionCoreTests/SceneAdaptationTests.swift`。
- 测试 `testRealReferenceMeasurementsCreateDifferentDirectorialPlans` 的“真实”仅表示手工填入从 JPEG 提取的数值；标签和 mask 仍由 fixture 人工注入，并未让 App 读取图片。

**运行/检查证据**

- 本机 `swift`、`xcodebuild` 均不可用，未执行测试。
- 既有文档记录提交 `8816e96` 对应 `iOS Build #42` 的 Swift 决策测试及 Simulator 编译通过；本次没有重新触发 CI，也没有把该编译结论扩大为像素质量结论。

**导致的问题**

- Scene recipe 有差异的测试可以全绿，但真实 Vision 可能返回错误/泛化标签。
- Core ML mask 可能未加载、误分或边缘错误，测试无法发现。
- Core Image 参数可能视觉近似无效，测试无法发现。
- 最终 JPEG、质量门、预览和保存回归无法由现有测试发现。

### D2. 场景识别可静默降级，且没有统一的可靠性/不确定性门（高影响，强代码证据，运行待验证）

**代码位置**

- `PhotoAnalyzer.swift:393-406`：通用 `VNClassifyImageRequest`，固定保留 confidence ≥ 0.12 的前 8 项；失败只记录日志并返回 `[]`。
- `PhotoAnalysis.swift:114-160,338-360`：以英文子串匹配把通用标签映射到单场景和 facets；没有标签校准、互斥消歧或整体置信度。
- `SkySegmentationService.swift:31-64`：模型加载/预测/输出异常返回 nil，主流程继续。
- `SkySegmentationService.swift:116-126`：输入直接分别缩放到 448×448，没有保持长宽比；这会使非正方形照片的模型输入发生几何拉伸，区域边缘质量需要真机验证。
- `SkySegmentationService.swift:150-188`：只读取离散 class ID，输出结果没有每像素概率或 mask 置信度。

**导致的问题**

- 识别失败时并非整次处理失败，而是更容易回到 `general`、基于亮度的 night/lowLight 或全局通用处理。
- 即便有分割 mask，也无法依据模型置信度决定是否安全应用局部处理。
- 在用户看来会表现为“有时略微换色、有时近似原图、不同场景趋同”。

### D3. 局部区域处理真实存在，但强度非常保守且触发条件严（高影响，强代码证据，视觉效果待验证）

**代码位置与上限**

- `LocalAdjustmentProcessor.swift:45-57` 植被只在 forest/countryRoad/nature facets 时执行；饱和度 delta 限于 -0.08...0.10，亮度约 -0.01...0.012，对比最多 +0.035。
- `LocalAdjustmentProcessor.swift:59-70` 水面只在 water/coast facets 时执行；亮度最多约 0.008，对比最多 +0.03。
- `LocalAdjustmentProcessor.swift:73-81` 建筑局部只增加最多约 0.04 对比。
- `LocalAdjustmentProcessor.swift:84-93` 地面局部曝光最多 0.055 EV，且实际由 `shadowZoneExposureEV * 0.28` 再次缩小；对比最多 +0.025。
- `LocalAdjustmentProcessor.swift:36-41` 有人脸但 person mask 不可靠时，全部语义区域编辑关闭，以保护人物。
- `PhotographyDecisionEngine.applyCinematicStrategy` 对大量策略选择共同的 `standard` 基线；context 之后虽有限幅，但全局共同影调仍可能比上述微弱局部差异更显著。

**导致的问题**

- “有蒙版、有处理函数”不等于能形成肉眼明确的专业局部制作。
- facet 漏识别、mask nil 或人物保护降级都会完全跳过相应区域。
- 当局部项很弱时，最终主要由全局曲线、电影影调和色彩分级决定，容易让多种场景仍共享相似观感。

### D4. 质量门只能检测粗粒度变化和技术异常，不能验证场景化专业效果（高影响，强代码证据）

**代码位置**

- `QualityCheckService.swift:85-94` 在 96 像素宽的缩略图上计算 RGB MAE 与变化像素比例。
- 非人物阈值：MAE 0.006、变化像素 20%；人物阈值：MAE 0.004、变化像素 12%。
- 只有 **MAE 和变化像素比例同时低于阈值** 才判 `insufficientProcessingImpact`。
- `PhotoProcessingPipeline.swift:231-242` 若判为变化不足，会提高通用曲线、局部对比、vibrance、对比度和亮度蒙版最低值。

**导致的问题**

- JPEG 重编码或全图极轻微变化可让许多像素跨过 `3/255` 阈值，即使视觉仍弱，也可能通过。
- 质量检查不评价“风景是否有空间层次”“室内灯光是否自然”“主体是否更明确”“局部 mask 是否有光晕”等场景审美目标。
- 修正路径保证更容易产生数值差异，但不是摄影质量优化器；它可能进一步强化不同场景共同的通用参数。

### D5. 诊断日志会把“具备条件”报告为“已执行”，降低故障定位可信度（中影响，强代码证据）

**代码位置**

- `CoreImageRenderer.swift:265-300` 的 `executedModuleNames` 根据 recipe/mask 推导模块。
- `LocalAdjustmentProcessor.swift:39-81` 才包含真正的 facet 和人物保护执行条件。

**导致的问题**

- 日志显示“植被蒙版/水面蒙版/建筑蒙版”不一定意味着该区域实际做了 blend。
- 后续真机排查可能错误地把“模块列名存在”当成局部处理成功。

### D6. 输入是相机 JPEG，不是 RAW；恢复空间存在客观上限（中影响，强代码证据）

**代码位置**

- `PhotoCaptureService.swift:31-33` 明确设置 `AVVideoCodecType.jpeg`。
- 未发现 RAW/ProRAW、镜头 profile 或镜头畸变校正链。

**导致的问题**

- 已经在 JPEG 中剪切的高光、压黑的暗部和强降噪细节不能被专业后期真正恢复。
- 这不是“处理没执行”的根因，但限制了极端场景达到专业相机 RAW 后期的上限。

---

## E. 测试结果

### E.1 本次实际执行

| 测试/检查 | 结果 | 说明 |
|---|---|---|
| 当前目录与 Git 状态 | 通过 | 位于 `D:\MasterCamera`；分支 main；初始仅 `图片/` 未跟踪 |
| `git diff --check` | 通过 | 没有已跟踪差异中的空白错误 |
| 源码调用链静态追踪 | 完成 | 从拍照/导入追到 Vision/Core ML、决策、Core Image、质检、预览和保存 |
| 模型文件存在性 | 通过 | `.mlpackage` 的 manifest、model、约 32 MB weights 均存在 |
| Xcode 工程引用检查 | 通过（静态） | Swift 源和 `.mlpackage` 均在工程 build phase 中 |
| 美颜/生成式模型代码搜索 | 未发现禁止项 | 未发现瘦脸、瘦身、磨皮、美白、祛痘、面部重建或生成式人脸调用 |
| 用户 7 张 JPEG 元数据/尺寸检查 | 完成 | 全部为 1179 px 宽、yuvj420p JPEG；无可用相机 make/model/creation EXIF |
| 用户 7 张 JPEG 低分辨率 signalstats | 完成 | 仅作为文件/亮度特征核对，不作为 App 处理效果证明 |

### E.2 参考图片检查结果

`D:\MasterCamera\图片` 中的 7 张文件如下：

| 文件 | 尺寸 | 只读观察 | 能否用于本次端到端验收 |
|---|---:|---|---|
| `ac2abf82...jpg` | 1179×1434 | 夜间秋叶道路参考成片 | 否：无对应 MasterCamera 原图/成片对 |
| `2167ef3c...jpg` | 1179×1411 | 夜间桥梁、水面、桌面参考 | 否 |
| `b62564fa...jpg` | 1179×1267 | 城市夜景，含“1/5”界面标记 | 否：截图/参考 |
| `d89b84c2...jpg` | 1179×1327 | 暖色卧室，含“1/6”界面标记 | 否：截图/参考 |
| `c4efdda5...jpg` | 1179×1346 | 暖色桌面参考 | 否 |
| `2819b216...jpg` | 1179×1362 | 真人环境人像，白边/“1/11”界面 | 否：截图/参考且无原始人像文件 |
| `5e55a75b...jpg` | 1179×1306 | 蓝调真人环境人像，白边/界面 | 否：截图/参考且无原始人像文件 |

这些文件可证明目标场景多样性，不能提供以下证据：App 实际识别标签及置信度、Core ML mask、最终 recipe、实际执行模块、原图/成片 MAE、局部边缘、人物纹理保持或最终相册文件。

### E.3 未执行的测试

- **未执行：`swift test`。** 原因：当前 Windows 环境没有 Swift；且即使执行，它也只测试决策 fixture。
- **未执行：`xcodebuild build/test`。** 原因：当前不是 macOS/Xcode 环境。
- **未执行：真实图片端到端 App 处理。** 原因：Core Image、Vision 和该 iOS Core ML 链无法在当前环境运行；仓库也没有可直接调用的跨平台 CLI。
- **未执行：真机拍照、相册保存和 UI 展示。** 原因：没有连接 iPhone 运行环境。
- **未执行：五类原始照片场景识别结果记录。** 原因：提供的文件是参考成片/截图，不是要求的未经处理原始摄影素材；不得伪造 Vision 输出。
- **未执行：原图与 AI 成片客观对比。** 原因：没有同一输入的配对输出。
- **未触发 GitHub Actions/TestFlight。** 原因：会创建外部任务并消耗构建/发布资源，不属于只读诊断。

---

## F. 人物保护专项审计

### F.1 禁止功能搜索结果

在运行时代码中未发现以下实现或调用：瘦脸、瘦身、五官/脸型几何修改、磨皮、美白、祛痘祛斑、皱纹消除、面部修复/重建、生成式重绘人脸。

唯一 Core ML 模型是场景语义分割，不输出增强图像；项目没有网络图像生成 API。

### F.2 当前人物保护链

- `PhotographyDecisionEngine.swift:85-110` 把人物保护放在所有场景/风格规则之后：
  - `faceExposureEV = 0`
  - 整人物补光只有 person mask 有效时才允许，且 ≤ 0.16 EV
  - skin texture protection ≥ 0.72
  - 限制降噪、锐化、局部对比
  - 橙色明度归零，橙色饱和度夹在 -0.02...0.02
- `LocalAdjustmentProcessor.swift:36-41`：检测到脸但没有可靠 person mask 时，关闭场景语义区域局部编辑。
- `SkinTextureProtectionProcessor`：将局部处理前的真实纹理回混到降噪/锐化后的结果，而不是生成皮肤。
- `QualityCheckService.swift:112-123`：比较人脸与背景的亮度/色彩变化差，以及人脸纹理能量比。

### F.3 仍未验证的风险

- 人脸框、person mask、skin matte 和 Core Image 坐标是否在所有方向/前后摄像头下完全对齐，未经真机验证。
- 输入照片没有 capture-time skin matte 时，皮肤保护会使用基于人脸框的额头/脸颊启发式区域；真实头发、侧脸和遮挡情形未经验证。
- 人物质检在 96 px 宽缩略图上进行，细微皮肤纹理变化可能检测不到。

结论：代码政策上未发现美颜功能，人物保护意图和硬限幅明确；**真实人物外貌/纹理保护仍是 E（未运行确认）而不是已完成验收。**

---

## G. 最重要的三个问题

1. **没有任何自动测试把真实照片送过 `PhotoAnalyzer → Core ML/Vision → CoreImageRenderer → QualityCheck → JPEG/Preview`。** 现有测试只证明人工标签能生成不同 recipe，不能证明真实识别和像素效果。
2. **局部区域处理的触发可靠性和强度不足。** 识别可无声降级、分割无置信度且输入被拉伸到正方形；即使触发，区域亮度/对比/饱和度上限很低，容易被共同全局调色覆盖。
3. **质量门不等于摄影质量门。** 当前主要判断缩略图数值是否变化及是否出现技术异常，不能判断场景处理是否合理；AND 条件还允许“广泛但很轻”的重编码差异通过。

---

## H. 下一步最小修复建议（本次不实施）

以下建议只对应已证实根因，不建议先重构架构。

### H1. 先建立最小真实回归样张包

准备至少 5 张未经社交软件/相册截图压缩的原始 JPEG/HEIC：天空/风光、秋季道路/植被、室内、夜景、真人。每张固定保存：原始文件、分析日志、mask 预览、最终 recipe、成片、质量指标和相册 asset 对应关系。

最小自动化目标不是“审美自动判满分”，而是让测试真正实例化 `PhotoAnalyzer`、加载模型、调用 `CoreImageRenderer` 并验证：

- 识别和 mask 不为空时确实改变对应区域；
- 五类场景 recipe 和区域实际执行记录存在合理差异；
- 输出几何/方向正确；
- 人脸区域无不允许的局部处理；
- 失败不会产生可保存的 AI 成片。

### H2. 让场景/蒙版失败成为可观测状态

最小改动方向：在 `PhotoAnalysis`/diagnostics 中记录 Vision 分类是否成功、最高/累计置信度、Core ML 加载/推理状态、每个 mask coverage 和拒绝原因；不能只把空数组/nil 当普通结果。`executedModuleNames` 应由处理器返回真实执行回执，而不是从参数和 mask 推断。

### H3. 用真实样张校准局部处理，而不是先提高全局滤镜

逐场景核对 `LocalAdjustmentProcessor` 的 facet 条件与亮度/对比/色彩上限；先确认 mask 边缘无误，再按真实原图提高有必要的区域强度。避免通过统一提高 `toneCurveAmount`、vibrance 或共同电影分级来制造差异。

### H4. 修正质量门的“变化有效性”定义

最小改动应把“变化不足”的 MAE/changed-ratio 逻辑与 JPEG 重编码噪声分离，并加入区域级前后比较：天空、地面、植被、建筑、水面以及人物保护区域分别核对处理方向。质量门仍不能代替人工盲评，但至少应验证“决策声称处理的区域确实按计划改变”。

### H5. 更新三处过时文档

在完成真实验证后再同步 `PROJECT_STATUS.md`、`MODEL_LICENSES.md` 和 `PROJECT_STATE.md`，明确区分“代码已接入”“CI 编译通过”“真实像素运行通过”“摄影审美验收通过”。

---

## I. 本次无法确认的内容

1. 7 张参考图在当前 TestFlight 构建上的真实 Vision 标签和置信度。
2. bundled Core ML 模型在目标 iPhone 上是否成功加载，以及五类 mask 的准确率、边缘、方向、内存和耗时。
3. Core Image 每项参数在目标设备和真实原图上的实际视觉强度。
4. 真实原图与本次 AI 成片的直方图、MAE、噪声、细节和局部区域变化。
5. 相册中 Original/AI_Edited 是否与本次拍照一一对应的真机证据。
6. 人物皮肤纹理、五官和头发在处理后的像素级保持情况。
7. 当前 `main` 最新提交的 Xcode 构建状态；本次未触发外部 CI。既有文档仅记录代码提交 `8816e96` 的 iOS Build #42 通过。

在获得真实原始文件、当前 TestFlight 日志和配对成片前，不应把上述项目写成“已通过”。
