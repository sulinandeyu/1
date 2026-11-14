# Automatic Photography Director V2 进度

更新时间：2026-11-15

## 当前阶段

V2 最小端到端实现已接入隔离诊断路径，尚未替换正式 B，也尚未经过 iPhone 人工摄影审美验收。

## 已完成

- 新建 `AutomaticPhotographyDirectorV2`，以现有结构化视觉证据、摄影问题和当前照片测量为输入。
- 新建 `SceneUnderstandingAdapterV2`，保留证据可靠度、人物/中性色保护和未知项；`ground` 不被声明为 `road`。
- 新建 `PhotographyIntentGeneratorV2`，为同一照片生成自然纪实、空间层次、氛围电影三种关系目标；场景名称不提供参数。
- 新建 `AdaptiveLookGeneratorV2`，把摄影意图映射为既有 `AutomaticEditingRecipe` 与 `AdaptiveRegionalTonePlan`，复用正式 Core Image 算子。
- 新建 `AestheticCandidateSelectorV2`，先排除技术失败候选，再进行明确标记为 provisional 的可解释选择；不奖励最大 RGB 差异、最暗或最饱和。
- `PhotoProcessingPipeline` 的相册诊断导入会串行执行 V2-1/V2-2/V2-3 全分辨率渲染、技术质检、区域复测和 V2-AUTO 暂定选择。
- 诊断 ZIP 与批量盲测导出已增加 V2 候选标识；正式拍照、正式 B、原图保存路径未切换。
- 新增 `PT-V2-INTENT-001`、`PT-V2-LOOK-001`、`PT-V2-SELECT-001` 的知识来源、输入、适用边界、副作用和验证方式。
- 新增测量驱动、候选差异、人物保护和技术门后选择的 Swift 契约测试。

## 正在验证

- GitHub Actions Apple 环境的 Swift 编译、测试与 iOS Simulator 构建。
- 七张本地真实照片的 Windows V2 投影、实际参数、技术指标、对照页和盲评入口。Windows 输出只作为开发投影，不冒充 Core Image 或 iPhone 结果。

## 尚未完成

- 七张私人原图尚未产生本版真实 Apple Core Image V2 全分辨率成片；它们不能提交公开仓库或公开构建产物。
- 尚无 V2 人工偏好记录，`V2-AUTO` 只能是 provisional，不能宣称学会专业摄影审美。
- 尚未证明 V2 候选在七类照片中都优于正式 B。
- 人物真实性仍需 iPhone 100% 放大检查；自动测试不等同于真人面部审美验收。
- 未上传 TestFlight；本轮明确禁止自动上传。

## 恢复入口

1. 先检查本文件和独立 V2 分支的最新 Apple CI 结果。
2. 若编译失败，只修复真实编译/像素问题并重新验证。
3. 若 Apple CI 通过，运行七图本地投影工具并检查输出清单。
4. 最后通过现有 iPhone 相册诊断导入获得真实 V2-1/V2-2/V2-3/V2-AUTO，导出 ZIP 后进行盲评。

