# 专业摄影知识库与实现进度

更新时间：2026-10-31

## 状态定义

- 文档完成：来源和规则已落盘。
- 代码完成：规则已接入生产数据流。
- 自动测试通过：可执行测试已真实运行。
- iOS 端到端通过：Apple 环境实际执行 Vision/Core Image 并保存结果。
- 视觉验收通过：真实照片由人工确认达到目标。

以上状态互不替代。

## 阶段 1：来源与持久化知识库

- 状态：文档完成。
- 已完成：核验 Adobe、Apple 官方资料和公开论文；创建 `PhotographyKnowledge` 来源索引、曝光/颜色/局部/细节/人物/质量规则及授权参考案例结构。
- 已完成：创建项目级 `AGENTS.md`，要求后续摄影代码使用规则 ID、实测输入和可验证边界。
- 测试：链接和内容已人工访问；未下载或复制付费课程。
- 未完成：没有授权的原图—专业成片—调整记录数据集，因此审美校准仍为空。

## 阶段 2：现有引擎差距审计

- 状态：已完成高优先级静态审计。
- 证实：生产路径已使用逐图求解器；Core Image 工作空间为扩展线性 sRGB、输出为 sRGB；局部蒙版已有覆盖率与边界可靠度检查。
- 证实：白平衡诊断/求解仍依赖整幅图 RGB 均值，可能把肤色、橙色主体、植被或天空固有颜色误判为照明色偏。
- 证实：`CITemperatureAndTint` 使用真实渲染，但源白点估计仍是近似值，不能宣称等同 RAW 域专业 AWB。
- 证实：自动质量分无法单独证明审美更好，仍需真实案例与人工偏好。
- 详细证据：见 `docs/PHOTOGRAPHY_ENGINE_KNOWLEDGE_AUDIT.md`。

## 阶段 3：高优先级代码接入

- 状态：代码完成，Windows 静态检查通过；Apple 环境验证待执行。
- 已完成：加入排除人脸、带覆盖率/空间分布/置信度的中性色测量。
- 已完成：色偏诊断和动态白平衡只使用可靠中性色证据；无可靠证据时保持中性参数，不再用全图 RGB 均值猜测。
- 已完成：混合光降低全局白平衡幅度；参数证据携带知识规则 ID。
- 已完成：按 Apple API 语义修正 `CITemperatureAndTint` 为“实测源白点→中性目标白点”。
- 已完成：参数方向、无证据保守降级、混合光衰减与知识规则映射测试代码。
- 已通过：`git diff --check`；PowerShell 参考案例工具语法解析；参考案例 JSON Schema 解析。
- 未执行：Swift 测试（当前 Windows 无 `swift` 命令）；Core Image/Vision/iPhone 端到端与视觉验收。

## 阶段 4：授权参考案例入口

- 状态：结构与安全校验工具完成，案例数据缺失。
- 已完成：增加 `PhotographyReferenceRecord` 可编码结构、JSON Schema 和 `scripts/Test-PhotographyReference.ps1`。
- 已验证：PowerShell 脚本语法解析通过，JSON Schema 可正常解析。
- 未完成：没有授权原图/专业成片/调整记录/摄影师说明，因此没有导入或伪造任何“专业案例”。

## 阶段 5：真实失败照片回归准备

- 状态：测试清单和自动测试代码完成，执行受环境限制。
- 已完成：将已有自拍、阴天建筑、人物与白车、阴天树木、柿子树登记到 `PhotographyKnowledge/REGRESSION_CASES.md`。
- 已完成：新增无中性色不校正、可靠中性色产生相反校正方向、混合光减弱校正、参数证据关联知识规则的 Swift 测试。
- 未执行：当前 Windows 没有 Swift/Xcode；本轮未运行这些 Swift 测试，也未生成新的 iPhone Core Image 成片。

## 环境限制

- 当前为 Windows，无本地 Xcode/Swift/iOS SDK。
- 本轮尚未运行 iPhone、Vision、Core Image 端到端测试；不得标记为通过。
- 未经用户允许，本轮不提交、不推送、不发布 TestFlight。

