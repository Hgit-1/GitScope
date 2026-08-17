# Changelog

## 0.7.0 — 2026-08-17

- “当前分支”加入分支 Overview，可浅克隆并聚合全部远程分支，同时在展开列表中查看每个分支的 Tip、长度和默认状态。
- 分支解离线固定在实际父提交节点处分离，并允许先沿新分支泳道走直线；Merge 线固定在 Merge 节点处汇入。
- 项目详情右上角改为真实 Fetch，项目库菜单也可 Fetch，并显示最近更新时间。
- 支持每小时、每 6 小时、每天或每周的 Android 后台自动 Fetch；任务受联网、电量和系统后台策略约束，私有仓库任务配置加密保存。
- 提交搜索结果支持选中后跳转到图谱位置；Commit 名称与完整 Hash 可分别点按复制。

验证信息：

- Android 版本：`0.7.0 (18)`
- APK Signature Scheme v2：通过（开发测试签名）
- Release 明文流量：已禁用
- SHA-256：`00ed356f8c8babbc0cb8b42ba8e911b0099c358e9463a56a3ff42bfbe8ac20de`

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
