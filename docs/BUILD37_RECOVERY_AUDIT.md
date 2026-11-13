# Build 37 中断恢复审计

审计时间：2026-11-14（Asia/Shanghai）  
审计范围：`D:\MasterCamera` 当前工作区、Git 历史、Apple CI、TestFlight 历史、Build 36 真机证据、A/T/R 反求证据及当前 Windows 实验产物。

## 1. 当前工作现场

| 项目 | 状态 | 证据 |
|---|---|---|
| 当前分支 | completed | `codex/build36-cinematic-core-overhaul-20261113` |
| 当前摄影源码 HEAD | completed | `b310d53dfe1593976bb8e77417f22a4f5d294ca8`，与远程分支相同 |
| 最近摄影实现 | completed | `8446dfa8` 增加测量驱动冷调电影分级，`e798ffbf`、`1eff8392` 修复编译问题 |
| 未提交摄影源码 | completed | 无；诊断开关接线修复已提交为 `b310d53d` 并由 Apple CI 验证 |
| 未跟踪文件 | completed（已保护） | Build 27 证据、学习原型、摄影数据许可记录、`output/`、`tmp/`、教程与参考图等均未清理、未提交 |
| 最新进度记录 | completed | `docs/BUILD36_CINEMATIC_CORE_OVERHAUL.md`、`docs/PHOTOGRAPHY_IMPLEMENTATION_PROGRESS.md` |
| 新 TestFlight 上传 | completed | 当前摄影核心改动后没有上传；最新上传仍是 Build 36 |

## 2. 最近 15 个提交

1. `1eff8392` Fix cinematic pixel test channel access
2. `e798ffbf` Fix measured cinematic grade scope
3. `8446dfa8` Implement measured cool cinematic diagnostic grading
4. `3f7f3dd1` Record cool cinematic Build 36 validation
5. `99a04d34` Fix Swift cinematic evidence type checking
6. `769540e0` Implement measured cool cinematic diagnostics
7. `8261ccee` Record target exploration validation
8. `356d1093` Fix measured target exploration fixture
9. `f766cea5` Validate target exploration with Core Image pixels
10. `970567e9` Redesign measured aesthetic target exploration
11. `febdb62b` Fix PhotosPicker batch import compile
12. `d5ba8396` Add serial iPhone candidate batch evidence
13. `2f0ce155` Record candidate validation build
14. `f6666064` Clean candidate validation report formatting
15. `0e2f600b` Separate candidate generation from candidate selection

恢复后新增提交：`b310d53d` Fix measured cinematic diagnostic test opt-in。

## 3. 上一轮摄影整改的实际完成度

| 能力 | 状态 | 审计结论 |
|---|---|---|
| `PT-AESTHETIC-012` 知识规则与代码映射 | completed | 已记录来源、测量输入、适用边界、副作用与验证方式 |
| 冷调电影目标字段 | completed | 阴影冷、中间调冷、弱暖高光、中性亮部保护和冷暖分离已进入配方结构 |
| Core Image 测量驱动分级算子 | completed | 已接入既有 `CinematicColorGradingEngine`，不是平行渲染器 |
| 正式 B 隔离 | completed（源码证据） | 正式路径保留 `.legacy`；测量电影分级只由诊断开关启用 |
| 人物保护 | incomplete | 检测到人物时会关闭全局电影分级，但没有当前源码的真实人像 Core Image 像素验收 |
| Windows 自动投影 | completed（模拟证据） | 秋季道路、建筑、阴天植被、人像安全、室内均已输出；不能视为 Apple/iPhone 验收 |
| Apple 合成像素测试 | completed（单项） | iOS Build #113 中冷暗区与中性亮部合成像素测试通过 |
| 当前源码完整 Apple 测试 | completed | iOS Build #114：99/99 测试通过，iOS Simulator `BUILD SUCCEEDED` |
| 当前源码秋季道路真实 Core Image 成片 | incomplete | 不存在；现有真实成片来自 Build 36 旧源码 |
| 当前源码跨场景真实 Core Image 成片 | incomplete | 不存在 |
| 当前源码人工摄影审美验收 | unknown | 尚未取得；Build 36 已被用户明确否决 |

