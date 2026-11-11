# 小苏相机候选生成与候选选择分离验证

日期：2026-11-11
分支：`codex/build33-intent-root-cause-20261110`

## 结论

本轮尚不能证明当前系统已经为 7 张隔离原图生成了至少一张值得选择的专业摄影候选，也不能把失败归因于排序器。原因不是缺少参数 JSON，而是本地没有任何一例同时具备 D、E1、E2 三张当前版本、同源、全分辨率 Core Image 成片及其真实技术状态。

因此，7 个案例当前统一记录为 `incomplete_render_evidence`，不是 `candidate_generation_failed`，也不是 `candidate_selection_failed`。候选生成失败必须由“三张真实候选全部技术失败”或“三张技术合格候选全部被真实人工评价为不好”证明；候选选择失败必须先存在获人工支持的候选，再证明自动选择没有选中它。

正式 B、正常拍照和原图保存没有修改；未上传 Build 34。

Apple 工程验证：摄影代码提交 `0e2f600b`（最终报告格式提交 `f6666064`）对应 [iOS Build #101](https://github.com/sulinandeyu/1/actions/runs/42942854695)，93/93 项 Swift 测试通过，iOS Simulator `BUILD SUCCEEDED`。这只证明状态契约、诊断导出和原有工程可编译，不替代七图真实 Core Image 成片与人工审美验收。

## 七张原图与隔离状态

清单：`PhoneValidationDataset/cross_scene_split.json`

| 原图 ID | 分组 | Windows 原图诊断 | 当前 D/E1/E2 Core Image 证据 | 当前结论 |
|---|---|---|---|---|
| phone-owned-001 | development | 亮度 0.476，饱和度 0.108，中性色 82.7% | 0/3 | 证据不完整 |
| phone-owned-002 | development | 亮度 0.213，饱和度 0.233，中性色 70.3% | 0/3 | 证据不完整 |
| historical-building | development | 亮度 0.582，饱和度 0.109，中性色 58.3% | 0/3 | 证据不完整 |
| phone-owned-003 | blind | 亮度 0.413，饱和度 0.222，中性色 60.5% | 0/3 | 证据不完整 |
| historical-selfie | blind | 亮度 0.445，饱和度 0.126，中性色 79.7% | 0/3 | 证据不完整；人物保护仍需真机验证 |
| historical-vehicle-person | blind | 亮度 0.648，饱和度 0.121，中性色 72.3% | 0/3 | 证据不完整；人物/白车保护仍需真机验证 |
| historical-trees | blind | 亮度 0.549，饱和度 0.217，中性色 52.9% | 0/3 | 证据不完整 |

以上指标只用于描述输入差异，不是 Core Image 或摄影审美验收。7 个 SHA-256 均已复核，开发集与盲测集没有哈希泄漏。四张历史 V8.1 成片只证明旧渲染器曾产生变化，不能冒充当前 D/E1/E2。

## 候选生成器审计

当前 `AestheticTargetHypothesisGenerator` 确实读取当前照片测量，不读取专业目标 T，也不是场景名到 LUT 的映射。但现有目标空间存在共同收缩：

- E1 色彩分离目标上限为 0.055，饱和度增量上限 0.016；E2 饱和度增量上限 0.010。
- E1/E2 都继承同一个 `subjectBackgroundDeltaTarget`，没有形成独立的主体—背景关系假设。
- E1 亮度位移约束在 0.010–0.052，E2 额外暗调约束在 0.018–0.060；两个目标主要是同一连续基线附近的保守扰动。
- 三个目标没有渲染后“实际差异充足性”门控；目标名称不同不代表真实像素已经形成三种摄影表达。
- D/E1/E2 当前没有执行彼此之间的自动审美排序，不能把工程分数或技术通过写成“自动最佳成片”。

这构成“候选可能共同趋近原图、影调范围不足、色彩表达单一”的代码级风险证据，但在取得七图真机成片前，仍不能把风险直接写成七图候选生成失败。

## 本轮实现

- 新增知识规则 `PT-PREF-002`，把候选生成结果与候选选择结果拆分。
- 诊断 ZIP 新增 `evidence/candidate_generation_and_selection.json`，只接受真实 executed 候选及对应全分辨率阶段图。
- 技术通过只产生 `preferencePending`；不会自动变成“摄影效果良好”。
- 新增可重复脚本 `scripts/prepare_cross_scene_candidate_blind_test.py`：验证 7 张原图哈希，自动寻找本地受控诊断 ZIP，只提取同源 D/E1/E2；缺图时禁止投票且不生成替代图片。
- 直接打开的盲测页：`output/cross_scene_candidate_blind_test/index.html`。
- 页面允许记录“第一/第二/第三更好”“全部不好”“差异不明显”，投票前随机盲化顺序；目前真实投票 0 条。

## 是否需要扩展到 100 张

现在没有依据扩展。最小下一关是先让这 7 张各自产生三张同源、全分辨率、技术状态明确的真实 Core Image 候选，并完成 7 组人工评价。只有出现“存在获人工支持候选但自动没选中”的重复证据，才进入排序器校准；如果多数组合为“全部不好”，应替换或扩展候选目标空间生成模块，而不是收集 300–600 条排序标签。

## 建议替换的模块边界

若七图人工评价证实候选普遍“全部不好”，应替换的是 `AestheticTargetHypothesisGenerator` 的目标空间探索层：从当前照片的可恢复动态范围、区域相对亮度、色彩角色、中性色/肤色保护和噪声余量，求解三组真正不同但安全的关系目标，并在低分辨率真实 Core Image 渲染后检查候选间区域差异。继续叠加场景规则或只提高饱和度不能解决该问题。

该替换仍不得读取专业目标 T、固定场景参数或未授权参考；`AdaptivePhotographyParameterSolver`、Core Image 渲染器、技术质检和正式 B 可以继续保留。
