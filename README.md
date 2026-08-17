# GitScope 0.7.0

GitScope 是一个面向 Android 的 Git 仓库图谱与工程数据分析应用。仓库包含三个可独立运行的部分：

- `apps/web`：React + TypeScript 高保真交互原型。
- `apps/api`：Fastify 分析 API，执行受限临时 Git 克隆并生成图谱与聚合指标。
- `apps/mobile`：Flutter Android 客户端，包含安全账号库、项目历史、CustomPainter Git Graph、报表和主题背景。

Android 0.7.0 默认使用内置 Eclipse JGit 6.4 标准模式：通过 `ls-remote` 读取分支目录，首次对默认分支执行历史深度 500 的浅克隆，用户可按需加载单一分支或“分支 Overview”中的全部远程分支。临时仓库在分析完成或失败后都会删除；持久化内容只有图谱和聚合报表。远程 API 仍可在设置中按需启用，Web 版继续使用该 API。

GitHub 和 GitLab 使用 `blob:none` 过滤传输，只下载提交关系和目录树，不下载文件正文；热点统计复用同一对象读取器并只抽样最近 250 个提交，以降低导入时间、网络流量与手机端 CPU 占用。

提交图谱使用固定 1:1 分支切换斜率：分支线在实际父提交节点处分离，Merge 线在实际 Merge 节点处汇入，第一父提交保持为主线。图谱页支持按提交内容、作者、完整/短哈希、引用及远程分支名称搜索；选中提交结果后可跳转到图谱位置，提交名称与 Hash 均可点按复制。

项目详情与项目库均可手动 Fetch，并显示“刚刚更新 / N 小时前 / N 天前 / 一月前”等时效信息。设置中可选择每小时、每 6 小时、每天或每周的 Android 系统自动任务；任务仅在联网且电量允许时执行，私有仓库的后台凭据保存在 Keystore 支持的加密配置中。HarmonyOS 的电池策略可能延后后台任务。

导入任务执行期间会显示仅驻留内存的实时克隆日志，包括远程引用读取、对象接收、增量解析、图谱生成和临时目录清理状态；成功离开导入页后日志即释放，失败时仅在当前页面保留以便诊断。

## 立即体验手机界面

```bash
npm install
npm run dev:web
```

访问 `http://localhost:4173`。界面采用手机应用工作区，不含宣传页。账号库默认为空，GitHub 账号必须用 fine-grained PAT 或 classic PAT 经过 `/user` 验证后才会加入；令牌只保留在当前 Web 会话。导入、项目搜索与收藏、分页图谱、工程报表、主题、图片背景和自动取色均已连接真实状态与 API。

生产构建与全量测试：

```bash
npm run build
npm run test:all
```

Web 端同时是可安装 PWA。生产构建会在 `apps/web/dist` 生成 Manifest、Service Worker 与离线预缓存资源；通过 HTTPS 部署后可从 Android 浏览器添加到主屏幕。

## 启动分析 API

此部分仅用于 Web、自托管或 Android 的可选“远程 API”模式；Android 默认设备内模式无需执行以下命令。

本地开发需要系统提供 `git`：

```bash
npm run dev:api
```

API 默认监听 `http://localhost:8080`。创建任务：

```bash
curl -X POST http://localhost:8080/v1/analysis-jobs \
  -H 'content-type: application/json' \
  -d '{"url":"https://github.com/octocat/Hello-World"}'
```

随后轮询 `GET /v1/analysis-jobs/{id}`，完成后访问：

- `GET /v1/projects/{projectId}/graph?cursor=0`
- `GET /v1/projects/{projectId}/reports`
- `DELETE /v1/projects/{projectId}`

私有 GitHub 仓库可在创建任务时传入 `Authorization: Bearer <短期令牌>`。令牌只存在于任务内存，不进入日志或结果存储。

## Docker 自托管

复制 `.env.example` 为 `.env` 并填写 GitHub App 凭据，然后运行：

```bash
docker compose up --build
```

API 容器使用只读根文件系统、无 Linux capabilities 和 1GB 临时目录。Worker 禁用 Git hooks、全局配置和交互式凭据，并在每次任务的 `finally` 中删除临时仓库。

