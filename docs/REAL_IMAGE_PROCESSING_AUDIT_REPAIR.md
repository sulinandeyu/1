# 真实图像处理链路审计与修复（2026-10-24）

## 结论

现有工程的“识别 → 决策 → Core Image 渲染 → JPEG 输出 → 预览/相册”主链路是连通的，
问题不是参数 JSON 完全没有传入渲染器。实际根因是：可见处理强度被压得过低、质量检查无法
拦截重新编码但视觉几乎不变的结果、未处理对象在数据模型中可把原图冒充成片、复合场景会
丢失部分语境，以及除天空/人物外缺少真正的语义区域蒙版。

本轮修复提交：

- `0f7c20c`：拒绝视觉影响过小的渲染结果，修正调色有效强度，阻止伪成片保存。
- `8816e96`：复用已部署的语义分割模型，执行道路、植被、水面和建筑区域局部处理。

## 真实执行链路与文件证据

1. `CameraManager.capturePhoto` 调用 `PhotoCaptureService.capturePhoto`，保存相机返回的原始 JPEG。
2. `CameraViewModel.processCapturedPhoto` 只在 `PhotoProcessingPipeline.process` 成功后发布
   `capturedPhoto`；失败显示明确错误，不进入预览。
3. `PhotoProcessingPipeline.process` 依次调用 `PhotoAnalyzer.analyze`、
   `PhotoProblemDetector.detect`、`PhotographyDirector.direct`、
   `CoreImageRenderer.renderAutomaticEdit` 和 `QualityCheckService.check`。
4. `CoreImageRenderer.processImage` 对原图像素执行曝光、高光阴影、曲线、亮度分区、白平衡、
   HSL、三段色彩分级、语义区域、局部对比、降噪、锐化和人物纹理保护，最终编码新的 JPEG。
5. `PhotoPreviewView.displayedImage` 的 AI 档读取 `editedImage`；原图档读取 `originalImage`。
6. `PhotoLibraryManager.savePhotos` 分别写入 `originalImageData` 和 `editedImageData`，使用不同
   文件名创建两个相册资源。

没有发现处理完成后又被原图覆盖、异步提前返回原图或前端固定绑定旧缩略图的代码路径。

## 已确认根因与修复

### 1. 质检只比较编码字节，无法识别视觉无变化

旧 `QualityCheckService.check` 仅在 `editedData == originalData` 时报告
`possibleRenderFallback`。只要 Core Image 重新编码 JPEG，即使解码像素几乎没变也会通过。

现已在同一质检函数中以 96 像素宽的统一 sRGB 解码图计算 RGB MAE 与显著变化像素比例。
非人物图低于 `0.006 / 20%`、人物图低于 `0.004 / 12%` 时报告
`insufficientProcessingImpact` 并进入一次有边界的场景配方增强；再次失败则拒绝输出成片。
阈值不是审美合格证明，只是防止“几乎等于原图”继续显示成功。

### 2. 三段色彩分级被连续缩小到近乎不可见

旧 `CinematicColorGradingEngine.apply` 将 `colorGradeIntensity`、分区量、额外 0.72–0.78
和约 0.009–0.022 的通道偏移连续相乘。常见夜景配方的最终通道移动仅约千分之一以内。

现保留阴影/中间调/高光亮度蒙版与场景配方，只把最终色彩偏移调整到仍受蒙版和配方双重
约束、但能够影响实际像素的范围。没有新增统一 LUT，也没有把所有照片强制染成青橙色。

### 3. 未处理照片可在数据层伪装成 AI 成片

旧 `CapturedPhoto.init` 在没有 `editedImageData` 时直接复制 `originalImageData`。虽然当前
ViewModel 正常路径不会提前展示它，但任何未来保存或预览分支都可能把原图当成 AI 输出。

现未处理对象的编辑数据保持为空；`hasCompletedProcessing` 必须同时具备分析、决策、质检和
非失败成片。`PhotoLibraryManager` 不满足条件时抛出 `processingIncomplete`，不再静默保存。

### 4. 夜间乡间道路丢失森林/道路摄影语境

主策略正确选择 `.night`，但旧 `PhotographyContext` 的风景风格条件没有包含 `.forest`、
`.countryRoad` 和 `.coast`，因此秋季夜路会退化成自然纪实通用约束。

现保留夜景主策略，同时让森林/乡间道路参与 `professionalLandscape` 的黄色、橙色和植被
关系决策。新增契约测试验证夜景主策略与道路/森林复合语境能够同时存在。

### 5. 局部修图只有天空、人物和显著主体

工程已内置 `DETRResnet50SemanticSegmentationF16P6.mlpackage`，但旧服务只读取天空类别 187。
本轮从模型自身 `com.apple.coreml.model.preview.params` 元数据核对真实输出类别编号，并在一次
推理中同时提取：

- 地面/道路：木地板、碎石、道路、沙地、普通地板、路面、泥地等。
- 植被：盆栽、花、树、草地。
- 水面：河流、海、水面。
- 建筑结构：桥、门、房屋、屋顶、楼梯、墙、窗、围栏、天花板、建筑等。

`LocalAdjustmentProcessor.applySemanticRegions` 根据当前场景 facets 与当前配方对这些蒙版做
羽化后的局部曝光、对比度和色彩调整。它不会为不存在的区域强行处理。人物图先扣除 Vision
整人蒙版；检测到脸但无法获得可靠整人蒙版时，全部场景局部处理关闭。

## 人物保护

- 不包含几何变形、生成式修复、磨皮、美白、祛痘、瘦脸或五官修改代码。
- `PhotographyDecisionEngine.enforcePortraitProtection` 最后执行，清零人脸专属曝光，并限制
  人像降噪、锐化、局部对比和橙色明度。
- `QualityCheckService.portraitIntegrity` 比较脸部相对背景的亮度/颜色变化与纹理能量，异常
  拒绝输出。
- 新增语义区域局部处理不会在缺少可靠整人排除蒙版时运行。

## 验证状态

- `0f7c20c` 的 Swift 决策测试和完整 iOS Simulator 编译已由 GitHub Actions
  `iOS Build #41` 验证通过。
- `8816e96` 增加了“夜间 + 乡间道路 + 森林”的复合场景测试，以及地面/植被区域制作计划
  断言；GitHub Actions `iOS Build #42` 的 Swift 测试与完整 iOS Simulator 编译均通过。
- 仓库没有天空、秋季道路、室内、夜景、人物五类未经处理的原始测试照片。用户提供的 7 张
  JPEG 是摄影参考成片，并非同一输入的 MasterCamera 原图/AI 输出对，因此没有把它们冒充
  端到端视觉验收。

## 尚未完成或仍需真机验证

1. 新蒙版类别在真实 iPhone 输入上的边缘质量、误分率和 448×448 推理耗时仍需 TestFlight
   真机验证。
2. 当前没有独立窗户/灯具专用类别策略；它们由建筑蒙版、亮度蒙版和高光源检测共同处理。
3. 质量阈值只能拦截无效输出，不能自动证明摄影审美优秀。最终仍需五类原始照片逐张比较。
4. 本轮没有使用生成式模型，也没有实现内容重绘。

## 真机验收记录要求

每张原始照片在诊断面板记录：语义标签与置信度、facets/lighting/style、五类蒙版是否有效、
最终配方、实际执行模块、RGB MAE、亮度/颜色 MAE、变化像素比例、质检结果和最终相册文件。
至少覆盖天空/风光、秋季道路/植被、室内、夜景和真人五类。任何一张出现人物纹理变化、蒙版
光晕、异常色偏或视觉仍近似原图，均视为未通过并回到对应函数修正。
