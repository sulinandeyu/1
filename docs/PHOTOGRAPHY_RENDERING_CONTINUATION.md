# 小苏相机专业调色渲染续接记录

更新时间：2026-11-09（Asia/Shanghai，Build 31 真机整改远程验证完成）

## 当前状态

- 当前分支：`codex/build31-r3-safety-auto-d-20261109`
- 已验证及发布源码提交：`30ee33400b286b94c4e4bec9aa31a506bcb7c40e`
- 当前整改提交：`27d4ce684d7fc33b0e61a2c460ede4e85576398b`
- 正式 B：未修改；新增能力仅用于诊断 M / 反求 R3-I。
- TestFlight：小苏相机 `1.0 (Build 31)` 已上传，App Store Connect 状态为 `VALID` / `READY_FOR_BETA_TESTING`，现有内部测试组可安装。

## 已完成

1. 阅读并遵守 `PhotographyKnowledge` 的来源、代码映射与人物保护约束。
2. 保留此前参数反求、区域影调处理和诊断安全指标实现。
3. 读取远程 iOS Build #76（run `42558738562`）真实日志：81 项测试中 79 项通过，2 个测试方法失败、共 3 个断言失败；Simulator 构建因测试失败而跳过。
4. 定位像素一致性根因：
   - Swift 七锚点曲线先采样到 32³ `CIColorCube`，Core Image 再对格点线性插值；旧 Windows 模拟直接计算解析曲线。
   - Core Image 工作空间为扩展线性 sRGB，HSL 和局部蒙版混合实际发生在线性工作域；旧 Windows 模拟在编码 sRGB 中执行。
   - 旧 M R3 使用 `.natural`（0.62）曲线强度，而反求器按 1.0 全强度求解。
5. Windows 模拟已改为 32 格点插值、线性域 HSL/局部混合，4 项单元测试通过。
6. 用同源秋季街道 A/T 和现有可靠蒙版重新执行当前边界及扩展边界反求：
   - 完整模拟 Swift HSL 感知色彩立方体后，当前边界 R2 全图 RGB MAE：`0.1112526`。
   - 修正后的扩展诊断 R3-W 全图 RGB MAE：`0.0652140`。
   - 道路亮度 `0.06864`，目标 `0.06376`；植被亮度 `0.20862`，目标 `0.18281`；道路减植被关系 `-0.13998`，目标 `-0.11905`。
   - 黄色/橙色饱和与中性色亮度仍存在明显差距，人工审美状态仍为待验收。
