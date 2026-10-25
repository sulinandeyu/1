# 小苏相机 V7 摄影引擎审计与修复报告

日期：2026-10-25

工程：`D:\MasterCamera`
审计范围：照片采集/导入、分析、摄影决策、局部蒙版、Core Image 渲染、质量检查、预览与相册保存。

## 1. 结论

当前工程不是“只生成参数但不处理像素”。真实链路会调用 Vision、Core ML 和 Core Image，渲染后的 JPEG 也会独立保存。但审计确认，V7 前的地面、植被、水面和建筑局部处理仍主要从全局配方间接推导，摄影计划中的区域说明没有一套与渲染器共享的区域参数，因此“识别出不同区域”和“实际获得针对性处理”之间仍存在断层。

本次没有改动相机 UI、拍照入口、原图保存、成片保存或用户数据结构的基本语义。修复集中在三项已有证据支持的问题：

1. 让区域实测结果生成明确的区域像素参数，并让计划、渲染和日志使用同一个结果。
2. 取消对所有照片统一要求明显像素差异的质量门槛，避免优质原图被强制加强。
3. 修正“阴影占比高就直接判为夜景”的误判条件。

## 2. 当前真实数据流

```text
CameraManager / PhotoCaptureService 或照片导入
  -> CapturedPhoto.originalImageData
  -> CameraViewModel.processCapturedPhoto
  -> PhotoProcessingPipeline.process
  -> PhotoAnalyzer.analyze
       - Core Image 低分辨率像素统计
       - Vision 人脸检测、人物分割、显著主体、场景分类
       - Core ML DETR 场景语义分割
       - 天空/地面/植被/水面/建筑区域统计
  -> PhotoProblemDetector.detect
  -> PhotographyDecisionEngine.makeDecision
       - 多维场景与光照语境
       - 全局配方
       - 实测区域参数与人物保护
  -> CoreImageRenderer.renderAutomaticEdit
       - 全局影调和色彩
       - LocalAdjustmentProcessor 蒙版区域处理
       - SkyAdjustmentProcessor 天空处理
       - 细节、肤质保护和镜头特征
  -> QualityCheckService.check
  -> 最多一次有边界的针对性重算；仍失败则明确报错
  -> CapturedPhoto.editedImageData
  -> PhotoPreviewView 展示原图/成片/差异
  -> PhotoLibraryManager 分别保存 Original 与 AI_Edited
```

## 3. 关键审计证据

### 3.1 场景识别与图像分析

- `MasterCamera/Analysis/PhotoAnalyzer.swift` 使用 `VNClassifyImageRequest` 输出最多 8 个标签，并记录识别成功、不确定、失败三种状态。
- 同一文件使用人脸检测、人物分割和显著主体请求；失败时返回空结果并写日志，不会把失败伪装为成功。
- `MasterCamera/Analysis/SkySegmentationService.swift` 加载随 App 打包的 `DETRResnet50SemanticSegmentationF16P6`，读取 `semanticPredictions`。
- 已从模型元数据核对实际类别编号：187 为 `sky (other)`、149 为 `road`、184 为 `tree`、193 为 `grass`、148 为 `river`、155 为 `sea`、178 为 `water (other)`、197 为 `building (other)`。当前代码使用的主要类别编号与模型标签一致。
- 区域统计由 `PhotoRegionStatistics.measure` 在蒙版像素内计算，不再只用全图平均值代表局部区域。

### 3.2 决策是否进入渲染

- `PhotoProcessingPipeline.process` 将同一个 `PhotoAnalysis` 传给 `PhotographyDecisionEngine` 和 `CoreImageRenderer`。
- `CoreImageRenderer.processImage` 按顺序执行全局影调、色彩、局部处理、天空处理、空间层次、降噪、锐化和肤质保护。
- `LocalAdjustmentProcessor` 使用 `CIBlendWithMask` 合成区域处理结果，人物存在时从场景蒙版中扣除可靠人物蒙版。
- `SkyAdjustmentProcessor` 只在有效天空蒙版内应用曝光、高光和饱和度调整。

### 3.3 输出与保存

- `CapturedPhoto` 新拍摄或导入时的 `editedImageData` 为空，不再用原图字节伪装 AI 成片。
- 处理失败时 `CameraViewModel` 显示错误，不会进入成片预览成功状态。
- `CoreImageRenderer.validateEncodedGeometry` 验证 JPEG 输出尺寸。
- `PhotoLibraryManager` 要求原图和成片都存在且处理完成，然后分别创建两个相册资源。