## 阶段 6：专业摄影审美数据库

- 状态：数据来源核查、数据库结构、首批导入、逐图特征和隔离检查已完成；模型训练与生产接入未启动。
- 已核查：MIT-Adobe FiveK 两份官方许可均只允许研究、禁止商业优势，因此没有下载或导入。
- 已核查：Unsplash Lite 允许内部商业 ML，但禁止披露/转移/再分发；本轮没有代替权利主体接受条款，也没有下载。Unsplash Full 禁止商业模型用途。
- 已核查：Open Images 图片虽列为 CC BY 2.0，但官方不保证逐图状态，且数据目标不是专业后期；本轮没有导入。
- 已完成：建立 `PhotographyDataset` 元数据 Schema、来源注册、许可矩阵、导入/测量/完整性测试脚本和现有引擎对接边界。
- 已执行：通过 Wikimedia Commons 官方 API 逐文件导入 250 张 Featured Pictures；220 张参考、30 张隔离验证，来源 ID/URL/SHA256 无重叠。
- 已执行：逐图生成亮度分位、影调、高光/阴影、RGB、色相、饱和度、冷暖、中性色、梯度、4×4 局部对比和中心/边缘代理统计。
- 已通过：数据集完整性测试；250 条清单、250 条特征、无重复像素、图片资产全部被 Git 忽略、原图—专家成片配对数为 0。
- 已检查：5 张共 250 图的联系表完成视觉抽查；样本主要为风光、建筑、自然、城市、夜景和天文摄影，没有把 Featured 状态冒充为专家修图参数。
- 许可分层：48 张为 `candidate_after_legal_review`（PD/CC0/CC BY），202 张 CC BY-SA 为 `blocked_pending_legal_review`；当前全部仅用于参考/特征分析，未训练模型。
- 测量结果：平均亮度 0.4348、平均饱和度 0.3159、平均网格局部对比 0.1250；详细分布见 `PhotographyDataset/reports/SAMPLE_STATISTICS.md`。
- 未完成：数据没有官方同底片专家修图配对；缺少摄影师调整意图；尚未把参考检索接入生产候选评分；没有 Core Image/iPhone 渲染或人工审美偏好验收。

## 阶段 7：摄影参考正式接入的诊断验证路径

- 状态：实际代码与 Windows 数据测试完成；正式算法未替换；iPhone 与人工审美待验收。
- 已完成：对 220×30 个跨集组合增加感知哈希审计，8 对候选逐对人工复核后没有确认近重复泄漏。
- 已完成：39 条本地研究候选中，仅将 21 条 Public Domain/CC0 数值特征写入 TestFlight 内部诊断索引（42,732 字节）；18 条 CC BY 因缺 App 内署名展示而排除，图片像素不打包，索引继续禁止生产使用和模型训练。
- 已完成：`PhotographyReferenceMatcher` 综合影调、两端分布、色彩、中性色和语义辅助，输出依据、置信度、不可迁移项与安全降级。
- 已完成：`PhotographyReferenceTargetGenerator` 以当前图基线为主，只有限校准摄影目标；现有 `AdaptivePhotographyParameterSolver`、Core Image 和质量检查继续作为唯一执行链。
- 已完成：诊断导入生成 A 原图、B 当前算法、C 参考候选；C 不替换 B，正式拍照路径不运行。
- 已完成：登记 3 张来源明确的自有手机原图，建立 30 张缺口清单和离线 B/C 盲测工具；没有伪造任何人工偏好。
- Windows 实测：使用 21 条 TestFlight 诊断索引，对 30 个隔离查询执行匹配；26 个进入诊断匹配、4 个安全回退，本轮耗时 318 ms，索引 42,732 字节；这不是 iPhone 性能或审美结论。
- 已通过：JSON/JSONL 解析、数据脚本执行、项目引用检查、`git diff --check`；3 张自有手机原图的文件、SHA-256、尺寸和授权字段一致。
- 尚未完成：手机验证集仍为 3/30，B/C iPhone 导出 0/3，人工偏好评价 0/3。
- 已通过：独立分支 `codex/reference-testflight-prep` 的远程 `iOS Build #59`；`swift test` 与 iOS Simulator Debug 构建均成功。
- 已完成：既有 `TestFlight Release` 已成功完成签名 Archive、IPA 导出和 App Store Connect 上传，版本 `1.0 (25)`，GitHub Actions run `40532209838`。
- 未执行：当前工作区新增视觉理解/审美规划代码的远程编译；build 25 上的 iPhone Core Image/Vision/JPEG、A/B/C 真机视觉验收。
- 下一步：build 25 只用于上一阶段参考诊断基线；本阶段代码未经用户确认不得提交/推送。确认后先运行远程 `swift test` 与 iOS Simulator build，再准备新的内部测试构建。

