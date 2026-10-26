# 小苏相机 V8.1：主体优先级与执行链修复

日期：2026-10-26

## Build 22 发现

Build 22 显示主体蒙版已生成（68×68），旧诊断甚至把主体置信度显示为 100%，但实际执行模块只有植被、建筑、地面等区域，没有“显著主体”。原因有两层：

1. 场景分类最高置信度被错误复用为主体置信度，导致虚假的高置信度。
2. 主体计划没有稳定转换为 `RegionalPixelAdjustment` 并进入 `LocalAdjustmentProcessor` 的语义区域循环。

## Subject Priority Profile

`PhotoAnalysis.subjectPriorityProfile` 现在输出：

- `primarySubjectMask`；
- `secondarySubjectMasks`；
- `backgroundMask`；
- 当前能力范围内可确认的 `lowPriorityDistractorMasks`；
- 独立主体置信度、类型说明和构成依据；
- `primarySubject` 或 `globalHarmony` 模式。

主体置信度只来自可靠人物蒙版，或 Vision 显著性覆盖、区域亮度/色彩/对比分离和有效范围。普通 `outdoor/plant/sky` 分类置信度不再冒充主体置信度。没有物体级证据时只描述“通用视觉显著区域”，不会谎称准确识别出柿子。

## 实际渲染链

可靠非人物主体按以下链路执行：

`PhotoAnalyzer` 测量显著区域 → `PhotoAnalysis.salientSubjectPriorityConfidence` → `PhotographyDecisionEngine.treatmentPlan` → `RegionalPixelAdjustment.make(.subject)` → `LocalAdjustmentProcessor.applySemanticRegions` → 候选预览与全分辨率 Core Image 渲染。

主体允许有限曝光、阴影/高光、局部对比、自然饱和度和清晰度调整；背景区域会排除主体蒙版，避免植被或建筑处理覆盖主体。人物照片仍禁止通用显著性处理人脸，只使用可靠整人物蒙版和原有人物保护链。

## 诊断产物

通过诊断导入入口重测时，处理阶段会保留：

- 原图；
- 仅全局调整；
- 全局加局部蒙版；
- 三个候选；
- 最终选择；
- 主体蒙版；
- 主体蒙版叠加图；
- 主体区域实际参数、覆盖率与前后像素统计。

`CoreImageRenderer` 的低分辨率候选与全分辨率渲染复用同一归一化蒙版、同一分析结果和同一候选配方，避免两阶段坐标体系不一致。

## 验证边界

当前代码已经建立执行分支和日志，但 Windows 无法运行 Vision/Core Image。必须在 iPhone 上看到“显著主体：已执行”、主体区域变化统计和正确蒙版叠加图，才能确认 V8.1 真机链路通过。