7. 远程 iOS Build #77（run `42579545332`）：81 项中 80 项通过；EV、黑点、32³ 曲线、区域中性恒等和亮度保护均通过。唯一失败是 Apple 私有 `CIColorControls` 与 Windows 近似最大偏差 `59/255`，不是自定义曲线差异。
8. 远程 iOS Build #78（run `42580580448`）：确认 Swift HSL 在 32³ 格点内先将线性值编码到 sRGB 做 HSV，再转回线性并由 Core Image 插值；旧 Windows 模拟遗漏该感知立方体。模拟已补齐并重新反求 R3 v3。
9. 远程 iOS Build #79（run `42582348554`）：81 项测试全部通过；随后 App 编译暴露 `QualityCheckService` 的 `compactMap` 可选返回类型推断错误。已显式声明 `PhotographyRegionImpact?`，没有跳过测试或降低质量阈值。
10. 远程 iOS Build #80（run `42583561947`）：81 项测试全部通过；App 编译进一步发现 `PhotographyRegionImpact` 的默认属性未进入 App 目标的成员初始化器。已补充带默认值的显式初始化器，使旧 6 项调用与新增 11 项区域安全测量共享同一数据结构。
11. 远程 iOS Build #81（run `42584431183`）：81 项测试全部通过，并取得 R3 v3 的真实 Apple 私有颜色控制基线：`[0,0,51] [21,41,55] [132,57,0] [128,103,0] [0,2,0] [112,112,112]`。App 编译发现诊断探针 `map` 闭包缺少显式 `return`；当前本地提交已修复，并把该基线从临时 `18/255` 容差收紧为 `3/255`。
12. 仓库仅有 1 个受控图片资源，秋季街道原图 SHA-256 `12BE...0F35` 不在 Git 跟踪文件中。当前远程 Apple 环境无法取得这张私有全分辨率输入，因此不能伪造 R3-I，也不能把 Windows R3-W 写成 Core Image 样片。
13. 远程 iOS Build #82（run `42585880410`，HEAD `03ce99a5`）：81/81 Swift 测试通过、0 失败，包含收紧为 `3/255` 的 R3 Apple 基线、区域中性恒等、亮度范围保护、曝光/曲线/HSL/白平衡方向及原有场景回归；iOS Simulator App 构建成功。
14. 补齐设备端 R3-I 诊断证据：相册诊断导入会以同一原图生成全分辨率 M/R3-I 候选；ZIP 中新增 `evidence/R3_VALIDATION_STATUS.json`，记录原图 SHA-256、实际候选状态、执行参数标识 `inverse-r3-core-image-expression-v3-ci-cube-faithful`、技术质检和人工审美状态。专业目标 T 因来源与授权限制不打包、不提交公开仓库。
15. 远程 iOS Build #86（run `42592309510`，HEAD `30ee3340`）：81/81 Swift 测试通过、0 失败，iOS Simulator App 编译成功。此前 Build #85 暴露的诊断导出字段引用错误已修复为读取真实 `qualityStatus` 与 `humanAestheticStatus`，未修改正式 B。
16. TestFlight Release #37（run `42593674139`，HEAD `30ee3340`）：归档、签名、IPA 导出及上传全部成功，实际版本为 `1.0 (31)`。
17. TestFlight Verification #38（run `42594262535`）：App Store Connect 已确认 `processingState=VALID`、`internalBuildState=READY_FOR_BETA_TESTING`，并继承 1 个 `hasAccessToAllBuilds=true` 的现有内部测试组；日志明确输出 `TESTFLIGHT_INTERNAL_INSTALLABLE build=31`。
18. 已读取 Build 31 真机 ZIP `XiaoSuCamera_Diagnostic_20261109_193312_411c710221.zip`，确认 A/B/D/E1/E2/M 均为同一原图的 2160×2880 全分辨率结果；C 继续为 unavailable。D 全局亮度约 `0.6132`，相对 A 的 RGB MAE 仅 `0.0385`；M/R3-I 亮度约 `0.3525`、RGB MAE `0.2821`，证明增强调色算子已在真实 iPhone 执行，但其强度不安全。
19. Build 31 M/R3-I 的失败区域已量化：地面阴影占比约 `54.23%`、黑位约 `32.56%`，建筑阴影约 `39.03%`、黑位约 `32.35%`，建筑中性色亮度约 `0.0291`；这与 `tooHarsh`、`neutralLuminanceLoss`、`localMaskBoundaryArtifact` 一致，不允许通过放宽阈值处理。
20. 根因已定位为两部分：M 的全局 `-0.56 EV` 与地面全亮度范围 `-1 EV` 叠加且缺少端点/羽化保护；D 虽有可靠地面、植被、天空和建筑蒙版，但仍只执行接近零的局部 EV/HSL，且高反差目标被过度压低到保守范围。
21. 当前独立分支已实现但尚待远程 Apple 验证：
   - `PT-AESTHETIC-007`：由每张照片的区域亮度、反差、噪声、颜色占比、可靠蒙版及逐图目标生成 `AdaptiveRegionalTonePlan`，直接进入 D/E 全分辨率 Core Image 区域处理；不读取场景名称，不复制 R3 参数，正式 B 的计划固定为 `nil`。
   - `PT-QA-003`：M/R3 首轮真实渲染失败后，按实际问题进行一次有界安全修正、重渲染和重质检；不修改质检阈值，只有状态或问题数量改善才采用。
   - 高反差源图的 D 目标不再被无条件压平到 `0.66`；增强区域处理使用中间亮度范围、阴影/高光保护及至少 `0.16` 羽化。
