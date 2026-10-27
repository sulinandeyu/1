# PhotographyReferences 授权案例结构

知识库暂不包含伪造案例。未来每条参考记录必须提供：

```json
{
  "id": "stable-id",
  "license": {"owner": "", "grant": "", "evidencePath": ""},
  "originalPath": "",
  "editedPath": "",
  "adjustmentRecordPath": "",
  "photographerNotes": "",
  "sceneAnalysis": {"lighting": "", "subjects": [], "background": ""},
  "goals": [],
  "protectedRegions": [],
  "validation": {"reviewer": "", "date": "", "decision": "pending", "notes": ""}
}
```

## 导入规则

1. 原图、成片、授权证据缺一不可；缺失时状态只能是 `pending`。
2. 调整记录用于解释目的，不得提取成所有同类照片通用的固定参数。
3. 比较包括技术安全、问题改善和人工偏好；像素差异不能作为专业质量结论。
4. 含人物时必须额外记录身份、纹理与几何保护结果。

## 验证工具

在 PowerShell 中运行：

```powershell
.\scripts\Test-PhotographyReference.ps1 -ManifestPath .\PhotographyKnowledge\References\case.json
```

工具只验证字段、文件和授权证据是否齐全，不会把未评审案例自动标记为专业参考，也不会改写照片。
