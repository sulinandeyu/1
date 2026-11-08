# 摄影技术与代码映射

| 规则 | 测量/决策 | 像素实现 | 边界 | 当前验证状态 |
|---|---|---|---|---|
| PT-TONE-001 | `PhotoAnalyzer.pixelStatistics`、`AdaptivePhotographyTargetGenerator`、`AdaptivePhotographyParameterSolver` | `CoreImageRenderer` 曝光、高光阴影、黑点、曲线 | 端点裁切与氛围保护 | 决策测试已有；iPhone 视觉待验收 |
| PT-TONE-002 | `noiseEstimate`、shadow/black ratio | 阴影恢复、亮度蒙版、降噪 | 夜景/高噪声减弱 | 决策测试已有 |
| PT-COLOR-001 | `NeutralColorStatistics`、`PhotoProblemDetector` | `CITemperatureAndTint` 动态温度/色调调整映射 | 覆盖率、混合光、人物保护 | macOS 像素方向测试已加入；iPhone 视觉待验收 |
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
| PT-LEARN-001 | `LearningEnhancementPrototype` 的模型/权重清单与 manifest | 仅允许本地研究推理；不进入 Xcode target | 代码、权重、训练数据三层许可都需满足 | DeepLPF 权重因 FiveK 研究许可被阻止分发 |
| PT-LEARN-002 | `run_deeplpf_prototype.py` 的源图相对技术安全门 | 学习输出只作为隔离 C 候选；超限时拒绝 | 技术通过不等于审美通过；人物还需蒙版内比较 | 5 张真实手机图已运行，4 张被技术门拒绝 |
| PT-LEARN-003 | `run_semantic_probe.py`；iOS 现有 DETR/Vision 分割 | 可靠语义仅限制/保护学习变换；未知区域走亮度/全局协调 | 禁止把 background 推断为天空/道路/建筑/植被 | Windows 5 图实测完成；iOS DETR 真机仍待验收 |
| PT-TRAIN-001 | `import_training_pairs.py` + `training-pair.schema.json` + 许可清单 | 不直接渲染；生成含 SHA-256、配准相关性、用途和分区的训练 manifest | 专家目标、商业训练权、模型分发权缺一不可；不同帧拒绝 | 5 对旧算法样本导入；0 对产品合格；导入拒绝测试通过 |
| PT-TRAIN-002 | `bilateral_residual_model.py` + `train_bilateral_residual.py` | `12×12×8` 双边 RGB 仿射系数网格、显式恒等基线、有界 residual、边缘引导切片 | 当前只在 Windows 隔离；烟雾权重不可分发；Core ML/Metal 切片待证实 | RTX 5070 Ti 实际训练 20 epoch；29,509 参数；iPhone 未执行 |
| PT-TRAIN-003 | `photo_quality_metrics.py` + 人物/肤色训练约束 + `prepare_blind_comparison.py` | Lab 中性色、线性亮度、人物/肤色/纹理、裁切、饱和、光晕和局部对比拒绝；随机 B/C2 盲测 | 技术通过不等于审美通过；人物蒙版不可靠时不得伪造结论 | 12 项 Python 测试（最终以实际测试输出为准）；DeepLPF 5/5 被新安全门拒绝；人工评价仍为 0 |
| PT-TONE-001/003、PT-COLOR-001/003、PT-LOCAL-001/002 | `ManualPhotographyParameters`、`CoreImageRenderer.renderManualEdit`、单控制探针 | M 路径使用与 B/D 相同的完整分辨率 Core Image、色彩空间和 JPEG 编码链；曝光、高光、阴影、黑点、白平衡、HSL、亮度范围分别生成诊断探针 | 仅诊断导入；显式人工值不进入正式算法，也不代表审美方案 | Windows 静态接入完成；Swift 编译、参数方向和组合效果待远程 Apple 环境/真机验证 |
| PT-UNDERSTANDING-001、PT-AESTHETIC-001/002/003 | `PhotographyTargetProfile.measuredBaseline`、`enableMeasuredAestheticPlanning`、`evaluateMeasuredAestheticCandidate` | D 路径不读取摄影参考，直接将当前图测量、问题、视觉关系送入现有求解器并进行完整分辨率渲染 | 仅诊断导入，不替换 B；技术代理不冒充审美结论 | 决策契约测试已增加但 Windows 无 Swift；iPhone A/B/D 视觉盲测待执行 |

## 已证实差距

1. 旧白平衡诊断使用全图 RGB 均值，不能区分照明色偏与主体固有颜色。
2. `CITemperatureAndTint` 的输入仍遵守 Apple 的 `neutral` / `targetNeutral` API 语义；项目中的 `temperatureShift` / `tintShift` 是求解器输出的校正方向，不冒充 RAW 域绝对色温。正负方向由真实 Core Image 像素测试约束，仍需 iPhone 视觉验收。
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
