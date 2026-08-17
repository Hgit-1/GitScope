package com.gitscope.mobile

import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.errors.InvalidRemoteException
import org.eclipse.jgit.api.errors.TransportException
import org.eclipse.jgit.diff.DiffEntry
import org.eclipse.jgit.diff.DiffFormatter
import org.eclipse.jgit.lib.Constants
import org.eclipse.jgit.lib.ProgressMonitor
import org.eclipse.jgit.lib.Ref
import org.eclipse.jgit.lib.Repository
import org.eclipse.jgit.lib.ObjectReader
import org.eclipse.jgit.revwalk.RevCommit
import org.eclipse.jgit.revwalk.RevSort
import org.eclipse.jgit.revwalk.RevWalk
import org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider
import org.eclipse.jgit.transport.FilterSpec
import org.eclipse.jgit.treewalk.CanonicalTreeParser
import org.eclipse.jgit.treewalk.EmptyTreeIterator
import org.eclipse.jgit.util.FS
import org.eclipse.jgit.util.io.DisabledOutputStream
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.URI
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

class LocalGitException(val code: String, override val message: String) : Exception(message)

typealias AnalysisLogSink = (progress: Double, stage: String, message: String) -> Unit

class LocalGitAnalyzer(private val storageRoot: File) {
    private val resultDirectory = File(storageRoot, "gitscope-results")
    private val workspaceRoot = File(storageRoot, ".gitscope-work")

    fun analyze(
        rawUrl: String,
        accessToken: String?,
        log: AnalysisLogSink = { _, _, _ -> }
    ): Map<String, Any> {
        log(0.03, "PREP", "正在校验仓库地址")
        val uri = validateUrl(rawUrl)
        val projectId = UUID.randomUUID().toString()
        val diagnosticId = projectId.take(8)
        val temporaryDirectory = File(workspaceRoot, projectId)
        val limiter = SizeAndTimeLimitMonitor(temporaryDirectory, log)
        var stage = AnalysisStage.PREPARE
        try {
            stage = AnalysisStage.CLONE
            log(0.08, "REMOTE", "正在读取远程分支目录")
            val catalog = listRemoteCatalog(uri, accessToken)
            log(0.14, "REMOTE", "发现 ${catalog.branches.size} 个分支、${catalog.tags} 个标签")
            prepareWorkspace(temporaryDirectory)
            log(0.18, "STORAGE", "临时工作区读写与锁文件检查通过")
            stage = AnalysisStage.CLONE
            log(0.20, "CLONE", "开始浅克隆默认分支，历史深度 $STANDARD_CLONE_DEPTH")
            val clone = Git.cloneRepository()
                .setURI(uri.toASCIIString())
                .setDirectory(temporaryDirectory)
                .setBare(true)
                .setCloneAllBranches(false)
                .setNoTags()
                .setDepth(STANDARD_CLONE_DEPTH)
                .setTimeout(300)
                .setProgressMonitor(limiter)
            if (supportsBloblessClone(uri.host)) {
                log(0.21, "CLONE", "已启用无 Blob 传输，仅下载图谱所需的提交与目录对象")
                clone.setTransportConfigCallback { transport ->
                    transport.filterSpec = BLOBLESS_FILTER
                }
            }
            if (!accessToken.isNullOrBlank()) {
                clone.setCredentialsProvider(
                    UsernamePasswordCredentialsProvider(authenticationUser(uri.host), accessToken)
                )
            }
            clone.call().use { git ->
                stage = AnalysisStage.ANALYZE
                log(0.76, "ANALYZE", "正在生成提交图谱与贡献统计")
                val defaultBranch = shortBranchName(git.repository.fullBranch)
                val data = decorateBranchData(
                    buildResult(git.repository),
                    catalog,
                    defaultBranch,
                    defaultBranch
                )
                stage = AnalysisStage.SAVE
                log(0.94, "SAVE", "正在保存聚合结果")
                persist(projectId, data)
                log(0.97, "SAVE", "聚合结果已保存")
            }
            return mapOf("projectId" to projectId)
        } catch (error: InvalidRemoteException) {
            throw LocalGitException(
                "GIT_REPOSITORY_NOT_FOUND",
                if (accessToken.isNullOrBlank()) {
                    "远程仓库返回 404。请确认粘贴的是仓库主页链接；私有仓库还需要选择有访问权限的账号"
                } else {
                    "远程仓库返回 404。请检查仓库链接、账号令牌的仓库权限，以及 VPN/代理分流"
                }
            )
        } catch (error: TransportException) {
            limiter.failureMessage?.let { throw LocalGitException("ANALYSIS_LIMIT", it) }
            if (error.isWorkspaceFailure(temporaryDirectory)) {
                throw analysisFailure(stage, error, diagnosticId)
            }
            throw LocalGitException("GIT_CONNECTION", transportMessage(error))
        } catch (error: LocalGitException) {
            throw error
        } catch (error: Exception) {
            throw analysisFailure(stage, error, diagnosticId)
        } finally {
            temporaryDirectory.deleteRecursively()
            log(0.99, "CLEAN", "临时 Git 仓库已删除")
        }
    }

