# V8 渲染与输出链路核验

日期：2026-10-26

## 调用链

`CameraManager / 样片复测` → `CameraViewModel` → `PhotoProcessingPipeline.process` → `PhotoAnalyzer` → `PhotoProblemDetector` → `PhotographyDirector` → `PhotographyCandidatePlanner` → 三个低分辨率 Core Image 候选 → `QualityCheckService` → `PhotographyCandidateSelector` → 优胜配方完整分辨率渲染 → 最多一次有边界质量修正 → `CapturedPhoto.editedImageData` → `PhotoLibraryManager.savePhotos`

## 参数一致性

- 低分辨率候选与完整分辨率渲染使用同一个 `PhotographyEditPlan.recipe`。
- 选择后通过 `decision.replacingRecipe` 重建区域执行计划，避免旧配方文本覆盖新配方。
- 所有区域蒙版都是归一化像素数据，候选和全分辨率渲染均按各自 `CIImage.extent` 缩放。
- 修复后的显著主体、地面、植被、水面、建筑都调用同一 `RegionalPixelAdjustment.make`，计划与渲染不会各自计算不同参数。

## 不能仅靠静态代码证明的部分

Vision 蒙版和 Core ML 蒙版的真机方向、边缘及覆盖必须看实际叠加图。静态路径一致不等于蒙版一定对齐。为此 `CoreImageRenderer.renderMaskDiagnosticPreviews` 新增了每个有效区域的灰度蒙版和橙色叠加预览。

## 分层调试输出

通过相机页“样片复测”导入的诊断样片会在现有“逐阶段预览”提供：

- `A 原始照片`
- `B 仅全局调整`
- `C 全局+局部蒙版`
- `D V8.1候选-自然保守`
- `D V8.1候选-层次增强`
- `D V8.1候选-问题定向`
- `E 自动选择最终结果`
- 每个有效区域的 `蒙版-*` 与 `蒙版叠加-*`
- 可靠主体存在时的 `主体调整前-仅全局`、`主体单独调整后` 与 `主体调整差异-放大5倍`

这些扩展内容只在 `isDiagnosticImport` 为真时生成，普通相机拍摄不增加候选和蒙版调试图，也没有改动正式取景 UI。候选预览直接复用真实低分辨率 Core Image 渲染结果，不是 Python 或 FFmpeg 替代图。

## 保存链验证

`PhotoLibraryManager` 在一次 `PHPhotoLibrary.performChanges` 中创建两个独立资源，文件名分别包含 `Original` 与 `AI_Edited`。保存前 `CapturedPhoto.hasCompletedProcessing` 要求分析、决策、非空编辑数据和非 failed 质量结果同时成立。

下一次真机仍需验证：相册重新打开的 `AI_Edited` 与 App 的 E 预览一致；时间戳配对正确；没有旧缓存或串图。

