# 专业摄影知识库与实现进度

更新时间：2026-11-07

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
# 2026-11-07：学习型空间自适应增强可行性阶段

- 已审计 B/C 与 Core Image 调用链：B 正式全分辨率渲染存在；C 仅诊断导入，未覆盖 B。
- 已建立 DeepLPF 隔离 Windows 原型并对 5 张真实手机原图执行实际模型推理、局部滤镜预测、像素输出和技术安全门。
- 实测 4/5 输出因暗部裁切或中性色偏移被拒绝；树木图技术门通过但人工观察过度增绿，未判定审美通过。
- 已建立 DeepLabV3-MobileNetV3 语义探针并输出类别蒙版、叠加图、置信度和耗时；确认人物/车辆部分可用，但天空/建筑/道路/植被大量未知且柿子图有人物误检。
- 已核查 HDRNet、DeepLPF、FiveK 和语义探针许可：DeepLPF 公共权重受 FiveK 研究许可限制，禁止 App/TestFlight/商业训练。
- 已分析 `摄影效果参考` 两组城市案例；均为不同视频帧，不作为同底片配对或固定参数目标。
- 当前没有修改 iOS 正式算法、没有加入模型资源、没有提交/推送/上传 TestFlight。
- 下一步入口：取得合法同底片训练配对，定义人物/中性色/裁切约束，训练轻量 HDRNet 类 residual 模型；Windows 隔离通过后再评估 Core ML C2。

## 2026-11-07：学习型模型训练与画质校准阶段

- 已完成：将技术安全门改为线性亮度 + CIE Lab D65；中性色亮度 `ΔL*` 与色度 `Δab` 分离；增加全图/阴影/高光/重要区域裁切、人物/肤色/纹理、饱和溢出、光晕和局部对比检查。
- 已执行：使用可靠人物蒙版重新评估 DeepLPF 5 张实际输出，5/5 均被技术门拒绝；车辆人物肤色色度变化约 9.29 Δab，树木/柿子饱和溢出约 9.34%/7.91%。没有放宽阈值让失败结果通过。
- 已完成：建立项目内 29,509 参数的 HDRNet 风格双边 residual 原型，显式恒等初始化、低分辨率系数网格、有界调整、边缘引导切片，语义缺失时支持安全推理。
- 已完成：建立同底片/专家目标/授权/配准/XMP/人物和关键区域保护的配对数据 Schema 与导入器。5 对旧算法样本通过同画面验证，但均被标记 `pipeline_smoke_only`；产品训练合格样本为 0。
- 已执行：RTX 5070 Ti、PyTorch 2.11.0+cu128 上运行 20 epoch 实际训练；约 19.86 秒、峰值已分配显存 35.32 MiB；训练/验证/测试严格分离，柿子图只作为测试。
- 已导出：5 组 A 原图、B 旧算法目标、C2 模型输出及引导图；C2 技术门未拒绝但肉眼基本接近原图，不宣称达到专业摄影效果。
- 已完成：人物肤色色度/纹理训练约束；两张人物样片 C2 的蒙版内肤色色度变化约 0.85/0.54 Δab，纹理比例约 0.85/0.89。该结果不等于身份/审美验收。
- 已完成：随机化 B/C2 盲测清单，当前人工评价 0/5；没有生成虚假偏好。
- 许可核查：FiveK 商业禁用；Unsplash Lite 不是专家配对且权重分发需确认；DPED 缺商业数据/权重明确授权；HDR+ 不是专家后期且存在 ShareAlike/隐私复核。当前没有可商业训练的专家配对。
- DETR：确认 iOS 现有约 30.9 MiB panoptic Core ML 资源及更完整类别映射；Windows 未运行 Core ML，真机准确率、耗时与内存仍未验证。
- 自动测试：Python 测试与 JSON/Schema/manifest 校验将在最终检查后记录；Windows GPU 训练已真实执行，但不是 Core Image、Vision 或 iPhone 验收。
- 未修改：正式 A/B/C、拍照/保存、Xcode 资源和发布流程；未提交、未推送、未上传 TestFlight。
- 下一步唯一有效入口：先取得书面授权的现代手机同底片专家后期配对及人物/模型分发权，再扩大数据、人工复核、训练、独立盲测；通过后才评估 Core ML/Metal C2。

详细报告：`docs/LEARNING_MODEL_TRAINING_CALIBRATION.md`。
# 2026-11-07：全场景最终整改（阶段 1：渲染与决策隔离诊断）