## 4. 已确认根因与修复

### 根因一：区域处理仍从全局参数间接推导

旧逻辑虽然有区域蒙版，但植被、水面、建筑和地面主要从全局 HSL、局部对比度和亮度蒙版参数派生。摄影计划仅说明“要处理该区域”，没有记录该区域为什么处理、实际参数、置信度和降级方式。不同照片可能识别出不同内容，但最终区域处理仍趋于相似或过弱。

修复：

- 在 `AutomaticEditingRecipe.swift` 增加 `RegionalPixelAdjustment`。
- 分别使用地面、植被、水面和建筑自身的亮度、5-95% 对比范围、饱和度、阴影和高光统计生成区域曝光、高光、阴影、对比度、饱和度、色温和清晰度参数。
- 参数受明确安全范围和识别/覆盖率置信度缩放。
- `PhotographyDecisionEngine`、`LocalAdjustmentProcessor` 和诊断日志调用同一个区域参数工厂，避免文档计划与实际像素处理不一致。
- 语义分类失败时不再使用全局场景色彩假设；如果 Core ML 已给出可靠蒙版，仍可执行低置信度、区域实测驱动的安全局部处理。

### 根因二：质量检查用统一差异门槛强迫照片变化

旧逻辑要求非人物照片的平均 RGB 差异至少达到 0.006，人物照片至少 0.004。原图即使已经具有良好摄影质量，也可能被判为“处理影响不足”，继而触发更强的二次处理。这与“好照片允许接近原图”的产品原则冲突。

修复：

- 质量门槛现在由原片是否存在曝光、对比、高光、暗部、饱和度、噪声问题，以及是否存在实际局部处理计划共同决定。
- 明确需要修正时仍检查足够的处理影响；原图健康且没有局部计划时允许非常克制的变化。
- 原图和成片字节完全相同仍被视为渲染失败，不会把原图伪装为成片。

### 根因三：高阴影占比可单独触发夜景

旧的 `semanticScene` 和 `PhotographyContext` 只要阴影占比超过 0.55，就可能判为夜景；强日光、峡谷、逆光风景也可能满足这个条件。

修复：

- 夜景现在需要夜景语义标签，或较低平均亮度；高阴影占比必须同时伴随低平均亮度才构成夜景证据。
- 新增“明亮但高阴影风景不能误判为夜景”的决策测试。

## 5. 修改文件

- `MasterCamera/Analysis/PhotoAnalysis.swift`
- `MasterCamera/ImageEngine/AutomaticEditingRecipe.swift`
- `MasterCamera/ImageEngine/LocalAdjustmentProcessor.swift`
- `MasterCamera/Models/PhotoDiagnostics.swift`
- `MasterCamera/PhotographerAI/PhotographyDecision.swift`
- `MasterCamera/PhotographerAI/PhotographyDecisionEngine.swift`
- `MasterCamera/Processing/PhotoProcessingPipeline.swift`
- `MasterCamera/QualityControl/QualityCheckService.swift`
- `MasterCameraDecisionCoreTests/SceneAdaptationTests.swift`

## 6. 修改前后决策差异

| 项目 | 修改前 | 修改后 |
|---|---|---|
| 地面处理 | 从全局阴影和局部对比参数推导 | 使用地面蒙版内实测亮度、阴影和对比度 |
| 植被处理 | 从全局绿/黄 HSL 推导 | 使用植被自身亮度、饱和度、阴影和场景语境 |
| 水面处理 | 从全局青/蓝 HSL 推导 | 使用水面高光、反射、饱和度和蓝调时刻证据 |
| 建筑处理 | 基本只有轻微全局对比衍生 | 使用建筑自身曝光、高光、阴影和结构对比 |
| 计划与执行 | 计划文字与渲染参数是两套逻辑 | 计划、渲染、日志共用 `RegionalPixelAdjustment` |
| 优质原图 | 仍需达到统一最小差异 | 无明确问题时允许克制变化 |
| 夜景判断 | 高阴影占比可单独触发 | 高阴影必须同时伴随低亮度，或有夜景标签 |

## 7. 可解释诊断

每张照片现在可记录：

- Vision 场景状态、最高置信度及失败原因。
- Core ML 分割状态、各区域覆盖率。
- 各区域实测亮度、对比、饱和度、高光和 RGB。
- 每个区域调整的置信度、曝光、高光、阴影、对比、饱和度、色温和清晰度。
- 每个区域已执行或跳过的原因。
- 全局配方、实际执行模块、质量检查、是否重算及最终像素差异。

