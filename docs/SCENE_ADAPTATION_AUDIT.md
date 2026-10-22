# 场景自适应后期根因审计（2026-10-22）

## 审计范围与证据等级

本次只追踪现有链路：

`PhotoAnalyzer` → `PhotoProblemDetector` → `SceneStrategy` →
`PhotographyDecisionEngine` → `CoreImageRenderer` → `QualityCheckService`。

旧对话附件中找回了三组真实手机实拍的 App 对比截图：清晨城市、晴天广场、
阴天海边。附件不是原始 JPEG/HEIC，所以本次可以确认截图内可见像素的变化方向，
不能确认 EXIF、原始动态范围或设备端 Vision/Core ML 的逐项输出。仓库仍需要用原始照片
在真机“样片复测”入口完成最终验收。

## 真实输入截图级追踪

按 `PhotoAnalyzer.pixelStatistics` 的同类阈值，从截图中的照片区域缩放采样。数值会受到
截图压缩和界面覆盖影响，仅用于比较同一组原图/成片的变化方向。

| 场景 | 版本 | 平均亮度 | 5–95% 对比跨度 | RGB 均值 | 平均饱和度 | 青/冷暖混合代理 |
|---|---|---:|---:|---|---:|---:|
| 清晨城市 | 原图 | 0.333 | 0.474 | 0.337 / 0.336 / 0.297 | 0.251 | 0.000 |
| 清晨城市 | AI 成片 | 0.328 | 0.462 | 0.330 / 0.331 / 0.287 | 0.256 | 0.024 |
| 晴天广场 | 原图 | 0.459 | 0.647 | 0.448 / 0.461 / 0.468 | 0.168 | 0.025 |
| 晴天广场 | AI 成片 | 0.468 | 0.626 | 0.448 / 0.473 / 0.483 | 0.234 | 0.124 |
| 阴天海边 | 原图 | 0.480 | 0.604 | 0.465 / 0.483 / 0.496 | 0.144 | 0.030 |
| 阴天海边 | AI 成片 | 0.493 | 0.547 | 0.464 / 0.500 / 0.518 | 0.182 | 0.133 |

晴天广场和阴天海边都表现为红通道基本不变、绿蓝通道和饱和度同步上升，且对比跨度
下降。这与用户看到的“不同场景都像同一种青蓝处理”一致；清晨城市则变化很小。

## 文件/函数级根因

### 1. 多标签在策略入口被错误压平

- `PhotoAnalyzer.classifyScene` 会保留最多八个 Vision 标签。
- 旧 `PhotoAnalysis.semanticScene` 先匹配泛化的 `outdoor`，再匹配 food、architecture、
  landscape、workspace、indoor。
- 旧 `SceneStrategy.choose` 直接采用这个单标签。只要标签集合中含 `outdoor`，海岸、天空、
  建筑等更具体证据就无法选择对应策略。

因此“识别到了多个场景标签”不等于“具体标签真正驱动了场景策略”。

### 2. 不同场景在后段重新收敛为同一电影调色基线

- `PhotographyDecisionEngine.applySceneStrategy` 确实产生不同曲线、HSL 和局部参数。
- 随后的 `applyCinematicStrategy` 对 landscape、outdoor、architecture 等大量场景都选择
  `standard`，并用 `max` 注入相同的 `colorGradeIntensity=0.4`、
  `shadowCoolAmount=0.28`、`midtoneWarmAmount=0.24`、
  `highlightWarmAmount=0.34` 基线。
- 旧 `applyContextStrategy` 对 professionalLandscape 和 urbanArchitecture 没有把这些公共
  色彩基线约束回各自场景目标。

这不会让配方完全相同，但公共全局调色足以成为最醒目的变化，遮蔽前面较小的场景差异。

### 3. 天空处理是少量固定档位，且无蒙版时完全不执行

- 旧 `applySkyStrategy` 对 landscape、outdoor、brightOutdoor、highContrast 共用一组数值，
  只根据 `clippedHighlights` 二选一。
- `SkyAdjustmentProcessor` 只有在有效天空蒙版存在时才执行。这一安全边界是正确的，但
  意味着“识别到 sky 标签”本身不会产生天空局部处理。

因此阴天海边和晴天广场即使都识别到天空，也可能得到同档天空参数；模型无有效蒙版时，
则只剩全局电影调色和 HSL。

### 4. 质检修正后的真实配方与界面诊断配方不一致

- `PhotoProcessingPipeline.chooseFinalEdit` 可能用 `correctiveRecipe` 完成第二次渲染。
- 旧返回对象仍保存初始 `decision`，诊断界面从 `decision.recipe` 展示参数。

像素并未使用错误配方，但日志/界面会让排障者看到一个没有真正生成最终 JPEG 的配方，
破坏了“识别 → 决策 → 渲染 → 输出”的证据闭环。

## 已实施的最小修复

1. `SceneStrategy.choose` 先读取 `PhotographyContext` 的多标签 facets 与 lighting，再回退到
   旧 `semanticScene`。泛化 `outdoor` 不再覆盖 coast/water/architecture/workspace 等证据。
2. 保留现有 cinematic 引擎，但在 `applyContextStrategy` 中按 blue hour、golden hour、portrait、
   interior、urban architecture、professional landscape、still life、documentary 分别限制
   三段调色强度，避免公共 `standard` 成为主视觉模板。
3. `applySkyStrategy` 按高光余量、对比跨度、饱和度余量连续计算天空曝光、高光与饱和度；
   阴天证据会限制天空增艳。仍坚持“无有效蒙版不做天空局部处理”。
4. 新增 `PhotoAnalysis.traceSummary` 与 `AutomaticEditingRecipe.traceSummary`；管线记录完整标签、
   facets、lighting、mask 可用性、初始配方、渲染器收到的配方以及最终配方。
5. 若质检采用修正版配方，`CapturedPhoto.decision.recipe` 现在同步为最终实际配方。

## 验收测试

`Package.swift` 把纯 Foundation 的分析/决策代码组成独立测试模块；
`MasterCameraDecisionCoreTests/SceneAdaptationTests.swift` 覆盖：

1. `outdoor + seashore + ocean + sky` 必须进入 landscape，而不是旧 outdoor。
2. `outdoor + building + architecture + sky` 必须进入 architecture。
3. 技术统计相同、语义不同的海岸与广场必须输出不同策略、HSL、调色强度和完整配方追踪。
4. 阴天天空与晴天天空不能得到同一固定天空预设。

CI 在 iOS Simulator 构建前运行 `swift test`。Windows 工作区没有 Swift/Xcode，因此本轮已完成
源码/项目结构与 `git diff --check` 验证，但不能在本机伪称 Xcode 编译或 Core Image 像素验收通过。

## 真机最终验收步骤

至少导入两张原始照片（建议阴天海边与晴天广场），在 Console 过滤 `ImageEngine`：

1. 核对“分析完成”中的 labels/facets/lighting/style 与画面一致。
2. 核对“决策完成”和“渲染器收到配方”的 trace 完全一致。
3. 若发生一次修正，核对“处理完成”的最终配方与诊断面板一致。
4. 阴天海边不应增加天空蓝色饱和度；晴天广场可适度增强天空，但建筑/地面不能同步染青。
5. 两张成片的 `sceneStrategy`、HSL、grade 或 sky 参数至少有一组摄影意义明确的差异。
6. 保存原图、成片、Console trace 和诊断面板截图，作为首个原始样片验收包。