- 已完成：完整读取本轮 706 行实施要求，并按项目约束复核 `PhotographyKnowledge/README.md`、`SOURCE_INDEX.md`、`CODE_MAPPING.md`。
- 已确认根因之一：现有审美规划器只在摄影参考 C 匹配成功时启用；正式 B 虽使用逐图求解器，但无法单独验证“视觉关系规划”对最终像素的贡献。
- 已确认验证缺口：此前只有自动配方渲染，没有“显式人工参数走同一完整分辨率渲染/编码链”的 M 路径，无法把决策问题与参数映射问题分开。
- 已修改：`ManualPhotographyParameters` 提供明确人工输入；`CoreImageRenderer.renderManualEdit` 复用 B 的完整 Core Image 管线；增加曝光、高光、阴影、黑点、温度、色调、橙/蓝 HSL、亮度范围单控制探针。
- 已修改：新增隔离 D 路径。`PhotographyTargetProfile.measuredBaseline` 只使用当前照片测量，`enableMeasuredAestheticPlanning` 将其送入现有 `AestheticPhotographyPlanner` 和 `AdaptivePhotographyParameterSolver`，最终执行全分辨率 Core Image；不读取参考库、不替换 B。
- 已修改：诊断导入现在准备 A/B/C/D/M，以及蒙版和 M 单参数探针；D/M 的参数、区域执行、质量状态和待人工评价状态写入现有诊断记录。
- 已增加决策测试：人工参数只映射声明字段；正式 B 契约保持无审美规划，D 具有测量驱动规划且不附加参考校准规则。
- 当前验证状态：Windows 无 `swift`、Xcode、Core Image、Vision/Core ML 运行时；因此本阶段只有源码静态检查，**尚未执行 Swift 测试、iOS 编译、Core Image 参数方向验证或 iPhone 视觉验收**。
- 下一步：先在现有远程 iOS Build 上执行 `swift test` 与 Simulator build，修复任何编译问题；随后用同一张真实原图检查 M 探针方向、蒙版坐标及 A/B/D/M。未经用户确认不得提交、推送或上传 TestFlight。

# 2026-11-08：全场景最终整改（阶段 2：远程编译与真实像素验证准备）

- 独立验证分支：`codex/diagnostic-render-validation-20261108`；不合并正式分支，不触发 TestFlight Release。
- 已修复 M 基线污染：`ManualPhotographyParameters.makeRecipe()` 对所有未暴露但可能改变像素的字段显式归零；中性曝光、高光阴影、颜色控制、自然饱和度、白平衡和七段影调直接旁路，不再插入无意义滤镜或 32³ 恒等色彩立方体。
- 已将生产渲染器的曝光、高光阴影、黑点、白平衡、颜色控制和自然饱和度参数映射提取为 `CoreImageParameterKernel`；应用与 macOS 像素测试调用同一实现，避免测试复制另一套公式。
- 已增加实际像素测试：曝光正负方向、高光/阴影区域方向、黑点中性色保护、色温相反方向、橙色 HSL 选择性、中性 M 零污染、局部人物蒙版坐标，以及同场景不同测量生成不同 D 参数。
- 已明确 D/M 状态：渲染失败、质检执行失败、质检返回 failed 分开记录；失败候选只供诊断，`eligibleToReplaceB=false`，正式 B 不变。
- 已降低诊断额外内存：阶段卡片改为最长边 960 的证据预览；A/B/C/D/M 主候选仍串行执行并保留真实全分辨率数据，M 单参数探针继续使用低分辨率预览。
- 已补齐诊断导出：相册保存保留 A/B，并按存在情况分别导出 C/D/M，文件名带明确版本标识。
- 授权收口：`PhotographyReferenceIndex.v1.json` 的 `productionUseAllowed=false`，因此已从 iOS App Resources 移除；Package 内仍可用于非分发的验证测试。合规内部构建中 C 会明确不可用，不能用 D 或固定参数伪装 C。
- Windows 限制：本机没有 Swift/Xcode/Core Image 运行时；上述 Swift/Core Image 测试必须由远程 macOS `swift test` 实际执行，结果将在工作流完成后补记。

# 2026-11-08：Build 27 真机证据与诊断导出（远程验证完成）

- 已读取 `Build27_真机测试` 全部三张图片和完整录屏，并与 `PhotoPreviewView`、`PhotoProcessingPipeline`、D/M 渲染链交叉验证。
- 已确认顶部“AI 成片”为 B；D 仅在阶段预览，技术质检通过但未替换 B；C 因许可/索引门控不可用。
- 已新增结构化 A/B/C/D/M 状态证据和原生 ZIP32 一键导出实现；包含实际图片、探针、蒙版、参数、质检、性能和设备版本信息。
- 已修复广覆盖环境构图被低覆盖类级物体劫持主体优先的问题；新增可靠区域黄色/绿色比例测量和测量驱动黄色 HSL 求解，不绑定秋季场景。
- 已加强仅用于诊断的 M 渲染表达验证；不改变普通拍照 B。
- 实际证据与根因详见 `docs/BUILD27_REAL_DEVICE_DIAGNOSIS.md`。
- 远程验证：分支 `codex/build27-diagnostic-export-20261108`，摄影与诊断实现提交 `93a274cb4418794fb0c99b5c14d66a89d0bdfde7`；GitHub Actions iOS Build #65（run `42455850567`）成功，69 项 Swift 测试 0 失败，iOS Simulator 构建成功。
- 尚未验证：ZIP 分享、A/B/D/M 真机导出内容、M 视觉表达和修复后 D 的摄影效果仍需下一版 iPhone 实测；本阶段未触发 TestFlight Release。
- 下一步：建议内部测试构建号使用 Build 28。用户确认上传后，在同一原图上选择 B/D/M 并一键导出诊断 ZIP；以 ZIP 中的真实全分辨率图片和 executed/rejected/fallback 证据继续验收。

