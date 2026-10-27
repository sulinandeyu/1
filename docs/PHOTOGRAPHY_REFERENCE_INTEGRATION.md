# 小苏相机摄影参考数据库接入报告

日期：2026-10-27
状态：代码接入和 Windows 数据测试完成；Swift/iOS/Core Image 真机执行与人工审美验收未完成。

## 1. 已有成果与数据边界

- 已确认 220 张参考、30 张隔离验证、250 条特征和逐文件来源/许可记录存在。
- 原先 SHA-256 检查只排除完全相同像素。本轮新增感知哈希跨集审计，实际比较 6600 对，筛出 8 对候选并逐对人工查看，确认均非同一照片。证据见 `PhotographyDataset/reports/NEAR_DUPLICATE_AUDIT.md` 与 `NEAR_DUPLICATE_VISUAL_REVIEW.md`。
- 202 张 CC BY-SA 记录维持 `blocked_pending_legal_review`，不进入 App 索引。
- 39 条参考集记录满足本地研究用的初步自动许可分层，但其中 18 条为 CC BY，当前 App 没有完整署名展示，且 39 条均未完成人工法律/内容复核，不能原样进入 TestFlight 分发包。
- TestFlight 内部诊断构建使用独立的保守索引：只包含 21 条 Public Domain/CC0 数值特征，18 条 CC BY 和全部 CC BY-SA 记录均排除；`productionUseAllowed=false`、`modelTrainingAllowed=false` 保持不变。
- App 资源只包含 42,732 字节的数值特征、来源和许可摘要，不包含 250 张参考图像素，也没有训练模型。

## 2. 摄影参考检索

实现文件：`MasterCamera/PhotographerAI/PhotographyReferenceMatcher.swift`。

检索综合当前照片的平均亮度、动态范围、阴影、高光、饱和度、R-B 与绿偏关系、可靠中性色覆盖，以及语义/光照辅助词。连续测量占 90%，语义辅助占 10%；语义不能直接选择参数。结果包含：

- Top 3 参考 ID、度量相似度、语义辅助相似度和综合置信度；
- 亮度/动态范围、两端分布和色彩关系的具体差值；
- 明确禁止迁移的绝对白平衡、HSL、直方图、曲线、内容颜色和主体身份；
- 人物照片额外禁止迁移肤色、面部纹理和人物局部参数；
- 相似度或许可门控不足时返回现有测量求解器。

Windows 对 30 张隔离验证图执行特征路径检索：21 条 TestFlight 诊断参考、30 次查询、26 次进入验证匹配、4 次安全降级；本轮总耗时 318 ms，序列化索引 42,732 字节。测试同时记录亮度、反差、饱和度和中心—边缘构图代理差值。该结果只证明 Windows 检索代码和回退实际运行，不代表审美更好，也不是 iPhone 性能结果。

## 3. 动态摄影目标与现有求解器对接

`PhotographyReferenceTargetGenerator` 先调用现有 `AdaptivePhotographyTargetGenerator` 生成当前照片基线，再对通过门控的前三个参考做相似度加权。参考影响受置信度、夜景/混合光氛围保护和人物保护共同限制，最大权重 16%。

允许校准的只是目标关系：亮度、反差、阴影、高光、饱和度、局部反差和可靠非人物主体/背景关系。单项目标位移分别设置小范围上限。白平衡、Tint、HSL、曲线、蒙版和实际 Core Image 参数仍由当前照片测量、问题诊断和安全规则求解。

`AdaptivePhotographyParameterSolver.solve(..., targetProfile:)` 是唯一参数求解器；没有新增平行滤镜引擎。参考目标实际进入现有 `PhotographyDecisionEngine → PhotographyEditPlan → CoreImageRenderer` 数据流，相关参数证据附带 `PT-REF-001/002/003`。

## 4. A/B/C 验证模式

`ProcessingConfiguration.referenceValidation` 当前为 `diagnosticImportsOnly`：

- A：原始照片。
- B：当前正式逐图算法和原候选选择结果。
- C：参考检索通过后，由同一参数求解器和同一 Core Image 渲染器生成的完整分辨率候选。