22. Windows 已生成同源 A/B/D/M/T 接触表和完整区域指标：`output/build31_real_diagnosis/A_B_D_M_T_contact_sheet.jpg`、`build31_full_resolution_metrics.json`。这些是真机 Build 31 结果复核，不是新 Swift/Core Image 输出；新 D 与安全 R3 仍需远程编译和下一次真机成片验收。
23. 远程 iOS Build #88（run `42620430980`，HEAD `c24989e3`）首次验证本轮整改，暴露新增测试自身的 Swift 参数顺序、`throws` 和类型推断编译问题；生产源码已经完成编译，但测试未运行。测试代码已按真实类型修复，没有删除断言。
24. 远程 iOS Build #89（run `42637431505`，HEAD `17826041`）执行 83 项测试，82 项通过。唯一失败为 `testMeasuredDGeneratesProtectedEnhancedRegionalToneFromCurrentPixels`：可靠植被区域中实测黄色饱和调整只有 `0.039438`，未达到测试要求 `> 0.05`。该失败与真机反馈的 D 色彩表达过弱一致，因此没有降低断言。
25. `PT-AESTHETIC-007` 已补充当前可靠植被蒙版内黄色相对绿色占比的有界分离证据。增益仍同时受当前饱和度余量、逐图色彩目标和 `0.14` 上限约束；不读取“秋季”“道路”等场景名称，不是固定模板。
26. 远程 iOS Build #90（run `42638843350`，HEAD `27d4ce684d7fc33b0e61a2c460ede4e85576398b`）：83/83 Swift 测试通过、0 失败；Windows/Core Image 共享阶段一致性测试、人物保护、正式 B 隔离、动态区域目标和 R3 安全修正合同均通过；iOS Simulator App 构建成功。
27. 已新增 `docs/BUILD31_REAL_RENDERING_DIAGNOSIS.md`，固化 Build 31 同源全分辨率 A/B/D/M/T 指标、M/R3-I 失败区域、D 过弱根因、真实代码调用链和未完成验收边界。

## 当前阶段结论

- Build 31 真机证据、代码整改和远程 Apple 编译测试已完成。分支为 `codex/build31-r3-safety-auto-d-20261109`，验证提交为 `27d4ce68`。正式 B 未修改，本轮未上传 Build 32。

## 尚未完成 / 真机验收项

1. 新安全修正后的 R3 尚未在 Core Image/iPhone 上生成；Windows 只能验证参数方向与 Build 31 旧图指标，不能替代真实渲染。
2. 新 D 的动态增强区域计划尚未取得 iPhone 实际成片，不能声称已满足人工摄影审美。
3. 需要用项目已有不同场景原图做设备端回归；人物结果必须继续验证肤色与真实纹理，禁止美颜或外貌修改。
4. 自动技术通过仍不能决定 D 是否比 B 更好，必须继续 A/B/D/安全 R3 盲测。

## 下一步

1. 等待用户决定是否准备下一内部诊断版；未经确认不上传 Build 32。
2. 下一真机版需导出旧 D、新 D、安全 R3 及对应参数/区域质检，再完成秋季街道和跨场景/人物人工验收。
3. 安全 R3 必须实际消除 `tooHarsh`、`neutralLuminanceLoss` 和 `localMaskBoundaryArtifact`，不能仅凭参数合同或自动测试判定通过。
4. 新 D 必须通过真实成片证明增强区域算子带来协调而有意义的变化；技术通过与人工摄影审美继续分开记录。

# 2026-11-10 Build 33 摄影意图根因整改（进行中）

- 当前分支：`codex/build33-intent-root-cause-20261110`，基线 `92b4c2056b5d3729693612b81651af1f9ac8bb86`；正式 B、普通拍照与保存流程未修改，本轮禁止 Build 34/TestFlight。
- 已解包并逐像素分析真机诊断 `XiaoSuCamera_Diagnostic_20261110_103023_411c710221.zip`。D 确实执行区域调色，但地面/植被亮度关系仅约 -0.008；根因不是“未渲染”，而是旧摄影目标缺少区域关系、区域求解共同追逐全局目标，以及质量检查把有意压暗道路与受保护白车/建筑中性色混合平均。
- neutral loss 精确归因：白车/主体代理 -0.0131、建筑 -0.0141、未分配区域 -0.0188，地面 -0.1784；旧全局值 -0.1083。新增 `PT-QA-005` 保留原 -0.065 阈值，对受保护中性色应用该阈值；有意暗调区域仍检查裁切、细节比例和蒙版边界，不以整图提亮掩盖问题。
- 新增 `PT-AESTHETIC-009`：只使用当前图像可靠地面/植被蒙版内的亮度、饱和度、覆盖关系、噪声余量形成可解释的区域层级假设；不读取场景名称、目标 T 或反求参数，并明确标记需人工审美确认。
- Windows 工程投影（不是 Core Image 成片）：旧 D 地面/植被约 0.520/0.528，新投影约 0.489/0.527；到 T 的 RGB MAE 0.2366→0.2248。改善仍明显小于专业目标，不能宣称新 D 审美通过。
- 新增自动测试：同场景标签但不同像素关系产生不同目标；neutral loss 归因保持原阈值并保护非暗调区域。下一步仅执行远程 Apple 编译与测试，不上传 TestFlight。
- 完整报告：`docs/BUILD33_INTENT_ROOT_CAUSE_REMEDIATION.md`；本地真实图像证据在 `output/build33_root_cause` 与 `output/build33_intent_remediation`，不提交私人原图或受限目标到公开 Git。