Compose 将聚合后的图谱与报表持久化到 `gitscope-data` 数据卷，API 重启后历史项目仍可访问。临时源码、OAuth 令牌和账号凭据不会写入该数据文件；分析任务进度只保留在当前进程中。

## Flutter Android

仓库已使用 Flutter 3.47.0、Dart 3.13.0、Android SDK/Build Tools 36、NDK 28.2.13676358、Gradle 9.3.1、AGP 9.1 与 Kotlin 2.4 完成验证。脚本优先使用被 Git 忽略的 `.toolchains`，不存在时自动使用系统 Flutter 与 `ANDROID_SDK_ROOT`/`ANDROID_HOME`。

检查、测试与生成 Release APK：

```bash
npm run doctor:android
npm run test:mobile
npm run build:android
```

APK 输出到 `apps/mobile/build/app/outputs/flutter-apk/app-release.apk`。当前 GitHub 预发布包使用开发调试签名，仅用于侧载验证；正式分发或应用商店发布前必须配置并妥善保存独立的正式签名密钥。

Android 默认在设备内分析。可在“设置 → 分析服务”切换为远程 API；Debug/Profile 构建在模拟器中可访问 `http://10.0.2.2:8080`，Release 构建禁止明文 HTTP，真机远程 API 必须使用可访问的 HTTPS 地址。

### VPN 下的 connection error

旧版默认访问 `10.0.2.2:8080`。`10.0.2.2` 是 Android 模拟器专用的宿主机回环别名，不是真机可访问的服务器地址；全局 VPN 又可能把 `10.0.0.0/8` 或全部流量送入隧道，因此会出现超时、拒绝连接或 DNS 错误。

0.7.0 的处理方式：

- 默认使用设备内 JGit，不再连接 `10.0.2.2`。
- 设置页检测当前活动网络是否为 VPN，并针对本地路由给出具体说明。
- 仓库域名若被 VPN 阻断，会提示为 GitScope 或该域名启用分流。
- 必须使用电脑上的 API 时，可以执行 `adb reverse tcp:8080 tcp:8080`，然后把远程地址设为 `http://127.0.0.1:8080`；此方式仅在 ADB 连接期间有效。
- GitHub 令牌只允许发送到 `github.com`，不会转发给 GitLab、Bitbucket 或任意通用 Git 主机。

账号库不会内置或自动生成任何身份。Android 端支持验证 GitHub fine-grained PAT 与 classic PAT；仅将账号公开资料写入 SharedPreferences，令牌由 `flutter_secure_storage` 写入 Android Keystore。classic PAT 访问私有仓库时需授予 `repo` 权限。删除账号或清除用户数据会同时清理相应凭据。

GitHub App 回调 scheme 为 `gitscope://oauth/github`。正式发布前需要：

1. 注册 GitHub App，仅申请 Metadata、Contents、Pull Requests、Issues 的只读权限。
2. 配置 OAuth 回调与 Android App Links。
3. 在 API 环境变量中配置 Client ID/Secret。
4. 使用正式签名配置替换 Android debug signing。

## 安全边界

- 首版通用仓库只接受公开 HTTPS URL，不接受地址内嵌凭据、SSH、本机、私网和非 443 端口。
- DNS 返回任一私网地址时拒绝任务。生产环境还应在容器/网络层禁止 egress 到私网，以抵御 DNS rebinding。
- 默认限制为每分支 500 层提交历史、5 分钟和 1GB 临时空间；浅克隆或超限结果会明确标记为截断。
- Android 令牌通过 `flutter_secure_storage` 进入 Keystore；非敏感项目历史才进入普通本地数据库。

## 已验证范围

- Web：存储迁移、空账号库、账号真实性验证、真实分析流程、深色主题与对比度、PWA 生产构建。
- API：URL 安全策略、真实临时 Git 仓库分析、图谱分页、报表、删除、结果重启持久化、OAuth 未配置时的明确失败。
- Android：设备内 JGit 真实 HTTPS 克隆、原生提交/贡献者/引用/热点统计、VPN 路由诊断、存储与安全账号流程、375×667 竖屏及 667×375 横屏四个主标签、深浅主题 WCAG 对比度、静态分析和 Release APK 构建。