    fun analyzeBranch(
        projectId: String,
        rawUrl: String,
        branch: String,
        accessToken: String?,
        log: AnalysisLogSink = { _, _, _ -> }
    ): Map<String, Any> {
        log(0.03, "PREP", "正在校验分支请求")
        validateProjectId(projectId)
        val uri = validateUrl(rawUrl)
        val diagnosticId = projectId.take(8)
        val temporaryDirectory = File(workspaceRoot, UUID.randomUUID().toString())
        val limiter = SizeAndTimeLimitMonitor(temporaryDirectory, log)
        var stage = AnalysisStage.PREPARE
        try {
            stage = AnalysisStage.CLONE
            log(0.08, "REMOTE", "正在刷新远程分支目录")
            val catalog = listRemoteCatalog(uri, accessToken)
            val overview = branch == BRANCH_OVERVIEW
            if (!overview && catalog.branches.none { it.name == branch }) {
                throw LocalGitException("BRANCH_NOT_FOUND", "远程仓库中不存在分支 $branch")
            }
            val previous = readProject(projectId)
            val defaultBranch = previous.optString("_defaultBranch")
                .ifBlank { catalog.branches.firstOrNull()?.name ?: "HEAD" }
            val baseline = previous.optJSONArray("_defaultCommitIds")
                ?.let(::jsonStringList).orEmpty()
            val knownLengths = previous.optJSONObject("_branchLengths")
                ?.toMap()?.toMutableMap() ?: mutableMapOf()

            prepareWorkspace(temporaryDirectory)
            log(0.18, "STORAGE", "临时工作区检查通过")
            log(
                0.20,
                "CLONE",
                if (overview) {
                    "开始浅克隆全部 ${catalog.branches.size} 个分支，单分支历史深度 $STANDARD_CLONE_DEPTH"
                } else {
                    "开始浅克隆分支 $branch，历史深度 $STANDARD_CLONE_DEPTH"
                }
            )
            val clone = Git.cloneRepository()
                .setURI(uri.toASCIIString())
                .setDirectory(temporaryDirectory)
                .setBare(true)
                .setCloneAllBranches(overview)
                .setNoTags()
                .setDepth(STANDARD_CLONE_DEPTH)
                .setTimeout(300)
                .setProgressMonitor(limiter)
            if (!overview) {
                clone
                    .setBranchesToClone(listOf("refs/heads/$branch"))
                    .setBranch("refs/heads/$branch")
            }
            if (supportsBloblessClone(uri.host)) {
                log(0.21, "CLONE", "已启用无 Blob 传输，仅下载图谱所需的提交与目录对象")
                clone.setTransportConfigCallback { transport ->
                    transport.filterSpec = BLOBLESS_FILTER
                }
            }
            if (!accessToken.isNullOrBlank()) {
                clone.setCredentialsProvider(
                    UsernamePasswordCredentialsProvider(authenticationUser(uri.host), accessToken)
                )
            }
            clone.call().use { git ->
                stage = AnalysisStage.ANALYZE
                log(
                    0.76,
                    "ANALYZE",
                    if (overview) "正在生成全部分支 Overview 图谱" else "正在生成 $branch 的单分支图谱"
                )
                val result = buildResult(git.repository)
                val data = if (overview) {
                    decorateOverviewData(result, catalog, defaultBranch, knownLengths)
                } else {
                    decorateBranchData(
                        result,
                        catalog,
                        defaultBranch,
                        branch,
                        baseline,
                        knownLengths
                    )
                }
                stage = AnalysisStage.SAVE
                log(0.94, "SAVE", if (overview) "正在保存全部分支图谱" else "正在更新分支聚合结果")
                persist(projectId, data)
                log(0.97, "SAVE", if (overview) "分支 Overview 已保存" else "分支图谱已保存")
            }
            return mapOf("projectId" to projectId, "branch" to branch)
        } catch (error: InvalidRemoteException) {
            throw LocalGitException(
                "GIT_REPOSITORY_NOT_FOUND",
                "远程仓库或分支返回 404。请检查仓库链接和账号令牌权限"
            )
        } catch (error: TransportException) {
            limiter.failureMessage?.let { throw LocalGitException("ANALYSIS_LIMIT", it) }
            if (error.isWorkspaceFailure(temporaryDirectory)) {
                throw analysisFailure(stage, error, diagnosticId)
            }
            throw LocalGitException("GIT_CONNECTION", transportMessage(error))
        } catch (error: LocalGitException) {
            throw error
        } catch (error: Exception) {
            throw analysisFailure(stage, error, diagnosticId)
        } finally {
            temporaryDirectory.deleteRecursively()
            log(0.99, "CLEAN", "临时 Git 仓库已删除")
        }
    }