# 自动专业摄影闭环最终集成（2026-11-09，进行中）

- 分支：`codex/automatic-professional-integration-20261109`，基线 `5125ba971adaf255d9f11b3972ae2297a3e876f6`（Build 32 已验证/内测基线，正式 B 未改）。
- 已复核知识规则：`PhotographyKnowledge/README.md`、`SOURCE_INDEX.md`、`CODE_MAPPING.md`。
- 已证实根因：D 的动态配方在求解后依次经过可靠性、问题安全、颜色完整性、人物保护与产品边界；可靠区域计划又把低审美置信度作为全参数缩放，首轮反馈只修改极小的全局值且不修改区域计划。M/R3 使用更宽的区域曲线/曝光/HSL 诊断边界，因此“渲染器能表达、自动 D 调不动”。
- 本阶段代码（待远程 Apple 验证）：
  - `PT-AESTHETIC-007` 改为由当前区域亮度/反差/黄色绿色关系计算表达需求；置信度只决定区域证据是否可用，不再重复缩小已可靠的实测残差。
  - 新增 `PT-AESTHETIC-008`：首轮真实区域复测后，安全且响应不足时只沿原计划方向补足；发生暗部、端点、中性色或蒙版边界风险时只收回受影响区域；最多一次从原图重渲染，不放宽质检阈值。
  - 新增 `PT-QA-004`：记录 `solverOutput → analysisReliabilityLimits → problemSafetyLimits → colorIntegrityGuards → portraitProtection → finalProductBounds`，并与 rendered/measured 证据分开导出。
  - D 的反馈选择同时检查全局目标与区域执行达成；技术质检失败的反馈候选仍拒绝。正式 B、拍照和保存路径未改变。
- 新增决策测试：区域响应不足补偿、区域风险定点收回、参数生命周期，以及原有 Build 31 区域表达契约增强。
- 当前限制：Windows 没有 Swift/Core Image；以上修改尚不能写成编译、Core Image 像素或 iPhone 审美通过。下一步是提交独立分支并运行现有远程 iOS Build；真实新 D 全分辨率图片仍必须由后续内部诊断真机生成，在满足发布门槛前不上传下一 TestFlight。

# 2026-11-10 自动专业摄影最终集成续记

- 分支：`codex/automatic-professional-integration-20261109`
- 主要提交：
  - `b64788e5`：区域测量反馈、参数生命周期和自动 D 闭环整改。
  - `3cb962e6`：解除决策核心对 App-only `QualityIssue` 的依赖。
  - `bd336ca8`：区域实测反馈契约修正。
  - `93061439`：诊断 ZIP 结构化参数生命周期（已推送；等待 Apple 验证）。
- 远程 Apple 结果：
  - iOS Build #92 失败：Swift Package 无法解析 App-only `QualityIssue`；已修复。
  - iOS Build #93 通过：86/86，iOS Simulator 构建成功。
  - iOS Build #94 失败：新增像素测试的 10% 软蒙版变化被 8-bit 量化；没有放宽产品阈值，改为遵守区域测量契约。
  - iOS Build #95 通过：87/87，iOS Simulator 构建成功；包含反馈后真实 Core Image 像素响应测试。
  - iOS Build #96 通过：`9306143944c22e3477ccb528b45ce677ec59d369`，87/87，iOS Simulator 构建成功；结构化生命周期导出完成编译验证。
- 真实成片状态：已有 Build 31 A/B/旧 D/M/T 真机证据；本轮新 D 尚无真机全分辨率结果，摄影审美未验收。
- 发布状态：TestFlight 仍为 Build 32；未上传下一版，正式 B 未替换。
- 下一步：仅在满足门槛时准备内部诊断构建，取得 A/B/新 D ZIP 和跨场景人工盲评。
- 完整报告：`docs/AUTOMATIC_PROFESSIONAL_INTEGRATION_REPORT.md`

