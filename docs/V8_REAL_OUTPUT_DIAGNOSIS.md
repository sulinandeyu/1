# 小苏相机 V8 真实成片效果诊断

日期：2026-10-26

## 证据边界

本轮收到两张 1280×1707 JPEG。它们来自微信临时目录，EXIF 来源信息已被清除，但用户已于 2026-10-26 明确确认第一张 `91999e...` 是原图，因此第二张作为同次配对的 TestFlight build 22 成片记录。

- 原图 SHA-256：`8F29F8F126E7DA115BAEE18418F5EA5E17AF6783B1CFAE18B93FE2C9A4DC00CD`
- V8 build 22 成片 SHA-256：`ED69E1653D0251482D4E3BB49CF0F2A837E32740468DFE557B2B1C5BFDE1D56A`
- 配对 SSIM：`0.887027`
- 配对 PSNR：`26.895129 dB`

这些数值证明 V8 成片并非只发生元数据或重新编码变化，但不能证明变化方向更好。

## 配对区域实测

数据来自 `scripts/Analyze-V8PersimmonPair.ps1`，完整结果保存在本地私有素材目录 `TestPhotos/V8_Persimmon/paired_metrics.json`。FFmpeg 只用于对称诊断，没有模拟 Core Image 成片。

| 区域 | 原图亮度/饱和度 | V8 build 22 亮度/饱和度 | 实际变化 |
|---|---:|---:|---|
| 全图 | 113.86 / 8.78 | 115.14 / 10.17 | 略亮、略增色 |
| 果树冠层 | 86.86 / 8.06 | 90.10 / 8.68 | 暗部略抬、颜色变化有限 |
| 阴天天空 | 182.91 / 6.69 | 171.22 / 9.07 | 压暗天空并增加色彩 |
| 石板路 | 130.16 / 8.33 | 132.59 / 10.28 | 局部略亮、略增色 |
| 前景果筐 | 112.28 / 13.91 | 116.64 / 16.04 | 橙色主体变化相对更明显 |

肉眼并排观察与指标一致：变化主要是全局/大区域影调和颜色整理，果实与树叶的摄影层次提升仍不够明确，主体没有形成稳定的视觉优先级。

## 已确认的代码根因

### 1. 主体计划与实际像素处理断链

`PhotoAnalyzer.generateSalientSubjectMask` 会生成 Vision 显著性蒙版，`PhotographyDecisionEngine.treatmentPlan` 也会登记 `.subject`。但旧 `LocalAdjustmentProcessor.applySubjectRelighting` 只有 `recipe.subjectExposureEV > 0` 才处理该蒙版，而普通户外/风景配方通常保持 0。因此日志可能出现主体计划，像素链却没有主体局部处理。

### 2. 候选评价没有普通主体目标

V8 旧评分只在 `.backlitSubject` 问题中读取 person/subject 区域影响。普通风景中的显著主体，即使三个候选表现不同，也不参与问题改善分。这会让系统主要比较全局技术问题和保真，缺少“主体是否更清晰”的选择依据。

### 3. 诊断无法证明蒙版方向

旧诊断仅显示蒙版存在和覆盖率，没有输出蒙版本体及叠加预览。低分辨率候选与完整分辨率渲染确实复用同一 `PhotoAnalysis` 和同一配方，并按目标画布缩放归一化蒙版，但在没有真机蒙版图时，不能证明 Vision/Core ML 输出方向与最终照片完全一致。

### 4. 保存链没有发现原图覆盖

`PhotoProcessingPipeline.process` 将 `finalEdit.data` 写入 `CapturedPhoto.editedImageData`；`PhotoLibraryManager.savePhotos` 分别把 `originalImageData` 与 `editedImageData` 写为两个 PHAsset。质量失败会抛错并阻止保存 AI 成片。静态代码没有发现最终成片被原图覆盖、缓存复用或异步提前保存的问题。

## 本轮最小修复

- 为显著主体计算独立区域统计与摄影优先置信度，不宣称具体物体身份。
- 过滤覆盖过小或超过 72% 的不可靠显著性蒙版。
- 将可靠 `.subject` 纳入与植被、道路、建筑相同的真实局部像素处理链。
- 把主体局部变化纳入区域问题、候选改善分和预期执行回执。
- 在现有处理阶段预览中保留三个低分辨率候选、全局版、全局+局部版、最终版、原始蒙版和蒙版叠加图。
- 增加主体局部处理及宽泛蒙版拒绝测试。

## 尚未验证

当前 Windows 不能执行 Vision、Core ML、Core Image，修改尚未提交或推送，也没有新的 iPhone 成片。因此以上状态是“代码修复完成、静态检查待完成、真机未验收”，不得写成视觉质量通过。

