# 小苏相机 V8 摄影引擎审计

日期：2026-10-25

## 结论

V7 已经真实执行 Vision/Core ML 分析、Core Image 全局与蒙版处理、JPEG 编码和独立保存，并非只生成参数。但 V8 审计确认效果不明显仍有三个结构性原因：

1. `PhotoProcessingPipeline` 只渲染摄影总监生成的一套完整分辨率配方，只有质检失败才做一次修正，没有在合理方案之间择优。
2. `PhotoProblem` 只有类型、严重度和证据文字，缺少影响区域、处理建议、风险和置信度，无法形成完整、可审计的编辑计划。
3. 质量检查可以排除技术异常，但不会比较多个候选对原始摄影问题的改善程度；像素差异只能证明变化，不能证明变好。

## 原有真实链路

`CameraViewModel` → `PhotoProcessingPipeline` → `PhotoAnalyzer` → `PhotoProblemDetector` → `PhotographyDirector` → `CoreImageRenderer` → `QualityCheckService` → `CapturedPhoto` → `PhotoPreviewView` / `PhotoLibraryManager`

原图与 AI 成片仍独立保存；处理失败不会以原图冒充成功成片。

## 本轮实际修改

- 扩展 `PhotoProblem`：增加影响区域、处理建议、处理风险和检测置信度。
- 增加 `PhotographyEditPlan` 与 `PhotographyPlannedAdjustment`，记录目标区域、调整类型、强度、范围、原因、预期效果和降级方式。
- 增加 `PhotographyCandidatePlanner`，从当前照片的实测配方派生自然保守、层次增强、问题定向三个候选。
- `CoreImageRenderer` 增加最长边 640 像素的候选预览渲染；全分辨率只渲染优胜方案。
- 管线增加问题改善、保真、技术风险和分区实际像素变化评价。
- 保留最多一次有边界修正，防止无限迭代。
- 人物保护在每个候选生成后再次执行，任何候选都不能开启人脸专属提亮或外貌处理。

## 参数与渲染传递

候选计划中的 `recipe` 直接传入 `CoreImageRenderer.processImage`。曝光、高光阴影、曲线、白平衡、色彩、HSL、局部分区、天空、亮度蒙版、降噪、锐化和镜头特征仍由现有 Core Image 节点执行。摄影计划不是旁路 JSON。

## 未验证边界

当前环境为 Windows，没有 Swift、Xcode、Vision、Core ML 和 Core Image iOS 运行时。本报告确认源码链路和 Windows 可执行的素材指标检查，不宣称 V8 已通过 iPhone 视觉质量验收。