# 2026-11-08：Build 28 真机 ZIP 与自动摄影闭环整改

- 已读取真实 ZIP 内 A/B/D/M 四张 `2160×2880` 图片、候选状态、参数、蒙版、质量和性能 JSON；不再依赖录屏截图推测。
- Windows 同源像素复核：A/B/D/M 平均亮度分别为 `0.6313/0.5800/0.5830/0.5683`；D 与 B 的道路、植被和黄色/绿色关系几乎相同；M 的 5–95% 跨度 `0.9535`，支持 `tooHarsh` 结论。
- 已确认 D 根因：区域黄色/绿色证据只进入说明，旧规划器颜色分离只由混合光触发；D 只渲染一次且目标亮度与安全参数范围不协调。
- 已修改 D-only：源图相对摄影目标、区域颜色协调目标、HSL 动态映射，以及最多一次同定义“渲染—复测—有界修正—重新质检”；正式 B 不变。
- 已修复 C 导出：`unavailable` 不再按名称前缀抓取旧预览；只有 exact `imageStageName` + `executed` 状态可导出图片。
- 已增强 M 证据：导出实际反差、中性色亮度指标、阈值和区域影响；M v3 降低会导致过硬/中性亮部损失的组合强度，仍仅用于诊断。
- 已更新知识规则 `PT-AESTHETIC-002`，新增 `PT-AESTHETIC-004`；增加源图相对目标、区域颜色关系和导出状态契约测试。
- 已运行 Windows ZIP 像素分析工具；详细证据见 `docs/BUILD28_DIAGNOSTIC_CLOSURE.md`。
- 远程验证：实现提交 `a3af9569` 的 iOS Build #72 暴露一处诊断日志变量改名遗漏；修复提交 `c5c069cfbb946d1e80a1afab5dc7abdb08339c49` 的 iOS Build #73（run `42480693382`）成功，73 项 Swift 测试 0 失败，iOS Simulator `BUILD SUCCEEDED`。
- 尚未执行：新版 iPhone A/B/D/M ZIP、真机 Core Image 成片验收、不同场景回归和人工盲测。未经确认不得上传 TestFlight 或替换 B。

# 2026-11-09：Build 29 摄影审美目标根因整改

- 已读取 Build 29 真机 ZIP，并与 Build 28 同源 ZIP 的 A/B/D/M 全分辨率像素、区域、中性色和导出状态比较；详细证据见 `docs/BUILD29_AESTHETIC_TARGET_REMEDIATION.md`。
- 已确认：Build 29 D 更亮是源图相对目标约 `0.605` 与弱曝光修正造成；最终亮度约 `0.613`，反差约 `0.774`，比 Build 28 D 更接近原图且更平。`92.6%` 只表示接近当前保守目标，不是审美成功。
- 已确认：旧 ZIP 丢失 D 有限反馈的生成/采纳状态，不能根据最终参数猜测第二轮是否触发。
- 已实现诊断专用 E1/E2 逐图目标假设：只使用当前图端点、噪声、可靠区域覆盖和颜色关系求解，复用现有规划器、求解器、全分辨率 Core Image 和质检；不按场景名绑定参数，不替换 B。
- 已移除审美规划置信度的 `0.42` 硬下限；置信度改由主体、可靠蒙版和识别证据计算。
- 已分离 `technicalQualityStatus`、`targetQualityStatus`、`humanAestheticStatus`；目标达成率不再冒充审美成功率。D/E1/E2 会导出最终实际配方、同定义复测和有限反馈状态。
- 已将 M 调整为 v4 安全表达探针：不放宽 `tooHarsh` 阈值，取消黑点并降低曲线、局部对比、HSL 和锐化；仍不进入正式算法。
- 已扩展 ZIP、相册导出和人工偏好工具以区分 A/B/C/D/E1/E2/M；C 继续受许可门控。
- 当前验证状态：Windows 同源像素复核已完成；Windows 无 Swift/Xcode/Core Image，远程 Swift 测试与 iOS Simulator 构建待执行；E1/E2/M v4 真机图片和人工盲测尚未执行。未经用户确认不得上传 Build 30。