    private fun listRemoteCatalog(uri: URI, accessToken: String?): RemoteCatalog {
        val command = Git.lsRemoteRepository()
            .setRemote(uri.toASCIIString())
            .setHeads(true)
            .setTags(true)
            .setTimeout(60)
        if (!accessToken.isNullOrBlank()) {
            command.setCredentialsProvider(
                UsernamePasswordCredentialsProvider(authenticationUser(uri.host), accessToken)
            )
        }
        val refs = command.call()
        val branches = refs.asSequence()
            .filter { it.name.startsWith(Constants.R_HEADS) }
            .mapNotNull { ref ->
                ref.objectId?.name?.let {
                    RemoteBranch(ref.name.removePrefix(Constants.R_HEADS), it)
                }
            }
            .distinctBy { it.name }
            .sortedBy { it.name.lowercase(Locale.US) }
            .toList()
        val tags = refs.asSequence()
            .filter { it.name.startsWith(Constants.R_TAGS) && !it.name.endsWith("^{}") }
            .map { it.name }
            .distinct()
            .count()
        return RemoteCatalog(branches, tags)
    }

    private fun prepareWorkspace(directory: File) {
        if (!workspaceRoot.exists() && !workspaceRoot.mkdirs()) {
            throw LocalGitException("LOCAL_STORAGE", "无法创建设备内分析工作区，请重启应用后重试")
        }
        workspaceRoot.listFiles()
            ?.filter { it.isDirectory && System.currentTimeMillis() - it.lastModified() > STALE_WORKSPACE_MILLIS }
            ?.forEach { it.deleteRecursively() }
        if (workspaceRoot.usableSpace < MIN_FREE_BYTES) {
            throw LocalGitException("LOCAL_STORAGE_FULL", "设备可用空间不足 128 MB，请释放空间后重试")
        }
        if (directory.exists() && !directory.deleteRecursively()) {
            throw LocalGitException("LOCAL_STORAGE", "无法清理上次的分析工作区，请重启应用后重试")
        }
        if (!directory.mkdirs()) {
            throw LocalGitException("LOCAL_STORAGE", "无法准备设备内分析工作区，请检查设备剩余空间")
        }
        val probe = File(directory, ".write-test")
        try {
            probe.writeText("ok")
        } catch (_: IOException) {
            throw LocalGitException("LOCAL_STORAGE", "应用私有目录不可写，请重启设备后重试")
        }
        val renameProbe = File(directory, ".rename-test")
        if (!probe.renameTo(renameProbe)) {
            probe.delete()
            throw LocalGitException(
                "LOCAL_STORAGE_RENAME",
                "设备无法在应用私有目录内重命名文件，请检查系统存储状态"
            )
        }
        if (renameProbe.readText() != "ok" || !renameProbe.delete()) {
            throw LocalGitException("LOCAL_STORAGE", "应用私有目录无法完成文件清理，请重启设备后重试")
        }
        val lockProbe = File(directory, ".lock-test")
        FS.DETECTED.createNewFileAtomic(lockProbe).use { token ->
            if (!token.isCreated) {
                throw LocalGitException("LOCAL_STORAGE_LOCK", "设备无法在应用私有目录内创建 Git 锁文件")
            }
        }
        if (!lockProbe.delete()) {
            throw LocalGitException("LOCAL_STORAGE_LOCK", "设备无法清理 Git 锁文件")
        }
    }

    private fun analysisFailure(
        stage: AnalysisStage,
        error: Exception,
        diagnosticId: String
    ): LocalGitException {
        val details = error.causeChainText().lowercase()
        val type = error.deepestCause().javaClass.simpleName
        val operation = when {
            ".lock" in details || "cannot lock" in details -> "LOCK"
            "/objects/pack/" in details || ".pack" in details || ".idx" in details -> "PACK"
            "/refs/" in details -> "REF"
            "/config" in details -> "CONFIG"
            "/head" in details -> "HEAD"
            else -> "FS"
        }
        val suffix = "诊断码 ${stage.code}-$operation-$type-$diagnosticId"
        return when {
            "enospc" in details || "no space left" in details ->
                LocalGitException("LOCAL_STORAGE_FULL", "设备空间不足，无法完成${stage.label}。$suffix")
            "permission denied" in details || "accessdeniedexception" in details ||
                "eacces" in details || "read-only file system" in details ->
                LocalGitException("LOCAL_STORAGE", "设备拒绝了本地 Git 文件操作，无法完成${stage.label}。请更新应用或重试；$suffix")
            "no such file" in details || "filenotfound" in details ->
                LocalGitException("LOCAL_WORKSPACE_LOST", "分析工作区在${stage.label}时不可用。请直接重试；$suffix")
            "cannot lock" in details || "lock failed" in details || ".lock" in details ->
                LocalGitException("LOCAL_WORKSPACE_LOCK", "临时仓库被占用，已清理工作区。请重试；$suffix")
            else -> LocalGitException(
                "LOCAL_GIT_ERROR",
                "设备内${stage.label}失败（$type）。请重试；若仍失败可切换远程分析。$suffix"
            )
        }
    }

