# 摄影技术与代码映射

| 规则 | 测量/决策 | 像素实现 | 边界 | 当前验证状态 |
|---|---|---|---|---|
| PT-TONE-001 | `PhotoAnalyzer.pixelStatistics`、`AdaptivePhotographyTargetGenerator`、`AdaptivePhotographyParameterSolver` | `CoreImageRenderer` 曝光、高光阴影、黑点、曲线 | 端点裁切与氛围保护 | 决策测试已有；iPhone 视觉待验收 |
| PT-TONE-002 | `noiseEstimate`、shadow/black ratio | 阴影恢复、亮度蒙版、降噪 | 夜景/高噪声减弱 | 决策测试已有 |
| PT-COLOR-001 | `NeutralColorStatistics`、`PhotoProblemDetector` | `CITemperatureAndTint` 源白点→目标白点 | 覆盖率、混合光、人物保护 | 本阶段接入；真机待验收 |
| PT-COLOR-003 | `PhotoAnalyzer` sRGB 测量 | 扩展线性 sRGB 工作空间、sRGB 输出、编码域 HSL | 禁止滑块单位直传 | 静态确认；真机导出待验收 |
| PT-LOCAL-001 | `NormalizedPhotoMask.qualityAssessment` | `LocalAdjustmentProcessor`、`SkyAdjustmentProcessor` | 空/宽/碎片蒙版跳过 | 自动测试已有；Vision 真机待验收 |
| PT-LOCAL-002 | 亮度区间残差 | `LuminanceZoneProcessor` | 不冒充语义局部精修 | 自动测试已有 |
| PT-DETAIL-001 | `detailScore`、`noiseEstimate` | 降噪、锐化、局部对比 | 人物与高噪声上限 | 决策测试已有；100% 真机观察待验收 |
| PT-PORTRAIT-001 | 人脸/人物/皮肤蒙版与源图比较 | 全局摄影处理、人物安全限制 | 禁止美颜与生成 | 静态与决策测试已有；真实人物真机待验收 |
| PT-QA-001 | `QualityCheckService`、候选评分、人工偏好脚本 | 候选选择/回退 | 技术分不等于美学分 | 工具已存在；标注样本不足 |
| PT-REF-001 | `PhotographyReferenceMatcher`：当前图影调/色彩/中性色 + 语义辅助 + 许可门控 | 不产生像素参数，只返回适用性、置信度和不可迁移项 | 生产许可关闭、低置信度回退、语义不直接绑定参数 | Windows 30 查询已运行；iPhone 待验证 |
| PT-REF-002 | `PhotographyReferenceTargetGenerator` + `AdaptivePhotographyParameterSolver(targetProfile:)` | 继续复用现有 Core Image 配方与局部处理 | 校准权重有界；不复制白平衡/HSL/曲线/直方图 | Swift 测试已写；Windows 无 Swift，远程/Apple 环境待执行 |
| PT-REF-003 | `PhotoProcessingPipeline.evaluateReferenceCandidate` | 诊断导入生成 A/B/C，C 单独 Core Image 渲染与质检 | C 不替换 B；正式拍照不运行；失败明确记录 | 静态接入完成；iPhone 真机待执行 |
| PT-UNDERSTANDING-001 | `PhotoAnalysis.visualSceneUnderstanding`、`SkySegmentationService.semanticObjectMasks` | 不直接改像素；向规划器提供带来源与未知项的结构化证据 | 类级蒙版不冒充实例识别；显著性不冒充对象身份 | Windows 静态接入完成；远程 Swift/iOS 编译与真机蒙版待验证 |
| PT-AESTHETIC-001 | `AestheticPhotographyPlanner` | 通过现有 `AdaptivePhotographyParameterSolver` 和主体/亮度蒙版执行视觉层级目标 | C 诊断路径专用；噪声、人物和蒙版质量限制 | 契约测试待远程 Apple 环境执行；iPhone 审美待盲测 |
| PT-AESTHETIC-002 | `AestheticPhotographyPlanner` + 动态求解器 HSL/Color Grading | 现有 Core Image HSL、色彩分级、皮肤保护链 | 无可靠区域/混合光证据时为 0；禁止复制参考参数 | 代码接入；肤色与中性色真机验证待执行 |
| PT-AESTHETIC-003 | `VisualSceneUnderstandingResult`、`AdaptivePhotographyTargetGenerator` | 参数安全上限、亮度区域与高光保护 | 氛围是约束而非固定参数来源 | 代码接入；多光照真机验证待执行 |

## 已证实差距

1. 旧白平衡诊断使用全图 RGB 均值，不能区分照明色偏与主体固有颜色。
2. `CITemperatureAndTint` 已修正为 Apple 定义的“实测源白点→中性目标白点”；源白点仍是 sRGB 低分辨率近似估计，不能宣称具备专业 RAW 域 AWB。
3. 局部蒙版有可靠度检查，但 Vision/Core Image 只能在 Apple 运行环境完成真实端到端验证。
4. 候选评价已有技术指标，专业审美仍需经过授权案例和人工偏好校准。
5. 内置 DETR panoptic 模型此前只输出五组环境蒙版；本阶段复用同一模型增加类级人物、车辆、动物、食物/果实、工作区、人工光源和道路证据，但它仍不具备摄影意图或实例关系理解。
6. 新审美规划目前只进入隔离的 C 诊断路径，不替换 B；是否更好看必须等远程编译、iPhone Core Image 成片和人工盲测。

## 摄影数据集对接状态

| 数据环节 | 现有实现 | 生产接入状态 | 边界 |
|---|---|---|---|
| 来源与许可 | `PhotographyDataset/licenses/source-registry.json`、逐文件 manifest | 数据准备完成 | CC BY-SA 和所有内容风险样本在商业训练前必须复核 |
| 当前照片/参考特征 | `scripts/Measure-PhotographyDataset.ps1` 输出亮度分位、色相、饱和度、冷暖、中性色、局部对比、中心/边缘代理 | Windows 数据集特征已生成；未接入生产求解 | 缩小 sRGB 统计不是 RAW、Core Image 或主体识别 |
| 动态目标检索 | `PhotographyReferenceMatcher` 使用许可过滤索引、连续测量与语义辅助，返回相似依据、置信度和不可迁移项 | 仅诊断导入接入 | 不允许按类别直接取参数或 LUT；不足时回退 |
| 参数求解 | `PhotographyReferenceTargetGenerator` 先生成当前图基线，再有限校准；`AdaptivePhotographyParameterSolver(targetProfile:)` 仍是唯一参数求解器 | 仅 C 候选读取参考目标；B 不变 | 白平衡/HSL/曲线仍来自当前图测量，安全规则优先 |
| 候选渲染与评价 | `PhotoProcessingPipeline` 生成 A/B/C；C 复用 `CoreImageRenderer` 和 `QualityCheckService` | 诊断导入开启，正式拍照关闭 | 必须真机真实渲染；统计接近参考不等于更美 |
| 验证隔离 | 220 参考 + 30 验证，ID/URL/SHA256 不重合 | 数据完整性测试通过 | 当前验证图多为优秀成片，仍缺普通手机原图与专家目标配对 |
