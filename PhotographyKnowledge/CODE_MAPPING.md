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
| PT-UNDERSTANDING-001 | `PhotoAnalysis.visualSceneUnderstanding`、`SubjectPriorityProfile`、`SkySegmentationService.semanticObjectMasks` | 不直接改像素；向规划器提供带来源与未知项的结构化证据；广覆盖环境构图不由低覆盖非固有主体类级区域劫持 | 类级蒙版不冒充实例识别；显著性不冒充对象身份；人物/动物/食物仍优先保护 | Build 27 真机已证实车辆类级区域曾错误取得主体优先；通用环境覆盖门控已修改，待新远程编译与真机复验 |
| PT-AESTHETIC-001 | `AestheticPhotographyPlanner` | 通过现有 `AdaptivePhotographyParameterSolver` 和主体/亮度蒙版执行视觉层级目标 | C 诊断路径专用；噪声、人物和蒙版质量限制 | 契约测试待远程 Apple 环境执行；iPhone 审美待盲测 |
| PT-AESTHETIC-002 | `PhotoRegionStatistics.yellowColorRatio/greenColorRatio`、`AestheticPhotographyPlanner` + 动态求解器 HSL/Color Grading | 现有 Core Image HSL、色彩分级、皮肤保护链；区域颜色分离目标与黄色 HSL 由可靠区域内颜色比例、共存关系及饱和度余量求解 | 颜色比例不冒充对象身份；无可靠区域、已饱和或人物保护风险高时为 0；禁止复制参考参数 | Build 28 实证：黄色 50.9% 但旧目标 separation=0、yellow HSL=0.0195；闭环修复与契约测试已加入，真机待复验 |
| PT-AESTHETIC-003 | `VisualSceneUnderstandingResult`、`AdaptivePhotographyTargetGenerator` | 参数安全上限、亮度区域与高光保护 | 氛围是约束而非固定参数来源 | 代码接入；多光照真机验证待执行 |
| PT-AESTHETIC-004 | `PhotoProcessingPipeline.evaluateMeasuredAestheticCandidate` 首轮结果 + `PhotoAnalyzer` 同定义复测 + `measuredAestheticFeedbackRecipe` | 仅 D 可执行最多一次有界完整分辨率重渲染；再次运行 `QualityCheckService` 与目标达成评分后择优 | 不改变 B；技术质检失败或目标无改善则保留首轮；不能把自动分数冒充审美结论 | Build 28 旧包尚无反馈；iOS Build #73 已通过 73 项决策测试与 Simulator 编译；新真机 Core Image 成片 ZIP 和人工盲测待验证 |
| PT-AESTHETIC-005 | `AestheticTargetHypothesisGenerator` | E1/E2 复用现有 `AestheticPhotographyPlanner`、`AdaptivePhotographyParameterSolver` 与完整分辨率 Core Image；只在诊断导入顺序执行 | 目标名称不绑定参数；所有数值来自当前图端点、噪声、可靠覆盖和区域颜色；不替换 B | Windows Build 29 同源分析已完成；Swift/真机 E1/E2 待远程验证 |
| PT-AESTHETIC-006 | `DiagnosticCandidateEvidence.targetQualityStatus/humanAestheticStatus`、诊断 ZIP | 分离技术状态、目标质量不确定性和人工盲测状态 | 无人工评价时固定为待评价；目标达成率不得冒充审美分 | 结构化代码已接入；远程编译和新真机 ZIP 待验证 |
| PT-AESTHETIC-007 | `AdaptiveRegionalTonePlanner`：全局/区域实测、可靠蒙版、逐图目标与颜色占比 | `AdaptiveRegionalTonePlan` 复用 `DiagnosticRegionalToneProcessor` 的区域曝光、七段曲线、端点保护和 HSL，并直接进入 D/E 全分辨率 Core Image | 不读取场景名称；人物保护不足、空/低质量蒙版时停用；中间亮度范围与羽化约束 | Build 31 根因已用真实 ZIP 量化；决策测试已加入，远程 Apple 编译/像素测试与新 iPhone 成片待验证 |
| PT-AESTHETIC-008 | `AdaptiveRegionalToneFeedbackSolver`：首轮真实区域影响、暗部/高光/细节和质检问题 | D 最多一次从原图重新进行全分辨率 Core Image 区域渲染；安全时补足原计划响应，风险时只收回受影响区域 | 不创造新目标、不进入 B、不放宽阈值；反馈成片质检失败时拒绝 | 参数方向与风险衰减测试已加入；远程 Apple 像素测试及 iPhone 同源 D 待验证 |
| PT-AESTHETIC-009 | `AestheticPhotographyPlanner` 读取当前图可靠地面/植被的亮度、饱和度、覆盖与蒙版可靠度；`AdaptiveRegionalTonePlanner` 求解区域相对亮度目标 | 只生成逐图的区域关系目标，并通过现有动态区域 Core Image 链执行；不读取 T、场景名或固定参数 | 证据不足返回 nil；暗部噪声与端点风险衰减；结果固定标记人工审美待验收 | Build 33 ZIP 已证实旧 D 的道路/植被亮度关系不足；方向与同标签不同测量测试已加入，远程 Apple 与真机新 D 待验证 |
| PT-AESTHETIC-010 | `AestheticTargetHypothesisGenerator`、`AestheticRegionalTargetIntent`、`AdaptiveRegionalTonePlanner`、`PhotographyTargetExplorationValidator` | 从当前图实测值分别求连续性、空间层级、克制深度的全局及区域目标；真实 Core Image 后比较 D/E1/E2 全图与区域像素 | 不读取场景预设或 T；人物证据不足停用区域增强；差异门槛只证明候选不同，不证明更美 | Build 34 的 0.0115/0.0083/0.0044 近似差异必须判探索无效；新目标需远程 Apple 像素测试、七图取证和人工盲测 |
| PT-AESTHETIC-011 | `PhotographyTargetProfile.measuredCinematicDiagnostic`、`AestheticTargetHypothesisGenerator`、`AestheticPhotographyPlanner`、`AdaptivePhotographyParameterSolver`、`AdaptiveRegionalTonePlanner` | 把当前图实测的中性环境、暖色占比、区域亮度关系与安全余量转换为冷灰环境、暖色重点、环境降色密度及 D/E1/E2 独立影调目标；继续使用同一 Core Image/HSL/区域曲线链 | 仅诊断；不读取 T/反求参数/场景预设；人物颜色强度衰减且源图相对保护；原质量阈值不变 | 代码与合成 Apple 像素测试待远程验证；秋季道路真机 ZIP 是首个实际验收，七图与人物随后验证 |
| PT-AESTHETIC-012 | `AestheticRegionalTargetIntent`、`AestheticPhotographyPlan`、`AdaptivePhotographyParameterSolver` | `CinematicColorGradingEngine.measuredCoolCinematic` 在扩展线性 sRGB 中分开处理暗部冷色、中间调冷色和弱高光暖色，并从中间调蒙版排除受保护亮部；`AutomaticEditingRecipe` 记录完整参数生命周期 | 只限 D/E 诊断；B 保持 legacy 数学；人物证据存在时因当前分级尚不能排除人物蒙版而关闭；场景失败/中性色/过曝/噪声继续限制 | Windows 忠实投影已生成秋季道路与跨场景图；真实 Core Image 合成像素测试及 iPhone 全分辨率审美仍待验收，Windows 结果不冒充 Apple 结果 |
| PT-UNDERSTANDING-002 | `VisualRegionEvidence`、`VisualRegionRelationshipEvidence`、`VisualSceneUnderstandingResult.make` | 复用 Vision 人物/显著性、Core ML 类级语义蒙版、蒙版质量与现有区域像素统计；只输出证据，不新建渲染器 | 道路必须来自道路类级蒙版；地面不冒充道路；显著性不冒充对象身份；无统计或低质量蒙版只能诊断/保护 | 结构化 JSON 与 Swift 契约测试待远程 Apple 验证；真实蒙版仍需 iPhone 叠加图人工核对 |
| PT-DIAGNOSIS-001 | `PhotoProblemDetector.structuredDiagnosis`、`PhotographyDiagnosisEvidence` | 复用现有问题检测、逐区证据和知识规则，输出测量依据、摄影意义、方向、副作用与 executable/analysisOnly 状态 | 不新增场景预设；证据不足不得宣称局部执行；人物局部诊断不会启用美颜/外貌修改 | 诊断 JSON 已接入；参数到像素的最终一致性仍以 Apple Core Image/iPhone 证据为准 |
| PT-QA-003 | `QualityCheckService` 首轮真实结果 + `ManualPhotographyParameters.safetyAdjustedForMeasuredRisks` | M/R3 最多一次有界安全修正、重渲染和重质检；保留实际采用参数 | 不放宽阈值、不进入 B；只有状态或问题数量改善才采用；真实人物仍禁止外貌修改 | Build 31 失败区域已量化；纯参数契约测试已加入，真实 Core Image 修正结果待远程及 iPhone 验证 |
| PT-QA-004 | `PhotographyDecision.recipeLifecycle`：求解器输出及五层限幅前后差异 | 诊断 ZIP 记录 planned/limited/rendered/measured 证据；不改变像素 | 生命周期记录不能成为第二参数来源；最终渲染值必须单独标识 | 阶段顺序测试已加入；远程编译与真机 ZIP 待验证 |
| PT-QA-005 | `QualityCheckService.colorIntegrity` 将源图中性色按人物/主体/建筑保护区与实际有意影调区归因；诊断 UI/ZIP 导出两类覆盖率及位移 | 保护区继续使用原 `-0.065` 阈值；有意影调区改由区域阴影增长、纹理能量、色偏及蒙版边缘共同约束 | 不关闭检查、不提高阈值；空蒙版、未执行计划与保护区重叠均按保护区处理 | Build 33 全分辨率归因：道路占主要损失，白车/主体与建筑位移很小；真实 Core Image 新包仍待验证 |
| PT-PREF-001 | `PhotographyCandidateEvaluation.preferenceEvidenceStatus/selectionBasis`、`PhoneValidationDataset/evaluation/blind-compare.html`、跨场景隔离清单 | 不产生像素；把工程代理选择与真实人工偏好分开记录，未来只在技术安全候选间校准轻量目标排序器 | 0 条人工记录时必须是 `notEvaluated`；不读取 T/反求参数；低置信度弃权 | 跨场景清单及通用 X/Y 盲测工具已建立；真实人工评价仍为 0，当前规则系统没有专业目标选择证据 |
| PT-PREF-002 | `PhotographyCandidateSetAssessor`、`DiagnosticBundleExporter.candidateSetAssessmentObject`、七图盲测会话 | 不产生像素；分别记录候选生成证据和候选选择证据 | 缺少 D/E1/E2 任一真实 Core Image 图时不得判断；技术失败不得参选；无人评时固定 `preferencePending` | 契约测试已加入；当前七图仍缺本版三候选真机导出，不能宣称生成或选择成功 |
| PT-V2-INTENT-001 | `SceneUnderstandingAdapterV2`、`PhotographyIntentGeneratorV2`：全图/区域亮度、对比、端点、颜色余量、中性色、人物与未知证据 | 不直接改像素；生成三种逐图关系目标，区域目标随当前测量重算 | 场景名称不提供参数；未知保持未知；空/低质量蒙版不生成语义局部目标 | Swift 契约测试与七图 Windows 投影待完成；真实视觉质量待 Apple/iPhone 盲测 |
| PT-V2-LOOK-001 | `AdaptiveLookGeneratorV2`、`AutomaticPhotographyDirectorV2` | 复用 `AutomaticEditingRecipe`、`AdaptiveRegionalTonePlan` 与 `CoreImageRenderer` 完整分辨率链；记录 planned/executed/rejected | 人物关闭环境色彩分级并限制白平衡；中性色、端点、噪声和蒙版继续走既有安全门 | 诊断路径已接入；Apple 编译、像素执行与真机导出待验证 |
| PT-V2-SELECT-001 | `AestheticCandidateSelectorV2`、V2 候选区域影响和 `QualityCheckService` | 不改像素；技术门后输出暂定 `V2-AUTO`，同时保留 V2-1/2/3 | 不奖励最大变化/最暗/最饱和；无人工偏好时必须标记 provisional/pending_human_review | 选择器测试与七图盲测待完成；没有证据可宣称专业审美选择成功 |
| PT-LEARN-001 | `LearningEnhancementPrototype` 的模型/权重清单与 manifest | 仅允许本地研究推理；不进入 Xcode target | 代码、权重、训练数据三层许可都需满足 | DeepLPF 权重因 FiveK 研究许可被阻止分发 |
| PT-LEARN-002 | `run_deeplpf_prototype.py` 的源图相对技术安全门 | 学习输出只作为隔离 C 候选；超限时拒绝 | 技术通过不等于审美通过；人物还需蒙版内比较 | 5 张真实手机图已运行，4 张被技术门拒绝 |
| PT-LEARN-003 | `run_semantic_probe.py`；iOS 现有 DETR/Vision 分割 | 可靠语义仅限制/保护学习变换；未知区域走亮度/全局协调 | 禁止把 background 推断为天空/道路/建筑/植被 | Windows 5 图实测完成；iOS DETR 真机仍待验收 |
| PT-TRAIN-001 | `import_training_pairs.py` + `training-pair.schema.json` + 许可清单 | 不直接渲染；生成含 SHA-256、配准相关性、用途和分区的训练 manifest | 专家目标、商业训练权、模型分发权缺一不可；不同帧拒绝 | 5 对旧算法样本导入；0 对产品合格；导入拒绝测试通过 |
| PT-TRAIN-002 | `bilateral_residual_model.py` + `train_bilateral_residual.py` | `12×12×8` 双边 RGB 仿射系数网格、显式恒等基线、有界 residual、边缘引导切片 | 当前只在 Windows 隔离；烟雾权重不可分发；Core ML/Metal 切片待证实 | RTX 5070 Ti 实际训练 20 epoch；29,509 参数；iPhone 未执行 |
| PT-TRAIN-003 | `photo_quality_metrics.py` + 人物/肤色训练约束 + `prepare_blind_comparison.py` | Lab 中性色、线性亮度、人物/肤色/纹理、裁切、饱和、光晕和局部对比拒绝；随机 B/C2 盲测 | 技术通过不等于审美通过；人物蒙版不可靠时不得伪造结论 | 12 项 Python 测试（最终以实际测试输出为准）；DeepLPF 5/5 被新安全门拒绝；人工评价仍为 0 |
| PT-TONE-001/003、PT-COLOR-001/003、PT-LOCAL-001/002 | `ManualPhotographyParameters`、`CoreImageRenderer.renderManualEdit`、单控制探针 | M 路径使用与 B/D 相同的完整分辨率 Core Image、色彩空间和 JPEG 编码链；曝光、高光、阴影、黑点、白平衡、HSL、亮度范围分别生成诊断探针 | 仅诊断导入；显式人工值不进入正式算法，也不代表审美方案 | Windows 静态接入完成；Swift 编译、参数方向和组合效果待远程 Apple 环境/真机验证 |
| PT-UNDERSTANDING-001、PT-AESTHETIC-001/002/003/004 | `PhotographyTargetProfile.measuredBaseline`、`enableMeasuredAestheticPlanning`、`evaluateMeasuredAestheticCandidate` | D 路径不读取摄影参考；源图相对目标、动态参数、完整分辨率渲染与一次有限复测构成可追踪闭环 | 仅诊断导入，不替换 B；技术代理不冒充审美结论 | Build 28 旧 D 已真机渲染但与 B 过近；新闭环待远程 Apple 环境及 iPhone ZIP 复验 |
| PT-INVERSE-001/002/003 | `PhotographyInverseSolver/inverse_solver.py`：SIFT/RANSAC 配准、有效区域、当前参数边界、全局后局部优化 | Windows 忠实复刻已公开的扩展线性 sRGB、EV、黑点以及曲线/HSL 两个 32³ 色彩立方体与线性域蒙版混合；输出全分辨率 R 与误差 | T 像素不得混合或复制到 R；扩展边界仅诊断；Apple 私有滤镜数学不冒充已复刻 | 秋季街道同源内点率 99.5%；修正后的当前边界 RGB MAE 0.1113、扩展探针 0.0652；真实 Core Image 与人工审美仍待验收 |
| PT-INVERSE-004 | `ManualPhotographyParameters.inverseR3Verification`、`ManualRegionalToneAdjustment`、`DiagnosticRegionalToneProcessor` | M 专用显式全局/区域曲线、曝光、高光阴影、黑白点、HSL、亮度范围蒙版；`QualityCheckService.measureRegionImpacts` 输出区域暗部/高光/细节证据 | B/D 边界不变；关闭 M 自动区域处理；私有滤镜偏差单独标注；无可靠蒙版跳过 | Build #76 证实旧 Windows 模拟与 Core Image 在 32³ 曲线插值、线性域 HSL/混合和曲线强度上不一致；模拟已修正并重新反求 R3-W，远程复验与真实 R3-I 待完成 |

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