## 阶段 8：视觉理解与逐图摄影审美规划

- 状态：教程人工分析与核心代码接入完成；Windows 静态检查进行中；Apple 编译和 iPhone 视觉验收未执行。
- 已完成：逐张检查 `网上教程` 的 11 张图片；确认 1 组山谷原图/成片、3 组地铁人像同帧前后关系；两张车内视频截图不是同一帧，没有伪造成修图前后。
- 已完成：创建 `docs/PHOTOGRAPHY_TUTORIAL_ANALYSIS.md`；教程仅作为未授权本地研究资料，不进入 App、参考索引、训练集或第三方服务。
- 已审计：当前实际使用 `VNClassifyImageRequest`、人脸检测、人物分割、注意显著性和约 30.9 MiB 的 DETR panoptic Core ML 模型。此前 DETR 大量类别未进入结构化理解，C 方案没有独立审美规划器。
- 已完成：复用现有 DETR 输出，增加人物、车辆、动物、食物/果实、工作区、人工光源、道路类级蒙版；类别编号逐项对照模型内嵌 `labels` 元数据（例如食物/果实 52–61/122/196、灯光 10/130、道路 147/149/191），明确类级语义不等于实例身份或摄影意图。
- 已完成：新增 `VisualSceneUnderstandingResult`，记录场景标签、语义区域、主体候选、视觉中心、光源/影调/颜色证据、保护项和未知项。
- 已完成：新增 `AestheticPhotographyPlanner`，只在隔离的 C 诊断路径启用；正式 B 不变。规划结果进入现有 `AdaptivePhotographyParameterSolver` 和 Core Image 配方，不创建平行渲染引擎。
- 已完成：增加 `PT-UNDERSTANDING-001`、`PT-AESTHETIC-001/002/003`，记录来源、输入、适用/不适用条件、副作用与验证方法。
- 已完成：A/B/C 诊断详情增加结构化视觉理解、审美规划、动态参数、区域执行和技术质检记录。
- 已增加：语义证据边界、C-only 规划接入、同场景不同测量产生不同目标，以及“无人脸但有人物蒙版仍启用严格人物保护”的 Swift 契约测试。
- 已完成安全收口：候选计划、参数状态和摄影上下文不再只依赖 `faceCount`；人脸、整人物分割或可靠语义人物区域任一成立都会启用人物保护，非人物局部增强优先读取可靠类级语义区域的实测统计。
- 已执行：`git diff --check`、参考索引/Schema JSON 解析和 250 张数据集完整性测试通过；新增 `scripts/Test-SemanticModelLabelMapping.ps1` 并通过，逐项核对模型 201 个标签中的 7 组/46 个实际 class ID 与 Swift 映射；现有参考检索脚本再次完成 21 条参考 × 30 个隔离查询，26 次匹配、4 次安全回退，本次 455 ms（只代表 Windows 脚本，不是 Core Image/真机性能）。授权案例 manifest 测试未执行，因为仓库仍没有可用的已授权原图—成片案例，不能拿 Schema 冒充案例。Windows 没有 `swift` 命令，本轮不能执行新增 Swift 测试，也不能声称 iOS 编译通过。
- 未完成：远程 macOS `swift test`/iOS Simulator build、DETR 新类级蒙版真机准确性/耗时/内存、C 真实 Core Image 出图、人物肤色保护、五类照片盲测。
