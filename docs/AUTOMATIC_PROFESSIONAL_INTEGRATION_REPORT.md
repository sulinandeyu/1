# 小苏相机自动专业摄影后期最终集成报告

更新时间：2026-11-10（Asia/Shanghai）  
开发分支：`codex/automatic-professional-integration-20261109`  
正式出片基线：小苏相机 1.0（Build 32），正式 B 未替换

## 1. 当前结论

本轮完成的是自动 D 的参数衰减根因修复、区域实测反馈闭环、参数生命周期证据以及 Apple 环境编译/像素测试。尚未取得本轮新 D 的真实 iPhone 全分辨率成片，因此不能宣布自动专业摄影效果已经通过，也不满足替换正式 B 或上传下一 TestFlight 的门槛。

已经证实：

- 现有 Core Image 区域渲染器具有明显影调表达能力；Build 31 的 M/R3-I 已在真实 iPhone 上形成强影调。
- 旧 D 的主要问题不是“没有渲染”，而是自动计划经过多层限制后偏弱、局部计划未根据渲染后区域残差继续修正，因此实际结果仍接近原图。
- 新代码已经把首轮实际区域测量和技术质检重新送入区域参数反馈，且 Apple Core Image 像素测试证明反馈后的参数会产生第二次真实像素响应。
- 技术正确不等于摄影审美通过；新 D 仍需同一原图真机出片和人工盲评。

## 2. 真实执行链

当前 D 诊断链为：

`原图` → `PhotoAnalyzer / Vision 区域分析` → `PhotoProblemDetector` → `PhotographyDecisionEngine` → `PhotographyTargetProfile / AestheticPhotographyPlanner` → `AdaptivePhotographyParameterSolver` → `applyAnalysisReliabilityLimits` → `applyProblemSafetyLimits` → `applyColorIntegrityGuards` → `enforcePortraitProtection` → `recipe.clamped()` → `AdaptiveRegionalTonePlanner` → `CoreImageRenderer.renderAutomaticEdit` → `QualityCheckService 区域实测` → `AdaptiveRegionalToneFeedbackSolver` → `第二次 Core Image 渲染` → `重新质检与目标/区域执行度量` → `D 诊断成片`。

关键代码位置：

- 参数求解和限制链：`MasterCamera/PhotographerAI/PhotographyDecisionEngine.swift`
- 参数定义和边界：`MasterCamera/ImageEngine/AutomaticEditingRecipe.swift`
- 全分辨率渲染入口：`MasterCamera/ImageEngine/CoreImageRenderer.swift`
- D 首轮/反馈渲染与选择：`MasterCamera/Processing/PhotoProcessingPipeline.swift`
- 结构化诊断 ZIP：`MasterCamera/QualityControl/DiagnosticBundleExporter.swift`
- 候选证据结构：`MasterCamera/QualityControl/ImageProcessingDiagnostics.swift`

## 3. 为什么 R3 有表现力，而自动 D 长期接近原图

### 3.1 已确认根因

1. `AdaptivePhotographyParameterSolver` 生成全局参数后，又依次经过分析可靠性、问题安全、颜色完整性、人物保护和最终产品边界。此前没有结构化记录每一层具体改动，导致“求解参数存在”和“最终渲染参数很弱”难以区分。
2. D 的区域参数此前继续乘以审美置信度。低置信度本应决定是否采用不可靠语义蒙版，却同时把已经由当前照片测量得到的曝光、曲线和 HSL 全部缩小。
3. 首轮反馈主要修正很小的全局参数，未根据地面、植被、天空和建筑的实际渲染响应修正区域计划。
4. 即使区域像素没有达到已生成目标，系统也可能因全局目标在容差内停止；这解释了日志中“目标达成率很高”但人工观感仍接近原图。
5. M/R3 使用更宽但隔离的诊断边界，能形成强表达；它同时暴露出暗部裁切、中性色损失和边界风险，所以不能直接复制到 D 或 B。

