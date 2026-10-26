# 小苏相机 V8.2 影调与专业调色

## 影调控制

V8.2 保留曝光、高光阴影、黑位、五点曲线、七段影调和亮度蒙版，但调整职责：

- 曝光和高光阴影处理负责动态范围问题。
- 五点曲线负责黑场、四分之一调、中间调、四分之三调和白场。
- 七段影调只做更细的过渡，不再默认抬黑和大幅压白。
- 亮度蒙版只作用于可恢复阴影与高光。
- 局部蒙版负责天空、地面、植被、建筑、水面和可靠主体，不以全局 HDR 代替局部处理。

## HSL / Selective Color

`ProfessionalHSLAdjustment` 现在为橙、黄、绿、青、蓝分别提供 Hue、Saturation、Luminance。色相范围限制在约 ±0.025 至 ±0.03 个色轮，饱和度与明度沿用安全上限。

实现使用连续色相权重和低色度保护：中性像素的调整权重会随原始饱和度趋近于零，避免灰墙、白车和云层被 HSL 染色。LUT 在编码 sRGB 中进行感知色彩计算，再回到扩展线性 sRGB 工作空间。

## 全局协调

- 阴天：保持天空中性，主要通过高光层次、建筑/植被局部对比和地面关系建立画面。
- 人物：以曝光和环境光影协调为主，不主动增强橙色。
- 建筑：以结构、材质和高光控制为主，不统一加蓝。
- 植被：按植被区域自身亮度和饱和度调整，不给整张照片加绿或黄。
- 夜景和明确日落仍允许有证据的冷暖关系，但受到最终质检约束。

## 候选选择

候选分数现在由问题改善、主体优先、区域协调、保真和颜色完整性共同决定。肤色或中性色风险最高可产生 34 分惩罚；超过硬阈值时直接拒绝。这样可以避免“最有滤镜感”或“最保守”自动胜出，也不会把 PSNR/SSIM 或像素差异当成审美分数。

## 代码位置

- `MasterCamera/ImageEngine/AutomaticEditingRecipe.swift`
- `MasterCamera/ImageEngine/CinematicImagingEngines.swift`
- `MasterCamera/ImageEngine/CoreImageRenderer.swift`
- `MasterCamera/PhotographerAI/PhotographyDecisionEngine.swift`
- `MasterCamera/QualityControl/QualityCheckService.swift`
- `MasterCamera/Processing/PhotoProcessingPipeline.swift`
