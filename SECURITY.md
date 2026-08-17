# Security

## 数据处理

GitScope 默认在 Android 设备内分析仓库。临时 Git 数据位于应用私有缓存目录，并在成功或失败后清理。项目历史只保存提交图谱和聚合统计。

GitHub 访问令牌通过 `flutter_secure_storage` 进入 Android Keystore。令牌不会写入日志、项目记录或仓库 URL，也不会发送给 GitHub 以外的 Git 主机。

## 网络边界

- 仓库导入仅接受 HTTPS URL，并拒绝 URL 内嵌凭据。
- Release Android 构建禁用明文 HTTP。
- 远程 API 会拒绝本机、私网及非标准端口目标，并限制分析时间、提交数量和临时空间。

## 报告问题

请通过 GitHub Security Advisory 私下报告可能泄露凭据、绕过 URL 校验或访问设备外部数据的问题。不要在公开 Issue 中附加令牌、私有仓库地址或完整设备日志。
