# MasterCamera 无 Mac 编译方案

## 当前结论

没有 Mac 也可以继续推进，但要把验证拆成两层：

- 云端编译：检查 Xcode 工程、Swift 代码、文件引用和基础 API 是否能通过编译。
- 真机验证：检查相机权限、实时取景、拍照、方向、人脸补光位置、相册保存。

云端编译可以先做。

真机验证最终仍然需要一台真实 iPhone 加一个能运行 Xcode 的 macOS 环境。

## 推荐路线

### 第一阶段：GitHub Actions 云编译

项目已经包含 workflow：

```text
.github/workflows/ios-build.yml
```

它会在 GitHub 的 macOS runner 上执行：

```text
xcodebuild build
```

用途：

- 检查 `MasterCamera.xcodeproj` 能否被 Xcode 打开。
- 检查 Swift 文件是否有编译错误。
- 检查 project 文件是否漏引用。
- 检查基础 iOS SDK API 是否可用。

限制：

- 不能打开真实摄像头。
- 不能验证照片方向。
- 不能验证相册保存体验。
- 不能验证人脸 mask 位置是否准确。
- 不能安装到你的 iPhone。

### 第二阶段：一次性真机验证

云编译通过后，再做一次真机验证。

可选方式：

- 借朋友的 Mac。
- 去线下 Apple Store / 工作室环境短时间测试。
- 租云 Mac，并把 iPhone 连接能力作为选择条件。
- 后续再考虑购买二手 Mac mini。

第一轮不用急着买机器。

## GitHub Actions 使用步骤

### 第一步：创建 GitHub 仓库

创建一个新仓库，例如：

```text
MasterCamera
```

可以先建私有仓库。

### 第二步：推送项目

在当前 Windows 项目目录执行：

```text
git init
git add .
git commit -m "Initial MasterCamera prototype"
git branch -M main
git remote add origin <你的 GitHub 仓库地址>
git push -u origin main
```

如果你还没有安装 GitHub CLI，也可以用 GitHub Desktop 上传整个目录。

### 第三步：运行云编译

进入 GitHub 仓库页面：

```text
Actions -> iOS Build -> Run workflow
```

如果没有看到 `Run workflow`，可以随便推送一次代码，workflow 会自动触发。

### 第四步：把错误发回来

如果失败，请打开失败的 workflow，复制第一段红色错误。

优先发这些信息：

- 失败的 step 名称。
- 第一条 Swift / Xcode 红色错误。
- 报错文件名。
- 报错行号。
- GitHub Actions 显示的 Xcode 版本。

不要一次性发完整日志，第一批错误最有价值。

## 我们现在的推进方式

在你没有 Mac 的情况下，建议顺序改成：

1. 先把项目推到 GitHub。
2. 用 GitHub Actions 跑第一次云编译。
3. 根据云编译错误修工程和 Swift 代码。
4. 云编译通过后，再安排一次真机测试。
5. 真机测试稳定后，再继续高级光照、风格引擎和更复杂的 AI 成片策略。

## 不能跳过真机的原因

相机 App 和普通 App 不一样。

以下问题只有真机能确认：

- 摄像头权限弹窗。
- 实时取景是否黑屏。
- 前后摄切换是否稳定。
- 拍照方向是否正确。
- 人脸补光区域是否偏移。
- 保存到相册是否成功。
- 处理速度是否能接受。

所以 GitHub Actions 解决的是“能不能编译”，真机解决的是“能不能真实使用”。