### 3.2 本轮修改

- 新增 `PT-AESTHETIC-008`：首轮渲染后的区域实测反馈。安全时只沿既有测量目标增强不足响应；出现阴影细节、中性色或蒙版边缘风险时，只收回受影响区域。
- 新增 `PT-QA-004`：参数生命周期审计，记录 `solverOutput → analysisReliabilityLimits → problemSafetyLimits → colorIntegrityGuards → portraitProtection → finalProductBounds → renderedSelection`。
- `AdaptiveRegionalTonePlanner` 不再用一个全局置信度连续衰减所有区域数值；置信度用于判断蒙版是否可靠，调整幅度继续来自当前照片的区域亮度、反差和黄色/绿色关系。
- D 反馈渲染同时携带最终选择的区域计划，重新测量真实像素并比较区域执行达成；不会把计划参数冒充执行参数。
- 质检风险映射为依赖中立的 `AdaptiveRegionalToneFeedbackRisks`，避免决策核心依赖 App 的 QualityControl 类型，同时保持阈值不变。

## 4. 参数证据

诊断 ZIP 的 `candidate_states_and_parameters.json` 现在包含结构化 `parameterLifecycle`：

- `stage`：哪个阶段修改参数。
- `recipeSummary`：该阶段完整配方。
- `changes`：相对上一阶段的实际字段变化。

D 还记录：

- 初始与最终实际配方。
- 选中的区域计划和蒙版执行信息。
- 首轮/反馈轮实际区域像素影响。
- 技术质检状态及问题。
- 全局目标达成与区域执行达成（明确标注不是审美分数）。
- 人工审美状态 `awaiting_blind_review`。

## 5. 已有真实图片证据

以下均为此前 Build 31 真机诊断的同源全分辨率输出，不是本轮新 D：

- `tmp/build31_diagnostic_20261109_193312/images/A_original.jpg`
- `tmp/build31_diagnostic_20261109_193312/images/B_formal_output.jpg`
- `tmp/build31_diagnostic_20261109_193312/images/D_automatic_diagnostic.jpg`
- `tmp/build31_diagnostic_20261109_193312/images/M_manual_render.jpg`
- 对照页：`output/build31_real_diagnosis/A_B_D_M_T_contact_sheet.jpg`
- 全分辨率指标：`output/build31_real_diagnosis/build31_full_resolution_metrics.json`

Build 31 关键实测：

| 图像 | 平均亮度 | 暗部占比 | 平均饱和度 | 相对 A RGB MAE |
|---|---:|---:|---:|---:|
| A 原图 | 0.6313 | 0.0654 | 0.1552 | — |
| B 正式 | 0.5800 | 0.0798 | 0.2143 | 0.0572 |
| 旧 D | 0.6132 | 0.0483 | 0.1748 | 0.0385 |
| M/R3-I | 0.3525 | 0.3840 | 0.3974 | 0.2821 |
| 外部 T（仅本地研究） | 0.3209 | 0.4746 | 0.3253 | 0.3090 |

这些数据说明旧 D 比 B 更接近原图，而 M/R3-I 已证明渲染器能够形成明显影调；同时 M/R3-I 的地面黑位与建筑中性色损失过大，不能直接作为正式结果。

## 6. Apple 环境验证

### 已通过

- iOS Build #93：提交 `3cb962e622a5a3606d4ea59bfcadbe7a2c22d256`，86/86 Swift 测试通过，iOS Simulator 构建成功。
- iOS Build #95：提交 `bd336ca884f097b20351d1280231b1ddb80dc189`，87/87 Swift 测试通过，iOS Simulator 构建成功。
- iOS Build #96：提交 `9306143944c22e3477ccb528b45ce677ec59d369`，87/87 Swift 测试通过，iOS Simulator 构建成功；诊断 ZIP 的机器可读生命周期结构完成编译验证。
- Build #95 新增真实 Core Image 像素测试：在区域反馈条件成立后，反馈配方经 `DiagnosticRegionalToneProcessor` 再渲染，输出亮度相对首轮产生可测的同方向变化。

