# MasterCamera 编译指南

## 当前结论

现在已经需要编译验证。

原因：

- 已经涉及 AVFoundation 相机预览和拍照。
- 已经涉及 Vision 人脸检测。
- 已经涉及 Core Image 渲染和 mask 坐标。
- 已经涉及相册写入权限。
- 这些能力在 Windows 上无法验证。

## 方案 A：用 Mac + Xcode 编译

1. 将整个 `D:\MasterCamera` 项目复制到 Mac。
2. 用 Xcode 打开：

```text
MasterCamera.xcodeproj
```

3. 选择 target：

```text
MasterCamera
```

4. 设置 Apple Developer Team：

```text
Signing & Capabilities -> Team
```

5. 修改 Bundle Identifier，避免和别人冲突：

```text
com.yourname.mastercamera
```

6. 选择真实 iPhone 运行。

相机 App 必须优先真机测试，模拟器无法完整验证相机能力。

## 方案 B：GitHub Actions 云编译

项目已经添加：

```text
.github/workflows/ios-build.yml
```

用途：

- 检查 Xcode 工程能否打开。
- 检查 Swift 是否能编译。
- 检查工程引用是否缺文件。

限制：

- 不能验证真实相机。
- 不能验证人脸 mask 位置。
- 不能验证拍照方向和相册保存体验。
- 默认不做真机签名。

使用方式：

1. 将项目推送到 GitHub 仓库。
2. 打开 GitHub Actions。
3. 运行 `iOS Build` workflow。

如果你没有 Mac，先看：

```text
docs/NO_MAC_BUILD.md
```

## 推荐第一轮验证顺序

### 第一步：只编译

目标：

- 工程能打开。
- Swift 能编译。
- 没有缺文件。
- 没有 API 使用错误。

### 第二步：真机打开相机

目标：

- 相机权限弹窗正常。
- 实时预览正常。
- 前后摄切换正常。
- 点击对焦正常。

### 第三步：拍照和预览

目标：

- 能拍照。
- 拍完显示处理中状态。
- 能进入成片预览页。
- 原图 / AI 成片切换正常。
- 长按查看原图正常。

### 第四步：验证 AI 成片

目标：

- AI 成片没有崩溃。
- Core Image 输出正常。
- 人脸补光位置没有偏移。
- 质量检查状态合理。

### 第五步：保存

目标：

- 相册权限弹窗正常。
- 保存中状态正常。
- 原图和 AI 成片都进入相册。

## 第一轮最可能出现的问题

- Xcode 工程手写配置存在细节错误。
- Swift 并发隔离需要根据编译器提示微调。
- Core Image typed filter API 在当前 Xcode 版本下需要改写。
- Vision 人脸框坐标和 Core Image 坐标方向需要转换。
- 拍摄照片方向与预览方向不一致。
- 相册权限状态需要补充更多分支处理。

## 什么时候继续写 Phase 13

建议先完成至少一次 Xcode 编译。

如果编译不过，先修编译。

如果编译通过但真机视觉效果不对，先修相机方向、图片方向、人脸 mask 坐标。

等这些稳定后，再继续 Phase 13 高级光照。

