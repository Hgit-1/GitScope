package com.gitscope.mobile

import org.eclipse.jgit.api.Git
import org.eclipse.jgit.lib.PersonIdent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.Date
import java.util.TimeZone

class LocalGitAnalyzerTest {
    @Test
    fun `buildResult derives graph contributors refs and hotspots from a real repository`() {
        val root = Files.createTempDirectory("gitscope-jgit-test-").toFile()
        val repositoryDirectory = File(root, "repository")
        try {
            Git.init().setDirectory(repositoryDirectory).call().use { git ->
                val author = PersonIdent(
                    "Verified User",
                    "verified@example.com",
                    Date.from(Instant.parse("2026-08-17T08:00:00Z")),
                    TimeZone.getTimeZone("UTC")
                )
                File(repositoryDirectory, "README.md").writeText("# Local analysis\n")
                git.add().addFilepattern("README.md").call()
                git.commit().setMessage("local verified commit").setAuthor(author).setCommitter(author).call()
                git.tag().setName("v0.3.0").call()

                val analyzer = LocalGitAnalyzer(File(root, "store"))
                val data = analyzer.buildResult(git.repository)
                @Suppress("UNCHECKED_CAST")
                val graph = data["graph"] as Map<String, Any?>
                @Suppress("UNCHECKED_CAST")
                val commits = graph["commits"] as List<Map<String, Any?>>
                @Suppress("UNCHECKED_CAST")
                val report = data["report"] as Map<String, Any?>
                @Suppress("UNCHECKED_CAST")
                val contributors = report["contributors"] as List<Map<String, Any?>>
                @Suppress("UNCHECKED_CAST")
                val hotspots = report["hotspots"] as List<Map<String, Any?>>

                assertEquals(1, commits.size)
                assertEquals("local verified commit", commits.single()["message"])
                assertTrue((commits.single()["refs"] as List<*>).contains("v0.3.0"))
                assertEquals("Verified User", contributors.single()["name"])
                assertEquals(1, report["totalCommits"])
                assertEquals(1, report["tags"])
                assertEquals("README.md", hotspots.single()["path"])
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `embedded JGit clones and analyzes a public HTTPS repository`() {
        assumeTrue(System.getenv("GITSCOPE_INTEGRATION") == "true")
        val root = Files.createTempDirectory("gitscope-jgit-network-").toFile()
        try {
            val analyzer = LocalGitAnalyzer(File(root, "store"))
            val liveStages = mutableListOf<String>()
            val projectId = analyzer.analyze(
                "https://github.com/octocat/Hello-World.git",
                null
            ) { _, stage, message -> liveStages += "$stage:$message" }["projectId"] as String
            val graph = analyzer.graph(projectId, 0)
            val report = analyzer.report(projectId)
            assertTrue((graph["commits"] as List<*>).isNotEmpty())
            assertTrue((report["totalCommits"] as Int) > 0)
            assertTrue((report["branches"] as Int) > 0)
            assertTrue(liveStages.any { it.startsWith("CLONE:") })
            assertTrue(liveStages.any { it.startsWith("CLEAN:") })
            @Suppress("UNCHECKED_CAST")
            val branchDetails = report["branchDetails"] as List<Map<String, Any?>>
            assertTrue(branchDetails.isNotEmpty())
            val otherBranch = branchDetails.firstOrNull { it["isCurrent"] != true }
            if (otherBranch != null) {
                val branchName = otherBranch["name"] as String
                analyzer.analyzeBranch(
                    projectId,
                    "https://github.com/octocat/Hello-World.git",
                    branchName,
                    null
                )
                assertEquals(branchName, analyzer.report(projectId)["currentBranch"])
            }
            assertTrue(analyzer.deleteProject(projectId))
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `embedded JGit performs a protocol level shallow clone`() {
        assumeTrue(System.getenv("GITSCOPE_INTEGRATION") == "true")
        val root = Files.createTempDirectory("gitscope-jgit-shallow-").toFile()
        val repositoryDirectory = File(root, "repository")
        try {
            Git.cloneRepository()
                .setURI("https://github.com/eclipse-jgit/jgit.git")
                .setDirectory(repositoryDirectory)
                .setBare(true)
                .setCloneAllBranches(false)
                .setNoTags()
                .setDepth(5)
                .call().use { git ->
                    assertTrue(File(git.repository.directory, "shallow").isFile)
                    // Git depth counts ancestry generations, so merge commits can
                    // make the reachable commit total slightly greater than five.
                    assertTrue(git.log().call().count() in 5..20)
                }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `merge topology produces dynamic lanes and parent relationships`() {
        val root = Files.createTempDirectory("gitscope-lanes-test-").toFile()
        val repositoryDirectory = File(root, "repository")
        try {
            Git.init().setDirectory(repositoryDirectory).call().use { git ->
                val author = PersonIdent("Lane User", "lanes@example.com")
                git.repository.config.apply {
                    setString("user", null, "name", "Lane User")
                    setString("user", null, "email", "lanes@example.com")
                    save()
                }
                File(repositoryDirectory, "base.txt").writeText("base\n")
                git.add().addFilepattern("base.txt").call()
                git.commit().setMessage("base").setAuthor(author).setCommitter(author).call()
                git.branchCreate().setName("feature").call()
                git.checkout().setName("feature").call()
                File(repositoryDirectory, "feature.txt").writeText("feature\n")
                git.add().addFilepattern("feature.txt").call()
                val feature = git.commit().setMessage("feature").setAuthor(author).setCommitter(author).call()
                git.checkout().setName("master").call()
                File(repositoryDirectory, "main.txt").writeText("main\n")
                git.add().addFilepattern("main.txt").call()
                git.commit().setMessage("main").setAuthor(author).setCommitter(author).call()
                git.merge().include(feature).setMessage("merge feature").call()

                val analyzer = LocalGitAnalyzer(File(root, "store"))
                val data = analyzer.buildResult(git.repository)
                @Suppress("UNCHECKED_CAST")
                val commits = (data["graph"] as Map<String, Any?>)["commits"] as List<Map<String, Any?>>
                val mergeCommit = commits.first { (it["parentIds"] as List<*>).size == 2 }
                @Suppress("UNCHECKED_CAST")
                val mergeParents = mergeCommit["parentIds"] as List<String>
                val firstParent = commits.first { it["id"] == mergeParents.first() }
                assertEquals(mergeCommit["lane"], firstParent["lane"])
                assertTrue(commits.maxOf { it["lane"] as Int } > 0)
                @Suppress("UNCHECKED_CAST")
                val report = data["report"] as Map<String, Any?>
                assertEquals(
                    commits.size,
                    (report["commitsByWeekday"] as List<Int>).sum()
                )
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `repository web links are normalized to clone endpoints`() {
        val root = Files.createTempDirectory("gitscope-url-test-").toFile()
        try {
            val analyzer = LocalGitAnalyzer(File(root, "store"))
            assertEquals(
                "https://github.com/openai/codex.git",
                analyzer.validateUrl("https://github.com/openai/codex/tree/main").toASCIIString()
            )
            assertEquals(
                "https://gitlab.com/group/nested/project.git",
                analyzer.validateUrl("https://gitlab.com/group/nested/project/-/tree/main").toASCIIString()
            )
            assertEquals(
                "https://bitbucket.org/team/project.git",
                analyzer.validateUrl("https://bitbucket.org/team/project/src/main/").toASCIIString()
            )
        } finally {
            root.deleteRecursively()
        }
    }
}
