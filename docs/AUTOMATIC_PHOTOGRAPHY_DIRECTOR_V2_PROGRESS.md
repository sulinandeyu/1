# Automatic Photography Director V2 进度

更新时间：2026-11-15

## 当前阶段

V2 最小端到端实现已接入隔离诊断路径。最新摄影源码提交
`d15c3cf5316da753b572bec68e0b6531d50d62e4` 已通过 Apple iOS Build #119：
`swift test` 步骤与 iOS Simulator 构建均成功。正式 B 未替换；V2 尚未经过
iPhone 人工摄影审美验收。

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
- 新增本地七图投影工具 `scripts/run_automatic_photography_director_v2_projection.py`；它不读取专业目标 T，按当前照片测量生成 V2-1/V2-2/V2-3、暂定 AUTO、实际参数、区域代理蒙版、技术指标、对照页与盲评页。
- 七图本地输出位于 `output/automatic_photography_director_v2/`；`comparison.html` 可直接对照原图、历史可比结果（仅在存在时）、V2 候选和 AUTO，`blind-compare.html` 不预填人工偏好。
- 将同源全分辨率 V2 候选的真实像素差异检查接入诊断链；只有三组配对均达到现有区域/像素差异门槛时才记录为有效目标探索，否则明确记录 `candidate_generation_failed`。该检查不把“差异足够”解释为“更好看”。

## 七图本地投影结果

Windows 投影只验证当前 V2 意图和参数能否产生可测差异，不冒充 Core Image、Vision 或 iPhone 结果。

- 建筑、室内混合光、阴天植被：三组候选配对达到本地差异门槛（3/7）。
- 秋季道路：V2-2/V2-3 RGB MAE 约 `0.0109`，候选生成差异不足。
- 柿子庭院：V2-2/V2-3 RGB MAE 约 `0.0087`，候选生成差异不足。
- 自然人物：最小配对 RGB MAE 约 `0.0030`；人物保护生效，但三种摄影表达不足。
- 人物与车辆：最小配对 RGB MAE 约 `0.0078`；人物保护生效，但三种摄影表达不足。
- 以上 4/7 记录为 `candidate_generation_failed_difference_too_small`；不得把暂定 AUTO 当作摄影审美成功。
- 当前七图均没有真实人工偏好记录；所有 AUTO 仍为 `pending_human_review`。

## 正在验证

- 私人七图仍需通过 iPhone 相册诊断取得真实 Core Image 全分辨率结果；私人素材不会提交公开仓库或公开构建产物。
- Build #119：<https://github.com/sulinandeyu/1/actions/runs/43661980959>；工作流没有公开单独汇总测试数量，因此只记录可核验的步骤结论，不编造数量。
- 已补齐待验证内部诊断包的取证边界：批量包明确包含当前源码生成的正式 B 与 V2-1/2/3，独立标注 V2-AUTO；盲测页仅匿名比较 B 与 V2-1/2/3，不显示或重复 AUTO；单图子包保存原生像素人脸裁块、图像尺寸、设备硬件标识、源码 Git SHA，以及 V2 阶段起止内存证据。
- 现有 `ios-build.yml` 只运行 Apple Swift 测试和 iOS Simulator 构建；它不签名安装到 iPhone，也不处理七张私人原图。历史上可用的签名渠道是手动 TestFlight 工作流，但本阶段未获上传授权，因此没有触发发布，也没有把本地照片传入 GitHub Actions。

## 尚未完成

- 七张私人原图尚未产生本版真实 Apple Core Image V2 全分辨率成片；Windows 输出均带有 `windows_projection_not_core_image` 标记。
- 尚无 V2 人工偏好记录，`V2-AUTO` 只能是 provisional，不能宣称学会专业摄影审美。
- 尚未证明 V2 候选在七类照片中优于正式 B；本地投影已证明 4/7 的候选空间仍不足。
- 人物真实性仍需 iPhone 100% 放大检查；自动测试不等同于真人面部审美验收。
- 未上传 TestFlight；本轮明确禁止自动上传。
- 当前 Windows 主机没有检测到可直接安装的 USB iPhone，工程也没有 Ad Hoc 安装工作流。因而在不上传 TestFlight 的约束下，真实 iPhone JPEG、实际设备峰值内存和人脸 100% 人工检查仍是外部阻断；Simulator/Windows 结果不会冒充这些证据。

## 恢复入口

1. 先检查本文件、独立 V2 分支最新 HEAD 及对应 Apple CI 结果。
2. 若编译或测试失败，只修复真实失败并重新验证，不降低差异或技术安全门槛。
3. 通过现有 iPhone 相册诊断导入获得真实 V2-1/V2-2/V2-3/V2-AUTO；ZIP 会记录候选探索状态与逐对像素证据。
4. 对七图执行盲评；若候选都不好，归类为生成失败；若存在好候选但 AUTO 未命中，归类为选择失败。
5. 未取得上述证据前，不替换正式 B、不上传 TestFlight、不宣称达到专业摄影审美。