    fun graph(projectId: String, cursor: Int): Map<String, Any?> {
        val graph = readProject(projectId).getJSONObject("graph")
        val commits = graph.getJSONArray("commits")
        val start = cursor.coerceIn(0, commits.length())
        val end = (start + PAGE_SIZE).coerceAtMost(commits.length())
        val page = ArrayList<Any?>(end - start)
        for (index in start until end) page += commits.getJSONObject(index).toMap()
        return mapOf(
            "commits" to page,
            "nextCursor" to if (end < commits.length()) end.toString() else null,
            "truncated" to graph.optBoolean("truncated", false)
        )
    }

    fun report(projectId: String): Map<String, Any?> =
        readProject(projectId).getJSONObject("report").toMap()

    fun deleteProject(projectId: String): Boolean {
        validateProjectId(projectId)
        val file = File(resultDirectory, "$projectId.json")
        return !file.exists() || file.delete()
    }

    internal fun buildResult(repository: Repository): Map<String, Any> {
        val refs: List<Ref> = repository.allRefs.values
            .filter { it.name.startsWith(Constants.R_REFS) }
        val refsByObject = mutableMapOf<String, MutableList<String>>()
        for (ref in refs) {
            val peeled = if (ref.isPeeled) ref else repository.refDatabase.peel(ref)
            val target = peeled.peeledObjectId ?: peeled.objectId ?: continue
            refsByObject.getOrPut(target.name) { mutableListOf() }
                .add(Repository.shortenRefName(ref.name))
        }

        val branches = refs.asSequence()
            .filter { it.name.startsWith(Constants.R_HEADS) || it.name.startsWith(Constants.R_REMOTES) }
            .map { it.name.removePrefix(Constants.R_HEADS).removePrefix(Constants.R_REMOTES).removePrefix("origin/") }
            .filter { it != "HEAD" }
            .toSet().size
        val tags = refs.count { it.name.startsWith(Constants.R_TAGS) }
        val commits = ArrayList<Map<String, Any?>>()
        val contributorCounts = mutableMapOf<String, Int>()
        val weekdays = MutableList(7) { 0 }
        val hours = MutableList(24) { 0 }
        val hotspots = mutableMapOf<String, Int>()
        val activeLanes = mutableListOf<String>()
        // A shallow repository contains only the requested recent history. Keep
        // this distinct from pagination so branch lengths are never overstated.
        var truncated = File(repository.directory, "shallow").isFile

        val hotspotReader = repository.newObjectReader()
        val hotspotFormatter = DiffFormatter(DisabledOutputStream.INSTANCE).apply {
            setRepository(repository)
            isDetectRenames = false
        }
        try {
            RevWalk(repository).use { walk ->
                walk.sort(RevSort.TOPO)
                walk.sort(RevSort.COMMIT_TIME_DESC, true)
                refs.mapNotNull { ref ->
                    val peeled = if (ref.isPeeled) ref else repository.refDatabase.peel(ref)
                    peeled.peeledObjectId ?: peeled.objectId
                }.distinctBy { it.name }.forEach { objectId ->
                    runCatching { walk.markStart(walk.parseCommit(objectId)) }
                }

                for (commit in walk) {
                if (commits.size >= MAX_COMMITS) {
                    truncated = true
                    break
                }
                val author = commit.authorIdent.name.ifBlank { "Unknown" }
                val localTime = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
                    timeInMillis = commit.commitTime.toLong() * 1000L
                }
                contributorCounts[author] = (contributorCounts[author] ?: 0) + 1
                weekdays[localTime.get(Calendar.DAY_OF_WEEK) - 1]++
                hours[localTime.get(Calendar.HOUR_OF_DAY)]++
                var lane = activeLanes.indexOf(commit.name)
                if (lane < 0) {
                    activeLanes += commit.name
                    lane = activeLanes.lastIndex
                }
                if (commit.parentCount == 0) {
                    activeLanes.removeAt(lane)
                } else {
                    // The first parent continues the current lane. Additional
                    // parents get stable adjacent lanes and visually merge into it.
                    val firstParent = commit.getParent(0).name
                    val existingFirstParentLane = activeLanes.indexOf(firstParent)
                    if (existingFirstParentLane < 0) {
                        activeLanes[lane] = firstParent
                    } else if (existingFirstParentLane != lane) {
                        activeLanes.removeAt(lane)
                    }
                    var insertionLane = (lane + 1).coerceAtMost(activeLanes.size)
                    commit.parents.drop(1).forEach { parent ->
                        if (parent.name !in activeLanes) {
                            activeLanes.add(insertionLane, parent.name)
                            insertionLane++
                        }
                    }
                }
                commits += mapOf(
                    "id" to commit.name,
                    "shortId" to commit.name.take(7),
                    "parentIds" to commit.parents.map { it.name },
                    "author" to author,
                    "authorEmail" to commit.authorIdent.emailAddress,
                    "authoredAt" to isoTimestamp(commit.commitTime.toLong() * 1000L),
                    "message" to commit.shortMessage,
                    "refs" to (refsByObject[commit.name] ?: emptyList<String>()),
                    "lane" to lane
                )
                if (commits.size <= HOTSPOT_COMMIT_LIMIT) {
                    collectChangedPaths(hotspotFormatter, hotspotReader, commit, hotspots)
                }
                }
            }
        } finally {
            hotspotFormatter.close()
            hotspotReader.close()
        }