C 会单独执行区域回执和 `QualityCheckService`，但绝不替换 B。诊断页保留匹配依据、置信度、不可迁移项、目标变化、完整参数、规则 ID、局部计划、区域执行、质量问题、RGB 差异、肤色/中性色风险和耗时。匹配、渲染或质检失败会明确记录，不能伪装为 C 已成功。

正式相机拍摄 `isDiagnosticImport=false`，不会运行参考路径；因此本轮没有改变正式出片默认行为。

## 5. 自有手机验证集与人工盲测

- 新建 `PhoneValidationDataset/manifest.jsonl`，登记用户已经明确声明为手机原相机拍摄的 3 张素材：室内强灯、夜景建筑、室内混合光/食物/环境人物。
- 当前 3/30，缺少 27 张；具体条件见 `PhoneValidationDataset/MISSING_CASES.md`。没有用公开参考图或合成图补位。
- `PhoneValidationDataset/evaluation/blind-compare.html` 在本地随机左右排列真实 B/C，支持“左更好、右更好、两者都不好、差异不明显”，并记录肤色异常、偏色、锐化、灰雾、饱和、局部错误、高光和暗部问题。
- 当前没有任何预填人工偏好，也不会把自动质量分写成用户评价。

## 6. Windows 已执行验证

已执行并通过：

1. 数据集原有完整性测试：220/30、无 SHA-256 重复、像素资产均被 Git 忽略。
2. 感知近重复脚本：6600 对，8 对候选完成视觉复核，0 对确认泄漏。
3. 参考索引生成：21 条 Public Domain/CC0 数值特征、无参考像素、生产/训练许可关闭；18 条 CC BY 因缺署名展示而排除。
4. 参考检索：30 次真实特征查询，26 匹配、4 安全回退。
5. JSON/JSONL 解析、项目文件引用检查和 `git diff --check`。
6. 自有手机原图清单检查：3 条文件、SHA-256、尺寸和授权字段一致；B/C 真机导出与人工偏好仍均为 0。

未执行：Windows 没有 Swift/Xcode/iOS SDK，新增 Swift 单元测试、Core Image 渲染、Vision 蒙版、JPEG 真机导出和 iPhone 性能均不能标记通过。

## 7. iPhone 真机步骤

1. 通过现有远程构建/TestFlight 流程生成包含本次代码的测试构建；本轮未提交、未推送、未发布。
2. 打开诊断导入入口，依次导入 `PhoneValidationDataset/manifest.jsonl` 中的同一张原图。
3. 在“逐阶段像素预览”确认出现 `A 原始照片`、`B 当前正式算法成片`、`C 摄影参考校准候选`。若没有 C，截图诊断页中的匹配状态和降级原因。
4. 截图“摄影参考验证 A/B/C”，确认索引 ID、目标、参数、局部计划、区域执行、质检和耗时均存在；人物样片重点检查肤色偏移和皮肤纹理。
5. 分别保存或导出 B/C，使用离线盲测工具评价，不要先看身份。
6. 至少先完成 3 张现有自有手机原图，再补人物、风景、日间建筑、逆光、阴天和更多夜景，目标 30 张。
7. 只有 C 在多类真实手机照片中获得稳定人工偏好且没有人物/中性色风险，才讨论把许可审核后的能力从诊断路径提升到正式候选；当前不允许。

## 8. 未解决问题

- 39 条本地候选尚未完成人工法律/内容审核；TestFlight 包只含其中 21 条 Public Domain/CC0 数值特征，生产开关保持关闭。这是工程上的保守准入，不构成法律意见。
- 参考作品没有原图—专家成片配对，也没有摄影师调整意图；目标校准能力有限。
- 30 张公开验证图是优秀作品，不等于普通手机随拍；自有手机验证集只有 3 张。
- 参考特征由 Windows 缩小 sRGB 统计生成，与 iPhone `PhotoAnalyzer` 的实现存在域差异，需要真机日志校准阈值。
- 自动质量检查只能排除部分技术错误，不能证明 C 更美；必须积累真实盲测结果。
- 新增 Swift 测试尚未在 Apple/Swift 环境执行，项目编译与资源加载需要现有远程构建确认。