质量重算后，最终摄影计划会使用修正后的配方重新生成区域参数，避免界面仍显示初版参数。

## 8. 已执行测试

### 8.1 当前 Windows 环境已执行

- `git diff --check`：通过；只有 Git 的 LF/CRLF 提示，无空白错误。
- 模型标签元数据核对：通过；当前读取的天空、道路、植被、水面和建筑类别编号与打包模型标签一致。
- `scripts/Analyze-PhotoTriplet.ps1`：成功读取 `TestPhotos/original.jpg`、`mastercamera.jpg`、`reference.jpg` 并生成区域指标。
- 三张图片确属同一画面，但现有 `mastercamera.jpg` 为旧版本成片，尺寸为 1279x1706，原图与参考图为 1280x1707。它不能作为本次 V7 新渲染结果。
- 旧成片相对原图主要表现为地面/人物轻微提亮和天空轻微增色，山体与天空的局部层次变化有限，符合本次根因判断。

### 8.2 已新增但当前机器不能执行

`SceneAdaptationTests` 新增：

- 暗地面与亮地面必须生成不同且方向正确的局部曝光参数。
- 场景分类失败时，全局 HSL 恢复中性，但可靠语义蒙版仍允许实测驱动的局部处理。
- 明亮高阴影风景不得误判为夜景。

当前 Windows 机器没有 Swift 工具链、Xcode、Vision、Core ML 和 Core Image iOS 运行环境，因此本轮不能在本机执行 `swift test`、iOS 编译或新的 Core Image 成片渲染。不得据此宣称 iOS 端到端已经通过。

## 9. 人物真实性

- 决策层继续强制 `faceExposureEV = 0`，禁止人脸专属提亮。
- 场景区域处理在检测到人脸但缺少可靠整人物蒙版时全部跳过。
- 有人物蒙版时，地面、植被、水面、建筑和天空蒙版均扣除人物区域。
- 只允许整个人物蒙版的有限曝光协调，不包含磨皮、美白、瘦脸、五官重建、瑕疵删除或生成式人脸处理。
- `QualityCheckService` 继续比较脸部与背景的亮度、颜色和纹理变化。

代码约束已保留，但人物真实性仍必须通过新版本 iPhone 原图与成片的 100% 局部查看完成视觉验收。

## 10. 未解决和仍需验证的问题

1. 新增 Swift 代码尚未在 macOS/Xcode 编译，可能存在仅编译器能发现的平台 API 或类型问题。
2. Core ML 蒙版坐标、方向、羽化边界和人像扣除效果尚未用本次版本的真机日志与蒙版结果验证。
3. Windows 指标脚本不能代替 Vision/Core ML/Core Image，不能生成或代表 V7 iOS 成片。
4. `TestPhotos/mastercamera.jpg` 是旧成片，不能用于判断本次修复后的视觉效果。
5. 当前区域处理仍受打包 DETR 模型类别和 448 像素分割分辨率限制；山体没有独立语义类别，需使用地面/自然区域与亮度层次保守处理。
6. 最终摄影审美必须用多场景真机样片人工验收，客观指标只能排除明显技术错误。

## 11. 下一步真机验收

1. 在 GitHub Actions 或 Mac 上先执行 `swift test` 和 iOS Simulator Debug 构建。
2. 生成新的 TestFlight 构建，不得复用旧 `mastercamera.jpg` 作为结果。
3. 在同一台 iPhone 上测试：晴朗天空与人物、阴天风景、室内、城市夜景、植被/乡间道路、逆光人物、普通旅行照、已经很好看的原图。
4. 每张照片保存原图和 AI 成片，并截取“画面分析”“AI 摄影决策”“像素与处理链诊断”页面。
5. 核对区域覆盖率、区域实测、区域参数与执行回执是否一致；重点检查天空或地面蒙版是否上下颠倒、错位或出现光晕。
6. 人物照片以 100% 查看脸部、头发、皮肤、衣服边缘，确认没有结构、纹理和身份变化。
7. 把原图、成片、三组诊断截图、机型、iOS 版本、处理耗时和主观问题反馈回项目，完成下一轮基于证据的调整。

本报告只确认代码审计、Windows 可执行检查和修复实现；不宣称 Xcode 构建、iOS Core Image 渲染或真机摄影质量已经通过。