        val contributors = contributorCounts.entries.sortedByDescending { it.value }.map {
            mapOf("name" to it.key, "commits" to it.value, "additions" to 0, "deletions" to 0)
        }
        val hotspotList = hotspots.entries.sortedByDescending { it.value }.take(12).map {
            mapOf("path" to it.key, "changes" to it.value)
        }
        val graph = mapOf(
            "commits" to commits,
            "truncated" to truncated,
            "nextCursor" to if (commits.size > PAGE_SIZE) PAGE_SIZE.toString() else null
        )
        val report = mapOf(
            "totalCommits" to commits.size,
            "branches" to branches,
            "tags" to tags,
            "contributors" to contributors,
            "commitsByWeekday" to weekdays,
            "commitsByHour" to hours,
            "hotspots" to hotspotList,
            "historyDepth" to STANDARD_CLONE_DEPTH,
            "availability" to mapOf("git" to if (truncated) "truncated" else "available"),
            "generatedAt" to isoTimestamp(System.currentTimeMillis())
        )
        return mapOf("graph" to graph, "report" to report)
    }

    @Suppress("UNCHECKED_CAST")
    private fun decorateBranchData(
        data: Map<String, Any>,
        catalog: RemoteCatalog,
        defaultBranch: String,
        currentBranch: String,
        previousDefaultCommitIds: List<String> = emptyList(),
        previousLengths: MutableMap<String, Any?> = mutableMapOf()
    ): Map<String, Any> {
        val graph = data.getValue("graph") as Map<String, Any?>
        val commits = graph.getValue("commits") as List<Map<String, Any?>>
        val currentIds = commits.mapNotNull { it["id"] as? String }
        val truncated = graph["truncated"] as? Boolean ?: false
        val defaultIds = when {
            currentBranch == defaultBranch -> currentIds
            previousDefaultCommitIds.isNotEmpty() -> previousDefaultCommitIds
            else -> emptyList()
        }
        previousLengths[currentBranch] = mapOf(
            "count" to commits.size,
            "truncated" to truncated
        )
        val relation = branchRelation(currentBranch, defaultBranch, currentIds, defaultIds)
        val report = (data.getValue("report") as Map<String, Any?>).toMutableMap()
        report["branches"] = catalog.branches.size
        report["tags"] = catalog.tags
        report["defaultBranch"] = defaultBranch
        report["currentBranch"] = currentBranch
        report["branchDetails"] = catalog.branches.map { branch ->
            val length = previousLengths[branch.name] as? Map<*, *>
            val isCurrent = branch.name == currentBranch
            mapOf(
                "name" to branch.name,
                "tip" to branch.tip,
                "isDefault" to (branch.name == defaultBranch),
                "isCurrent" to isCurrent,
                "commitCount" to length?.get("count"),
                "truncated" to (length?.get("truncated") as? Boolean ?: false),
                "ahead" to if (isCurrent) relation.ahead else null,
                "behind" to if (isCurrent) relation.behind else null,
                "relation" to if (isCurrent) relation.status else "unloaded"
            )
        }
        return mapOf(
            "graph" to graph,
            "report" to report,
            "_defaultBranch" to defaultBranch,
            "_defaultCommitIds" to defaultIds,
            "_branchLengths" to previousLengths
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun decorateOverviewData(
        data: Map<String, Any>,
        catalog: RemoteCatalog,
        defaultBranch: String,
        previousLengths: MutableMap<String, Any?>
    ): Map<String, Any> {
        val graph = data.getValue("graph") as Map<String, Any?>
        val commits = graph.getValue("commits") as List<Map<String, Any?>>
        val orderedIds = commits.mapNotNull { it["id"] as? String }
        val parentsById = commits.associate { commit ->
            val id = commit["id"] as String
            id to (commit["parentIds"] as? List<String>).orEmpty()
        }

        fun reachableIds(tip: String): Set<String> {
            val reachable = linkedSetOf<String>()
            val pending = ArrayDeque<String>()
            if (tip in parentsById) pending.add(tip)
            while (pending.isNotEmpty()) {
                val id = pending.removeLast()
                if (!reachable.add(id)) continue
                parentsById[id].orEmpty().forEach { parent ->
                    if (parent in parentsById && parent !in reachable) pending.add(parent)
                }
            }
            return reachable
        }

        val truncatedGraph = graph["truncated"] as? Boolean ?: false
        val reachableByBranch = catalog.branches.associate { branch ->
            branch.name to reachableIds(branch.tip)
        }
        catalog.branches.forEach { branch ->
            val count = reachableByBranch.getValue(branch.name).size
            previousLengths[branch.name] = mapOf(
                "count" to count,
                "truncated" to (truncatedGraph || count >= STANDARD_CLONE_DEPTH)
            )
        }
        val defaultIds = orderedIds.filter {
            it in reachableByBranch[defaultBranch].orEmpty()
        }
        val report = (data.getValue("report") as Map<String, Any?>).toMutableMap()
        report["branches"] = catalog.branches.size
        report["tags"] = catalog.tags
        report["defaultBranch"] = defaultBranch
        report["currentBranch"] = BRANCH_OVERVIEW
        report["branchDetails"] = catalog.branches.map { branch ->
            val length = previousLengths[branch.name] as? Map<*, *>
            mapOf(
                "name" to branch.name,
                "tip" to branch.tip,
                "isDefault" to (branch.name == defaultBranch),
                "isCurrent" to false,
                "commitCount" to length?.get("count"),
                "truncated" to (length?.get("truncated") as? Boolean ?: false),
                "ahead" to null,
                "behind" to null,
                "relation" to "overview"
            )
        }
        return mapOf(
            "graph" to graph,
            "report" to report,
            "_defaultBranch" to defaultBranch,
            "_defaultCommitIds" to defaultIds,
            "_branchLengths" to previousLengths
        )
    }

    private fun branchRelation(
        currentBranch: String,
        defaultBranch: String,
        currentIds: List<String>,
        defaultIds: List<String>
    ): BranchRelation {
        if (currentBranch == defaultBranch) return BranchRelation(0, 0, "default")
        if (defaultIds.isEmpty()) return BranchRelation(null, null, "unknown")
        val defaultPositions = defaultIds.withIndex().associate { it.value to it.index }
        val currentPosition = currentIds.indexOfFirst { it in defaultPositions }
        if (currentPosition < 0) return BranchRelation(null, null, "unrelated")
        val common = currentIds[currentPosition]
        val behind = defaultPositions.getValue(common)
        val status = when {
            currentPosition == 0 && behind == 0 -> "equal"
            behind == 0 -> "ahead"
            currentPosition == 0 -> "behind"
            else -> "diverged"
        }
        return BranchRelation(currentPosition, behind, status)
    }

    private fun collectChangedPaths(
        formatter: DiffFormatter,
        reader: ObjectReader,
        commit: RevCommit,
        counts: MutableMap<String, Int>
    ) {
        runCatching {
            val entries = if (commit.parentCount == 0) {
                formatter.scan(EmptyTreeIterator(), CanonicalTreeParser(null, reader, commit.tree))
            } else {
                formatter.scan(commit.getParent(0).tree, commit.tree)
            }
            for (entry in entries) {
                val path = if (entry.changeType == DiffEntry.ChangeType.DELETE) entry.oldPath else entry.newPath
                if (path != DiffEntry.DEV_NULL) counts[path] = (counts[path] ?: 0) + 1
            }
        }
    }

    private fun persist(projectId: String, data: Map<String, Any>) {
        resultDirectory.mkdirs()
        val destination = File(resultDirectory, "$projectId.json")
        val temporary = File(resultDirectory, "$projectId.tmp")
        temporary.writeText(JSONObject(data).toString())
        if (!temporary.renameTo(destination)) {
            temporary.delete()
            throw LocalGitException("LOCAL_STORAGE", "无法保存设备内分析结果")
        }
    }

    private fun readProject(projectId: String): JSONObject {
        validateProjectId(projectId)
        val file = File(resultDirectory, "$projectId.json")
        if (!file.isFile) throw LocalGitException("PROJECT_NOT_FOUND", "设备内分析结果不存在，请重新导入仓库")
        return try { JSONObject(file.readText()) }
        catch (_: Exception) { throw LocalGitException("LOCAL_STORAGE", "设备内分析结果损坏，请重新导入仓库") }
    }

    private fun validateProjectId(projectId: String) {
        if (!PROJECT_ID.matches(projectId)) throw LocalGitException("INVALID_PROJECT", "项目标识无效")
    }

    internal fun validateUrl(rawUrl: String): URI {
        val uri = try { URI(rawUrl.trim()) }
        catch (_: Exception) { throw LocalGitException("INVALID_URL", "Git 仓库地址无效") }
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null || (uri.port != -1 && uri.port != 443)) {
            throw LocalGitException("INVALID_URL", "设备内分析仅接受不含凭据和自定义端口的 HTTPS Git 地址")
        }
        val host = uri.host.lowercase(Locale.US)
        val originalPath = uri.path.orEmpty().trimEnd('/')
        val normalizedPath = when (host) {
            "github.com", "bitbucket.org", "gitee.com" -> {
                val segments = originalPath.trim('/').split('/').filter(String::isNotBlank)
                if (segments.size < 2) {
                    throw LocalGitException("INVALID_URL", "仓库链接需要包含所有者和项目名称")
                }
                "/${segments[0]}/${segments[1].removeSuffix(".git")}.git"
            }
            "gitlab.com" -> {
                val projectPath = originalPath.substringBefore("/-/").trim('/').removeSuffix(".git")
                if ('/' !in projectPath) {
                    throw LocalGitException("INVALID_URL", "GitLab 链接需要包含群组和项目名称")
                }
                "/$projectPath.git"
            }
            else -> originalPath
        }
        return URI("https", null, host, -1, normalizedPath, null, null)
    }

    private fun authenticationUser(host: String): String = when {
        host.equals("github.com", true) -> "x-access-token"
        host.equals("gitlab.com", true) -> "oauth2"
        host.equals("bitbucket.org", true) -> "x-token-auth"
        else -> "oauth2"
    }

    private fun supportsBloblessClone(host: String): Boolean =
        host.equals("github.com", true) || host.equals("gitlab.com", true)

    private fun shortBranchName(ref: String?): String = ref.orEmpty()
        .removePrefix(Constants.R_HEADS)
        .removePrefix(Constants.R_REMOTES)
        .removePrefix("origin/")
        .ifBlank { "HEAD" }

    private fun isoTimestamp(epochMillis: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date(epochMillis))

    private fun transportMessage(error: TransportException): String {
        val raw = error.message.orEmpty().lowercase()
        return when {
            "not authorized" in raw || "authentication" in raw || "401" in raw || "403" in raw ->
                "仓库拒绝了访问令牌，请检查账号权限或仓库可见性"
            "unknownhost" in raw || "resolve" in raw ->
                "无法解析仓库域名；VPN 或私有 DNS 可能阻止了域名解析"
            "timed out" in raw || "timeout" in raw ->
                "连接仓库超时；VPN 可能接管或阻断了仓库网络"
            else -> "无法连接 Git 仓库；请检查仓库地址、VPN 分流和网络权限"
        }
    }

    companion object {
        private const val PAGE_SIZE = 300
        private const val STANDARD_CLONE_DEPTH = 500
        private const val MAX_COMMITS = 20_000
        private const val HOTSPOT_COMMIT_LIMIT = 250
        private const val MIN_FREE_BYTES = 128L * 1024L * 1024L
        private const val STALE_WORKSPACE_MILLIS = 24L * 60L * 60L * 1000L
        private const val BRANCH_OVERVIEW = "__gitscope_all_branches__"
        private val BLOBLESS_FILTER = FilterSpec.fromFilterLine("blob:none")
        private val PROJECT_ID = Regex("^[0-9a-fA-F-]{36}$")
    }
}

