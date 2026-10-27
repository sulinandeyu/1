# 摄影参考诊断模式 TestFlight 准备记录

日期：2026-10-27
范围：内部测试准备；不替换正式算法，不执行 TestFlight 上传。

准备分支：`codex/reference-testflight-prep`
应用版本：`1.0`
最近成功 TestFlight 运行号：`24`
计划内部测试 Build：`25`（仅在用户确认上传后使用）

## 1. 分发数据边界

- 本地研究候选共有 39 条：21 条 Public Domain/CC0，18 条 CC BY。
- 当前 App 没有为 18 条 CC BY 提供完整署名展示，因此 `testflight-internal` 构建明确排除这 18 条记录。
- 随包索引只包含 21 条 Public Domain/CC0 的数值特征和来源摘要，大小 42,732 字节；不包含参考图片像素。
- 索引顶层和逐条记录均保持 `productionUseAllowed=false`、`modelTrainingAllowed=false`；没有擅自改变授权标记。
- 该索引仅供诊断导入的 A/B/C 内部测试，不进入正常拍照路径，不构成对正式商业使用的法律结论。

## 2. A/B/C 执行链

- A：导入的原始照片。
- B：当前正式算法输出，仍是应用正常保存的 AI 成片。
- C：仅在诊断导入时执行 `PhotographyReferenceMatcher` → `PhotographyReferenceTargetGenerator` → 现有 `AdaptivePhotographyParameterSolver` → `PhotographyDecisionEngine` → `CoreImageRenderer` → `QualityCheckService`。
- C 的计划、渲染或质检失败会记录降级原因；C 不会替换 B。
- 诊断导入保存时，照片库文件名分别带 `_Original`、`_AI_Edited`、`_C_ReferenceCandidate`，便于测试人员区分。

## 3. 当前验证状态

- Windows 数据测试：21 条参考，30 次隔离查询，26 次匹配，4 次安全回退；本轮 318 ms。
- Swift 单元测试与远程 Xcode 模拟器编译：等待本次独立分支的现有 GitHub Actions 流程验证。
- iPhone Core Image/Vision/JPEG：未执行。
- A/B/C 人工盲测：未执行，不得声称 C 更好看。

## 4. iPhone 内部测试步骤

1. 安装经确认后上传的内部 TestFlight 构建。
2. 在相机主页点击“相册”，选择 `PhoneValidationDataset/inputs` 中同一张原始照片；该入口会标记为诊断导入。
3. 等待处理完成，进入成片页，点击右上角信息按钮。
4. 在“逐阶段像素预览”中确认 `A 原始照片`、`B 当前正式算法成片` 和 `C 摄影参考校准候选`。若没有 C，保留匹配状态和降级原因截图。
5. 点击保存。诊断导入成功时，照片 App 中应出现三张文件，文件名后缀分别为 `_Original`、`_AI_Edited`、`_C_ReferenceCandidate`；可在照片信息页核对文件名。
6. 用系统分享菜单将 B、C 原文件保存到“文件”，不要截图或经过社交软件二次压缩。
7. 在电脑打开 `PhoneValidationDataset/evaluation/blind-compare.html`，导入同一原图对应的 B/C，完成盲测并导出 JSON。
8. 首轮顺序：`phone-owned-001`、`phone-owned-002`、`phone-owned-003`。人物样片重点记录肤色、皮肤纹理和五官是否保持；任何美颜或结构变化均判失败。

## 5. 通过条件

- 远程 Swift 测试与 iOS 模拟器编译通过。
- 真机能从同一原图生成并区分 A/B/C，C 的诊断日志证明经过匹配、目标、求解、渲染和质检。
- B 保持正式输出，C 只作为内部候选。
- 三张输出文件与本次导入一一对应，保存后不存在旧缓存或原图冒充。
- 人物真实性、高光、暗部、偏色、锐化和局部边界检查无硬性失败。
- “C 是否更好”只依据实际盲测结果，不依据自动分数或匹配成功。
