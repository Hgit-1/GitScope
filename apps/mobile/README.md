# GitScope Mobile

GitScope 的 Flutter Android 客户端。应用可在设备内通过 JGit 浅克隆并分析 HTTPS Git 仓库，展示提交拓扑、分支关系、贡献报表、热点文件和临时克隆日志。

## 开发验证

从仓库根目录运行：

```bash
npm run doctor:android
npm run test:mobile
npm run build:android
```

Release APK 输出到 `build/app/outputs/flutter-apk/app-release.apk`。GitHub 预发布包使用开发签名；公开正式分发前必须替换为独立的正式签名。

## 数据与权限

- 仓库源码只存在于应用私有缓存，分析结束后删除。
- GitHub 令牌通过 Android Keystore 保存，不写入项目历史或日志。
- 图片读取权限仅用于选择自定义背景。
- Release 构建只允许 HTTPS 网络连接；Debug/Profile 构建保留模拟器本地 HTTP 调试能力。