private data class RemoteBranch(val name: String, val tip: String)
private data class RemoteCatalog(val branches: List<RemoteBranch>, val tags: Int)
private data class BranchRelation(val ahead: Int?, val behind: Int?, val status: String)

private enum class AnalysisStage(val code: String, val label: String) {
    PREPARE("PREP", "准备工作区"),
    CLONE("CLONE", "克隆仓库"),
    ANALYZE("ANALYZE", "生成图谱"),
    SAVE("SAVE", "保存报表")
}

private class SizeAndTimeLimitMonitor(
    private val directory: File,
    private val log: AnalysisLogSink
) : ProgressMonitor {
    private val startedAt = System.currentTimeMillis()
    private var lastSizeCheck = 0L
    private var taskTitle = "传输 Git 对象"
    private var totalWork = ProgressMonitor.UNKNOWN
    private var completedWork = 0
    private var lastLoggedPercent = -1
    private var lastLogAt = 0L
    var failureMessage: String? = null
        private set

    override fun start(totalTasks: Int) {
        log(0.22, "CLONE", if (totalTasks > 0) "Git 传输已启动，共 $totalTasks 个阶段" else "Git 传输已启动")
    }

    override fun beginTask(title: String?, totalWork: Int) {
        taskTitle = displayTask(title)
        this.totalWork = totalWork
        completedWork = 0
        lastLoggedPercent = -1
        lastLogAt = 0L
        log(0.24, "CLONE", taskTitle)
    }

    override fun update(completed: Int) {
        completedWork += completed.coerceAtLeast(0)
        val now = System.currentTimeMillis()
        if (totalWork > 0) {
            val percent = (completedWork.toLong() * 100L / totalWork).coerceIn(0L, 100L).toInt()
            if (percent >= lastLoggedPercent + 5 || now - lastLogAt >= 1000L) {
                lastLoggedPercent = percent
                lastLogAt = now
                log(0.24 + percent * 0.0048, "CLONE", "$taskTitle · $percent% ($completedWork/$totalWork)")
            }
        } else if (now - lastLogAt >= 1000L) {
            lastLogAt = now
            log(0.48, "CLONE", "$taskTitle · 已处理 $completedWork")
        }
    }

    override fun endTask() {
        log(0.72, "CLONE", "$taskTitle · 完成")
    }
    override fun isCancelled(): Boolean {
        if (failureMessage != null) return true
        val now = System.currentTimeMillis()
        if (now - startedAt > MAX_ANALYSIS_MILLIS) {
            failureMessage = "设备内分析超过 5 分钟，已安全中止"
            return true
        }
        if (now - lastSizeCheck >= SIZE_CHECK_INTERVAL_MILLIS) {
            lastSizeCheck = now
            val size = directory.walkTopDown().filter { it.isFile }.sumOf { it.length() }
            if (size > MAX_TEMP_BYTES) {
                failureMessage = "设备内临时仓库超过 1 GB，已安全中止"
                return true
            }
        }
        return false
    }

    private fun displayTask(rawTitle: String?): String {
        val title = rawTitle.orEmpty().replace(directory.absolutePath, "<临时目录>").trim()
        val translated = when {
            title.contains("Counting objects", ignoreCase = true) -> "正在统计对象"
            title.contains("Finding sources", ignoreCase = true) -> "正在查找对象来源"
            title.contains("Getting sizes", ignoreCase = true) -> "正在读取对象大小"
            title.contains("Compressing objects", ignoreCase = true) -> "正在压缩对象"
            title.contains("Receiving objects", ignoreCase = true) -> "正在接收对象"
            title.contains("Resolving deltas", ignoreCase = true) -> "正在解析增量"
            title.contains("Updating references", ignoreCase = true) -> "正在更新引用"
            title.isBlank() -> "正在传输 Git 对象"
            else -> title
        }
        return translated.take(120)
    }

    companion object {
        private const val MAX_ANALYSIS_MILLIS = 5 * 60 * 1000L
        private const val MAX_TEMP_BYTES = 1024L * 1024L * 1024L
        private const val SIZE_CHECK_INTERVAL_MILLIS = 750L
    }
}

private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key -> valueToPlatform(opt(key)) }
private fun JSONArray.toList(): List<Any?> = (0 until length()).map { valueToPlatform(opt(it)) }
private fun jsonStringList(value: JSONArray): List<String> =
    (0 until value.length()).mapNotNull { value.optString(it).takeIf(String::isNotBlank) }
private fun valueToPlatform(value: Any?): Any? = when (value) {
    is JSONObject -> value.toMap()
    is JSONArray -> value.toList()
    JSONObject.NULL -> null
    else -> value
}

private fun Throwable.causeChainText(): String = generateSequence(this) { current -> current.cause }
    .take(12)
    .joinToString(" | ") { current ->
        "${current.javaClass.simpleName}: ${current.message.orEmpty()}"
    }

private fun Throwable.deepestCause(): Throwable =
    generateSequence(this) { current -> current.cause }.take(12).last()

private fun Throwable.isWorkspaceFailure(directory: File): Boolean {
    val details = causeChainText()
    return directory.absolutePath in details ||
        "No space left on device" in details ||
        "Read-only file system" in details
}
