# Changelog

## 0.6.1 — 2026-08-17

- 在 Android 设备内使用 JGit 6.4 浅克隆分析 Git 仓库，并针对 HarmonyOS 应用私有文件系统修正锁文件与 Pack 写入兼容性。
- GitHub 与 GitLab 支持 `blob:none` 过滤传输、500 层默认历史和按需单分支分析。
- 提交图谱使用固定斜率，正确区分第一父提交与 Merge 父线，并显示分支数量和历史长度。
- 支持按提交内容、作者、SHA、引用与分支名称搜索。
- 增加贡献者、每周提交分布、热点文件和实时临时克隆日志。
- 修复从仓库页面返回主页时仓库链接输入框意外重新获得焦点的问题。
- Release 构建禁止明文 HTTP；Debug/Profile 仍允许模拟器本地调试。

GitHub APK 为开发签名的预发布测试包，不用于应用商店分发。

验证信息：

- Android 版本：`0.6.1 (17)`
- APK Signature Scheme v2：通过
- Release 明文流量：已禁用
- SHA-256：`6a6f2f81aadaf62700cddff50482973fa2487be6f10d691cac1e0cbb9e5c6244`
