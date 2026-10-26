# 小苏相机 V8.1：Scene Profile 场景画像修复

日期：2026-10-26

## Build 22 证据

柿子树真机诊断记录显示：植被覆盖 56.1%、地面 29.9%、天空 6.9%、建筑仅 3.8%；语义标签为 `outdoor 83% / sky 81% / cloudy 81% / plant 75%`。旧逻辑只要建筑蒙版有效就插入 `.architecture`，随后风格判断又先检查建筑，因此错误输出 `urbanArchitecture`。

截图已归档在本地私有目录 `TestPhotos/V8_Persimmon/diagnostics_build22`。

## 代码修复

`MasterCamera/Analysis/PhotoAnalysis.swift`

- 新增 `SceneProfile`，同时保留室内/户外、乡村/城市、天气与时段、区域存在度、摄影倾向、光线柔和度、对比状态和色温趋势等加权证据。
- 建筑风格不再由“建筑蒙版存在”触发。必须有明确城市语义，或建筑覆盖达到主导阈值并且没有被植被压过。
- 将 `plant/tree/garden` 与明确的 `landscape/mountain/scenery` 语义分开，避免把生活纪实照片机械理解成大风景。
- 保留兼容字段 `PhotographyContext.style`，但它现在由 Scene Profile 权重产生。
- `weightSummary` 输出每个权重以及最终风格理由，方便真机核对。

`MasterCamera/Models/PhotoDiagnostics.swift`

- 诊断页新增 `V8.1 Scene Profile 权重`。
- 风格理由会显示城市、自然、纪实和建筑覆盖各自的贡献。

## 回归测试

`SceneAdaptationTests.testV81PersimmonLikeProfileDoesNotLetMinorArchitectureWin` 使用与 Build 22 接近的区域比例构造回归条件，要求：

- 少量建筑不能赢过植被主导画像；
- 风格输出为 `naturalDocumentary`；
- `urbanArchitectureTendency` 保持低权重；
- 可靠主体仍能进入局部处理计划。

## 验证状态

- 真实 Build 22 根因：已由真机截图确认。
- V8.1 代码修复：已完成，尚未提交或推送。
- Swift 自动测试：当前 Windows 缺少 Swift/Xcode，尚未执行。
- iPhone 真机效果：必须在下一 TestFlight 构建验证，当前不能声称通过。

