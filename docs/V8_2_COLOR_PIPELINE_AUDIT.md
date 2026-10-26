# 小苏相机 V8.2 色彩管线审计

## 结论

V8.1 的实拍问题不是渲染未执行，而是多个有效模块产生了叠加偏差：场景分支先写入 HSL 和冷暖参数，`applyCinematicStrategy` 又给绝大多数场景强制添加冷阴影、暖中高光和电影曲线，随后 `CoreImageRenderer` 依次执行普通曲线、电影曲线、白平衡、HSL 和三段色彩分级。质量检查只专门拦截新增青偏，无法阻止橙黄肤色、黄绿色中性色和阴天蓝染。

## 已核对的真实链路

1. `PhotographyDecisionEngine.makeDecision` 根据实测分析和场景生成配方。
2. `PhotographyCandidatePlanner` 生成自然、层次和问题定向三个候选。
3. `CoreImageRenderer.renderPipeline` 按以下顺序处理实际像素：曝光 → 高光阴影 → 黑位 → 五点曲线 → 七段电影影调 → 亮度蒙版 → 白平衡 → 全局色彩 → 自然饱和度 → 分区 HSL → 三段色彩分级 → 局部蒙版 → 细节与镜头质感。
4. 候选与最终全分辨率渲染共用同一配方和渲染器。
5. 输出在 `extendedLinearSRGB` 工作空间处理，JPEG 以 sRGB 编码；没有发现重复套用 ICC 配置或保存阶段重新调色。

## 已确认根因

### 1. 强制电影色彩覆盖了场景真实性

V8.1 的 `applyCinematicStrategy` 会给 natural/standard/dramatic 三种强度强制写入冷阴影、暖中间调、暖高光和色彩对比。人物、阴天建筑、白车及阴天植被都因此得到不需要的分离色调。

V8.2 改为：电影强度主要控制影调形状，色彩分级只保留场景分支已经有证据支持的部分，并设置更低上限。阴天和大面积中性色场景再执行最终保护门禁。

### 2. 曲线重复抬黑和压白

普通五点曲线和七段电影曲线都存在非零黑点及偏低白点。两层叠加后，自拍黑色头发和衣物变灰，阴天高光则被明显压暗。

V8.2 将自然、人物、风景、室内和工作区曲线的黑点归零，提高安全白点，仅给 low-key 留极小黑位偏移。曲线仍然可以塑造中间调，但不再默认制造“灰黑”。

### 3. HSL 在错误的感知域中计算

Core Image 工作空间是扩展线性 sRGB，V8.1 的 HSL LUT 却直接对线性 RGB 做 HSV 计算。V8.2 在 LUT 内先转为编码 sRGB，再做 H/S/L，最后回到线性 RGB；同时加入真正的 hue 参数，而不是只有饱和度和亮度。

### 4. 质量门禁缺少肤色和中性色

V8.1 只检查全局青偏，且人物检查主要比较面部与背景的相对变化。当整张图共同变暖时仍可能通过。

V8.2 新增源图相对检查：从原图识别低色度中性像素以及人脸内保守皮肤样本，测量染色、冷暖、绿偏、亮度损失和肤色偏移。异常候选被拒绝，风险同时进入候选评分与一次性修正配方。

## 色彩管理边界

- 输入由 Core Image 按方向信息解码。
- 工作空间固定为 extended-linear sRGB。
- HSL 在 perceptual sRGB 中计算后回到线性空间。
- 最终 JPEG 固定输出 sRGB。
- 当前没有 RAW/Display P3 端到端真机样片，因此不声称广色域流程已验收。

## 依据

- Adobe Lightroom 的 Color Mixer 将 Hue、Saturation、Luminance 作为针对特定颜色的独立控制，而不是用全局饱和度替代：[Adobe Adjust Color](https://helpx.adobe.com/lightroom/web/edit-photos/apply-effects/adjust-color.html)
- Adobe 对 Tone Curve 的定位是调整具体影调范围：[Adobe Tone Curve](https://helpx.adobe.com/lightroom/mobile/adjust-light-and-color/adjust-tonal-range-using-curve.html)
- Adobe Masking 用于隔离局部调整：[Adobe Masking](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/masking.html)
- 本项目仍使用 Apple Core Image 的 `CIColorControls` 与 `CIHighlightShadowAdjust` 执行受控像素处理：[CIColorControls](https://developer.apple.com/documentation/coreimage/cicolorcontrols)、[CIHighlightShadowAdjust](https://developer.apple.com/documentation/coreimage/cihighlightshadowadjust)

## 验证状态

- 代码审计：完成。
- 四组 V8.1 实拍基线量化：完成。
- Windows 静态差异检查：完成。
- Swift 自动测试：未执行，本机没有 Swift 工具链。
- iOS/Core Image 构建与 V8.2 真机成片：未执行，必须经现有 GitHub Actions/TestFlight 流程完成。
