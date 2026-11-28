# 首批五对专业 A/T 本地准入清单

本流程落实 `PT-TRAIN-004`。图片和包含个人信息的合同仅保存在被 Git 忽略的本地目录；模板中的引用字段只保存本地证据编号，不复制合同正文。

每一对在导入前必须同时满足：

1. A 为用户拥有拍摄和训练使用权的原始照片；T 与 A 是同一底片/同一资产的独立专业后期。
2. T 由可核验的独立编辑者制作，不是 ORACLE、正式 B、旧算法、网络成片或从另一张照片复制的结果。
3. 至少记录一个真实操作、该操作解决的问题、使用工具和逐图目的。
4. 商业训练、模型权重/产品分发以及必要的隐私、肖像或物业授权分别核验；声明不等于核验。
5. 使用原始资产 ID、编辑历史/sidecar/导出记录或拍摄会话记录证明同源；结构相关性仅用于辅助发现错配。
6. 先按拍摄内容去重，再按来源分配 train/validation/test；同一内容的重编码、裁剪或后期版本不得跨分区。
7. 覆盖至少五个相互独立的拍摄内容，优先包含自然风景、街道、建筑、室内和人物；人物必须具有必要授权且不以美颜目标作为 T。

执行方式：

```powershell
python -m pip install -r PhotographyDataset/requirements.txt
python PhotographyDataset/tools/import_authorized_pairs.py `
  --declarations PhotographyDataset/private/first-five.jsonl `
  --project-root D:\MasterCamera `
  --local-manifest PhotographyDataset/private/first-five-manifest.json `
  --redacted-audit PhotographyDataset/private/first-five-audit.json
```

只有 `authorization_verification.status=verified`、编辑者身份和同源血缘均核验且全部程序检查通过的记录，才计入 `eligible_pair_count`。达到五对只表示可以开展首批人工验收；达到至少二十对且按拍摄内容隔离后，才达到最小训练程序实验门槛，不代表已经证明泛化。
