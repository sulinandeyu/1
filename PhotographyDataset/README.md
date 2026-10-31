# 小苏相机摄影数据集

本目录保存可审计的摄影参考数据结构、来源许可、逐文件清单、提取后的测量特征和执行报告。第三方图片像素保存在已被 `.gitignore` 排除的 `assets/`，不得随代码仓库分发。

## 当前边界

- `PhotographyKnowledge` 保存摄影方法与规则；本目录保存具体数据记录，两者不互相替代。
- 首批样本只用于摄影统计、检索实验和候选评价校准准备，不直接生成场景固定参数。
- 只有 `authorization.modelTraining` 明确为 `candidate_after_legal_review` 且完成法务/内容风险复核的记录，才可进入未来训练计划。
- MIT-Adobe FiveK 仅限研究且禁止商业优势，登记为 `blocked_commercial`，没有下载。
- Unsplash Lite 允许内部商业机器学习，但禁止披露、转移或再分发数据；必须由项目权利主体单独接受其条款后，在仓库外本地导入。本轮没有代替用户接受条款，也没有下载。
- Wikimedia Commons 数据通过官方 MediaWiki API 获取，每个文件单独保存作者、许可、来源页和许可 URL。Commons 仍提示逐文件核实，人物权、商标权和隐私权不由版权许可自动解决。

## 目录

- `schemas/photo-record.schema.json`：单张照片/真实配对的元数据结构。
- `licenses/SOURCE_LICENSE_MATRIX.md`：数据集级许可结论和证据链接。
- `licenses/source-registry.json`：机器可读的来源准入状态。
- `manifests/reference.jsonl`：参考集逐文件来源与许可。
- `manifests/validation.jsonl`：与参考集隔离的验证集。
- `features/*.jsonl`：只含实测统计，不含图片像素。
- `reports/`：导入、许可、样本分布与特征执行报告。
- `assets/`：本地图片字节，禁止提交。

## 数据角色

- `reference`：用于建立分布、检索候选摄影目标和人工评价界面，不等于训练数据。
- `validation`：与参考集按文件 SHA/来源页严格隔离，只用于验证；不得回流训练。
- `paired_original` / `paired_expert_edit`：只有官方或授权材料提供同一底片的明确对应关系时才允许使用；本轮没有创建虚假配对。

## 运行

```powershell
pwsh -File scripts/Import-WikimediaPhotographyDataset.ps1 -TargetCount 250 -ValidationCount 30
pwsh -File scripts/Measure-PhotographyDataset.ps1
pwsh -File scripts/Test-PhotographyDataset.ps1
```

脚本使用 Wikimedia Commons 官方 API，不抓取网页。特征脚本只依赖 Windows 自带的 `System.Drawing`。

## 与现有引擎的关系

参考检索只能以当前照片的实测特征为输入，例如亮度分位数、动态范围、综合色偏、中性色覆盖、饱和度、局部对比和可靠蒙版统计。类别标签只用于安全边界和结果解释，不能映射固定 LUT 或固定参数。详细对接见 `INTEGRATION.md`。
