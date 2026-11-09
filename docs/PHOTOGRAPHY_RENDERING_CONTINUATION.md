# 小苏相机专业调色渲染续接记录

更新时间：2026-11-09（Asia/Shanghai）

## 当前状态

- 当前分支：`codex/coreimage-tone-expression-20261109`
- 已验证及发布源码提交：`30ee33400b286b94c4e4bec9aa31a506bcb7c40e`
- 当前进度提交：`30ee3340`
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

## 正在进行

- Build 31 已完成内部 TestFlight 发布。下一步是在真实 iPhone 上从相册导入秋季街道 A，取得设备端全分辨率 M/R3-I 与诊断 ZIP，再进行真实区域安全和人工摄影审美验收。

## 尚未完成 / 真机验收项

1. 真实秋季街道全分辨率 R3-I 尚未生成；私有 A/T 未上传至公开 Git 或公开构建产物，Windows R3-W 仍未冒充 R3-I。
2. 需要使用 Build 31 取得真实 R3-I，完成道路、植被、天空、白色车辆/建筑中性色、暗部细节、噪声及蒙版光晕检查。
3. 需要用项目已有不同场景原图做设备端回归；人物结果必须继续验证肤色与真实纹理，禁止美颜或外貌修改。
4. TestFlight 可安装只代表工程发布门通过，不代表 R3-I 摄影效果或跨场景审美已经验收。

## 下一步

1. 在 iPhone 安装 TestFlight Build 31，打开相册诊断入口并导入真实秋季街道 A。
2. 等待 A/B/D/E1/E2/M 生成完成，确认 M 标识为 R3-I 实验候选；使用一键导出生成诊断 ZIP。
3. 将 ZIP 提供回项目，复核实际全分辨率图片、参数、区域指标、质量状态和原图 SHA-256；T 继续只在本地授权边界内参与对比。
4. 完成真实 R3-I 与跨场景/人物人工验收前，不替换正式 B、不合并正式分支、不提交 App Store 正式审核。

