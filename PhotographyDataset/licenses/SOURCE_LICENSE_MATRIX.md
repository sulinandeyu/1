# 数据来源与许可矩阵

核查日期：2026-10-27。以下是工程准入结论，不构成法律意见；商业训练前仍需由权利主体复核具体用途。

| 来源 | 官方证据 | 许可结论 | 本项目处理 |
|---|---|---|---|
| MIT-Adobe FiveK | [官方数据页](https://data.csail.mit.edu/graphics/fivek/)、[Adobe license](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobe.txt)、[Adobe/MIT license](https://data.csail.mit.edu/graphics/fivek/legal/LicenseAdobeMIT.txt) | 两份许可都写明仅可用于自身研究，不得用于面向商业优势或金钱报酬的用途。虽然它提供真实 RAW 与五位专家成片配对，但不适合直接训练商业产品。 | `blocked_commercial`；不下载、不导入、不训练。若未来获得单独商业授权，再按官方文件清单恢复配对。 |
| Unsplash Lite Dataset | [官方数据页](https://unsplash.com/data)、[官方仓库](https://github.com/unsplash/datasets)、[Dataset Terms](https://github.com/unsplash/datasets/blob/master/TERMS.md) | Lite 条款允许内部商业目的训练；许可不可转移/再许可，禁止披露、发布或再分发 Licensed Data。普通 Unsplash 图片条款禁止把网页图片用于 ML/AI 数据集，必须走 Dataset。 | `eligible_local_only_after_terms_acceptance`；本轮不代替用户接受条款，不下载。以后只能在受控本地目录使用，绝不提交图片或原始元数据。Unsplash+ 明确禁止 ML/AI，不得混入。 |
| Unsplash Full Dataset | 同上 | 仅非商业训练；由 Full 数据训练或处理的模型不得商业使用。 | `blocked_commercial`。 |
| Wikimedia Commons Featured Pictures | [官方复用说明](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia)、[MediaWiki imageinfo API](https://www.mediawiki.org/wiki/API:Imageinfo) | Commons 文件许可逐项不同。开放许可通常允许商业使用，但必须遵守署名、许可链接及可能的 ShareAlike；Commons 不保证每项权利状态，人物权、商标、艺术作品等另行处理。 | 通过官方 API 逐文件读取许可。首批只接纳 Public Domain/CC0/CC BY/CC BY-SA，保留来源和署名；像素本地 gitignore。CC BY-SA 与人物/商标风险样本禁止直接进入商业模型训练，待法务与人工复核。 |
| Open Images V7 | [官方说明与 Licenses](https://storage.googleapis.com/openimages/web/factsfigures_v7.html#licenses) | 注释为 CC BY 4.0；图片列为 CC BY 2.0，但官方明确不保证每张图片许可，要求逐文件核实。它是视觉识别数据，不等于专业摄影审美数据。 | `metadata_or_segmentation_candidate`；本轮不作为优秀摄影参考导入。未来用于分割/主体检测时必须保留逐图片来源和许可核验。 |

## 许可状态语义

- `candidate_after_legal_review`：许可文本允许当前内部分析/潜在训练，但正式商业模型训练前仍需法务和内容风险复核。
- `blocked_pending_legal_review`：当前可内部参考或特征分析，但 ShareAlike、人物权、商标/作品权等使模型训练结论不明确。
- `blocked_commercial`：官方条款明确限制非商业或研究用途，不进入商业训练。

## 本轮不使用的方式

- 不从 Unsplash 网页/API 批量抓图替代 Dataset 授权。
- 不把 FiveK 的专家成片配对复制进商业训练库。
- 不根据 Commons 的站点级描述假设所有文件同一许可。
- 不把两张构图相似的照片标记为原图/专家成片配对。
