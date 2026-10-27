# 小苏相机自适应摄影后期核心整改

日期：2026-10-27

## 根因审计

此前生产链先依次执行曝光、反差、色彩、场景、天空、电影感、上下文和整图协调等旧版策略，再由 `PerPhotoParameterPlanner` 对结果进行修正。因此逐图测量并不是参数的唯一来源，场景策略已经提前为配方确定了方向。低分辨率候选又固定生成“自然保守、层次增强、问题定向”三种变体，容易把最弱变化误认为最安全结果。

## 已实施整改

- `PhotographyDecisionEngine.makeDecision` 不再调用旧版场景配方方法。旧方法暂时保留为不可达兼容代码，便于后续独立删除；生产入口只接受 `AdaptivePhotographyParameterSolver` 的结果。
- `AdaptivePhotographyTargetGenerator` 使用当前照片的亮度、中间调、反差、阴影、黑位、高光、白位、饱和度、噪声、混合光和空间亮度方差生成逐图目标。夜景或现场光标签只形成氛围保护权重，不选择固定配方。
- `AdaptivePhotographyParameterSolver` 从全中性配方开始，计算曝光、亮度、高光、阴影、黑白场、曲线、中间调、白平衡、饱和度、自然饱和度、细节、降噪、亮度蒙版及可靠区域参数。
- 参数证据新增影响区域与 `planned / notNeeded / disabledBySafety` 状态；诊断页同时显示输入测量、目标、安全范围、实际值和渲染后指标。
- 候选不再固定为三套。始终保留求解器基线；只有存在影调残差时增加影调修正，只有存在局部、颜色或细节残差时增加局部修正。
- 候选评分新增逐图目标达成度，降低“变化越小越安全”对最终选择的支配。
- 质量修正不再在画布不一致时使用共享 `safeFallback` 配方。画布错误会明确失败；其他修正依据最终实测值与逐图目标之间的残差计算。

## 参数执行链

`PhotoAnalyzer` → `PhotoProblemDetector` → `AdaptivePhotographyTargetGenerator` → `AdaptivePhotographyParameterSolver` → 按需残差候选 → `CoreImageRenderer` 低分辨率实渲染 → 目标/问题/保护/区域评分 → 同一配方完整分辨率渲染 → `QualityCheckService` → JPEG 与诊断保存。

分析、候选和最终渲染共用同一个 `AutomaticEditingRecipe`。最终 `PhotographyDecision.replacingRecipe` 只刷新候选或一次修正后的实际配方，不从场景重新生成参数。

## 人物保护

人物照片继续禁用人脸专属提亮、橙色 HSL、过强降噪/锐化、几何变化和生成式处理。人物保护作为求解完成后的硬约束执行，不关闭全局曝光、白平衡、环境反差和整个人物/背景关系的摄影后期。

## 当前验证状态

- Windows 静态差异检查：已执行。
- Swift 单元测试：未执行；本机没有 Swift 工具链。
- iOS Simulator 编译：未执行；本机没有 Xcode。
- iPhone Vision/Core Image 真机出片：未执行。
- Git 提交、推送、TestFlight：未执行，遵守本轮“未经明确确认不得提交、推送或发布”的要求。

## 仍需验证

1. GitHub `iOS Build` 上的 Swift 编译和测试。
2. 不同 iPhone 设备上 Vision 蒙版的有效率、边缘质量、推理时间和内存峰值。
3. 真机原图与成片是否达到自然、协调且可感知的摄影改善。
4. 人像面部色相、纹理和身份特征是否在保存后的 JPEG 中保持一致。