## 4. Apple CI 与发布历史

### 当前分支

- iOS Build #111，`8446dfa8c1279ff2a02d49a8d275389dbc6f9751`：编译失败。
- iOS Build #112，`e798ffbf079e405eb77cc70d562eff3ca9b3deed`：测试源码编译失败。
- iOS Build #113，`1eff8392583d833a123fe421d1b385f5e88cc177`：Swift 编译和 Core Image 测试已运行，但 99 项中有 1 个测试函数的 4 个断言失败，Simulator 构建未执行。
- 失败根因已经定位：诊断测试创建了测量目标，却没有打开 `enableMeasuredAestheticPlanning`，因此得到 legacy 配方。这是测试接线问题，不是允许忽略的失败。
- iOS Build #114，`b310d53dfe1593976bb8e77417f22a4f5d294ca8`：接线修复后 99/99 测试通过，iOS Simulator 构建成功。运行地址：<https://github.com/sulinandeyu/1/actions/runs/43470285795>。

### 最近成功基线与 TestFlight

- iOS Build #110，`e486b74a43f885cfb829ba7da5bd766f540931cb`：成功，但不包含当前核心提交。
- Build 36 的已验证摄影源码：`17badd171672f4dcf1c0d57d15c2be2b0536440b`，iOS Build #109 成功。
- TestFlight Release #47/#48：上传 `17badd...`，版本 `1.0 (36)`；这是当前最后一次上传。
- 当前分支没有 Build 37 上传记录，避免了重复发布。

## 5. 秋季道路 A/T/R 证据

### 文件与来源状态

- Build 36 真机 A：来自私有诊断 ZIP，SHA-256 `411C71022136DA94C667E829F807CA21A8815CB5D69480D913334498CD2F0E28`。
- 逆向求解 A：SHA-256 `7A6C4F182538C5C5FB7A3F3C090E034CF13F47D6A83595D51C15D5DE96220402`。
- 两者是同一摄影案例，但因尺寸/编码不同并非字节同一文件，不能宣称 SHA 匹配。
- T 只保存在本地研究目录，不进入自动推理、App 资源、公开仓库或商业训练。

### 已知目标表达能力

- Windows 反求 R3-W 将道路、植被、天空和冷暖关系明显拉近 T，说明现有确定性算子具有较强表达潜力。
- 这是“已知目标 + Windows 数学实现”的证据，不是自主摄影决策证据，也不是 Apple Core Image 一致性证据。

### 当前自动算法投影

- 自动求解时未读取 T；秋季道路平均编码亮度从 `0.6313` 降到 `0.5269`。
- 新自动投影相对 T 的 RGB MAE 仍约 `0.2191`，道路亮度约 `0.2517`（T 约 `0.0637`），整体明显更浅、更平。
- 道路与植被相对亮度关系约 `+0.0003`，而 T 约 `-0.1189`，说明空间影调目标没有建立成功。
- 结论：相对旧 D 有可见变化，但冷调电影感仍未成立。

## 6. 跨场景证据

| 场景 | 状态 | 结果 |
|---|---|---|
| 建筑 | incomplete | Windows 投影呈冷灰，未见明显脏青；没有 Apple 实图 |
| 阴天植被 | failed（泛化） | Windows 投影偏暗、偏冷，规则强度不稳定 |
| 室内 | failed（泛化） | Windows 投影出现过强蓝青阴影 |
| 人像 | incomplete | 全局分级被关闭，未完成肤色/纹理真实像素验证 |

## 7. 中断点结论

当前工作不是“已完成待发布”，而是停在以下位置：

1. 冷调电影分级算子和诊断接线已实现。
2. 当前摄影源码 SHA 的 Apple 全套测试已经通过；这只关闭工程接线阻碍，不构成摄影审美通过。
3. 没有当前源码的真实 Apple/iPhone 秋季道路及跨场景成片。
4. Windows 投影证明规则式自动目标仍不能安全泛化，室内和植被存在明显问题。
5. Build 36 已被用户明确判定摄影效果失败。

因此恢复审计状态为：**开发实现与 Apple 工程验证已完成到诊断候选阶段，真实摄影效果仍未通过，发布尚未开始。**