### 失败并已修复

- iOS Build #92：决策核心错误引用 App-only `QualityIssue`，Swift Package 编译失败。改为 App 管线映射 `AdaptiveRegionalToneFeedbackRisks` 后修复。
- iOS Build #94：最初的像素测试把 10% 灰度软蒙版当作区域内实测，8-bit 输出量化后无变化。测试改为遵守 `PhotographyRegionImpact` 的区域测量契约，并使用真实 Core Image 全区域渲染验证反馈响应；未放宽产品质量阈值。

## 7. 安全与人物保护

- 未增加美颜、磨皮、祛痘、瘦脸、五官/脸型/体型修改或生成式重建。
- 人物保护仍位于最终产品边界前，并保留肤色和真实纹理约束。
- 反馈发现中性色损失、阴影细节损失或蒙版边缘风险时，仅衰减相关区域并提高亮度范围保护和羽化，不取消整张照片的摄影目标。
- 正式 B、正常拍照、原图保存和正式成片保存逻辑未改为 D。

## 8. 跨场景回归状态

自动测试已覆盖：

- 同场景不同曝光/颜色输入产生不同决策。
- 天空、地面、植被、建筑区域计划差异。
- 人物保护与肤色约束。
- HSL 色域隔离、白平衡方向、黑点中性、曝光/高光/阴影方向。
- 蒙版坐标、亮度范围保护和中性参数零变化。
- 区域反馈增强不足响应、风险定点收回及真实 Core Image 像素响应。

尚未完成：本轮新 D 在人物、室内、夜景、建筑、静物和自然场景的真实 iPhone 全分辨率人工盲评。自动测试只能证明数学和工程契约，不能代替摄影审美。

## 9. 发布与正式 B 状态

- 当前 TestFlight 基线仍为 Build 32。
- 本轮没有上传新 TestFlight，没有合并正式分支，没有替换 B。
- 新自动摄影代码仍在独立分支和诊断 D 路径。
- 当前已验证源码 SHA：`9306143944c22e3477ccb528b45ce677ec59d369`。

不满足替换 B 的具体原因：

1. 缺少本轮新 D 的真实 iPhone 同源全分辨率成片。
2. 缺少 A/B/新 D 的人工盲评结果。
3. 缺少人物、室内、夜景、建筑、静物、自然场景的真机回归。
4. 尚不能证明自动审美目标选择在人类偏好上稳定优于旧 B。

## 10. 对四个最终问题的回答

### 第一：为什么 R3 接近目标，而自动 D 始终接近原图？

R3 使用隔离的宽表达边界；旧 D 的测量结果在多层安全限制、置信度缩放和仅全局的小幅反馈后被连续削弱，区域实际残差没有驱动第二轮区域参数。渲染器能表达，自动决策闭环没有充分调用它。

### 第二：有表现力的参数控制是否真正接入自动决策和 iOS 渲染链？

代码层面已接入 D：区域计划由当前照片测量生成，进入同一个全分辨率 Core Image 渲染器；首轮真实区域像素和质检再驱动一次有界区域修正。Apple 像素测试已证明反馈会改变实际输出。它仍限定在诊断 D，未接管正式 B。

### 第三：不提供 T 时，现在能否自主生成明显、协调且技术合格的成片？

尚不能下结论。本轮代码满足自主规划和真实渲染链要求，但还没有本轮新 D 的真实 iPhone 成片与人工视觉证据。Build 31 的旧 D 不达标，不能用新代码的测试通过替代新成片验收。

### 第四：是否满足替换正式 B 的条件？

没有。缺失项是新 D 真机图片、跨场景真机回归、人工盲评和人物真实性实拍验证。在这些证据完成前，正式 B 必须保留。

