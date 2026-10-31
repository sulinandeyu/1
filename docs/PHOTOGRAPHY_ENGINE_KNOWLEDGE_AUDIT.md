# 小苏相机摄影知识接入审计

日期：2026-10-27

## 生产链路结论

当前 `PhotographyDecisionEngine.makeDecision` 会调用 `AdaptivePhotographyParameterSolver`，再把同一份 `AutomaticEditingRecipe` 交给候选计划与 `CoreImageRenderer`。因此本阶段没有另建平行引擎，而是在现有分析—求解—渲染链上修复证据来源与 API 映射。

## 已证实问题与修复

### 1. 肤色容易偏橙红、主体颜色会被误判为色偏

- 原因：`PhotoAnalysis.colorCast`、`PhotoProblemDetector.detectColorProblems` 和 `AdaptivePhotographyParameterSolver.solve` 依赖整幅图 R/G/B 均值。人物肤色、橙色果实、蓝天和植被都可能改变全图均值。
- 修复：`PhotoAnalyzer` 新增排除人脸、限制亮度与色度、检查覆盖率和空间分布的 `NeutralColorStatistics`。只有证据可靠时才诊断色偏和计算白平衡；人物肤色不再充当参考白。
- 规则：PT-COLOR-001、PT-COLOR-002、PT-PORTRAIT-002。
- 剩余边界：这是 sRGB 低分辨率证据，不是 RAW 域照明估计模型；复杂混合光仍需真机样片验证。
- 校准说明：覆盖率、色度、偏差阈值属于保守工程门槛，不冒充 Adobe/Apple 的推荐参数，后续必须用真实灰/白物体和人物样片校准。

### 2. 白色物体可能染黄或染绿

- 原因：`CoreImageRenderer.applyWhiteBalance` 过去把固定 6500K 写入 `neutral`，把偏移写入 `targetNeutral`，与 Apple 文档定义的“源白点→目标白点”相反。
- 修复：全局与局部渲染都将动态估计写入源白点 `neutral`，目标写为中性 6500/0；没有可靠中性色证据时参数保持 0。
- 规则：PT-COLOR-001、PT-COLOR-003。
- 剩余边界：Core Image tint 方向和幅度需要在 iPhone 上用灰/白物体与人物混合样片确认；当前不标记真机通过。

### 3. 阴天天空偏青蓝

- 当前保护：求解器只在可靠天空蒙版内计算天空 HSL；阴天分支禁止增加蓝色饱和度，并限制温度、色调和色彩分级。
- 本阶段增强：全局白平衡不再根据蓝天或灰天改变后的全图 RGB 均值触发。
- 规则：PT-COLOR-001、PT-LOCAL-001。
- 待验证：Vision 分割与最终 Core Image 成片只能在 Apple 环境验证。

### 4. 黑位容易发灰

- 当前实现：黑点只在黑位稀少且反差不足时建立；阴影恢复使用“阴影比例减纯黑比例”的可恢复量，并受噪声和夜景氛围限制。
- 风险：候选评分若过度奖励端点安全，仍可能选择层次过弱的版本；若阴影提升较大，也可能造成灰雾。
- 规则：PT-TONE-001、PT-TONE-002、PT-TONE-003。
- 待验证：至少以夜景、阴天和室内样片检查黑位、暗部噪声和中间调层次。

### 5. 不同场景使用相似参数

- 现状：生产求解器已从当前照片亮度、反差、端点、饱和度、噪声、混合光和可靠区域统计连续求值；相同像素测量即使标签不同也应得到相同技术配方。
- 遗留：`PhotographyDecisionEngine.swift` 仍保留旧场景策略函数和固定风格代码，但当前 `makeDecision` 不调用它们。为避免无证据的大规模删除，本阶段只在文档标记为遗留代码。
- 验证：现有测试覆盖相同像素/不同标签配方一致，以及同场景不同曝光得到相反曝光方向。

### 6. 局部蒙版计划与最终渲染可能不一致

- 当前保护：`NormalizedPhotoMask.qualityAssessment` 检查空、过宽和碎片蒙版；失败时局部语义处理跳过，亮度范围处理作为安全降级。
- 风险：Windows 无法执行 Vision/Core Image，候选分辨率与全分辨率坐标/方向仍需 iPhone 诊断页的覆盖率、区域影响和最终文件标识验证。
- 规则：PT-LOCAL-001、PT-LOCAL-002。

### 7. 候选选择可能偏向错误结果

- 当前能力：质量检查可以拦截裁切、颜色完整性和人物风险；人工偏好脚本可记录 A/B/C/原图/都不好。
- 缺口：没有足够授权参考案例和人工选择数据，自动评分不能被称为专业审美模型。
- 规则：PT-QA-001、PT-QA-002。

## 本阶段代码映射

- `MasterCamera/Analysis/PhotoAnalyzer.swift`：中性色候选采样与置信度。
- `MasterCamera/Analysis/PhotoAnalysis.swift`：`NeutralColorStatistics`、诊断摘要和可靠性色偏状态。
- `MasterCamera/Analysis/PhotoProblemDetector.swift`：基于可靠中性色的色偏诊断。
- `MasterCamera/PhotographerAI/PhotographyDecision.swift`：知识规则 ID 与授权参考案例数据结构。
- `MasterCamera/PhotographerAI/PhotographyDecisionEngine.swift`：可靠证据驱动的白平衡求解、参数—规则映射。
- `MasterCamera/ImageEngine/CoreImageRenderer.swift`：Core Image 源白点到目标白点的正确方向。
- `MasterCamera/Processing/PhotoProcessingPipeline.swift`、`MasterCamera/Models/PhotoDiagnostics.swift`：日志和诊断页显示知识规则及中性色证据。

## 验证状态

- 文档来源核验：完成。
- 知识库与代码映射：完成。
- Windows 静态检查：进行中。
- Swift 自动测试：当前 Windows 无 Swift 工具链，未执行。
- iOS Vision/Core Image 端到端：未执行。
- 真实视觉质量验收：未执行。
