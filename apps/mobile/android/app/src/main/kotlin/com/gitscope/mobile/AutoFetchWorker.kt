package com.gitscope.mobile

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.TimeUnit

object AutoFetchScheduler {
    private const val UNIQUE_WORK = "gitscope-periodic-fetch"
    private const val SECURE_PREFS = "gitscope_auto_fetch_secure"
    private const val CONFIGS_KEY = "projects"

    fun configure(
        context: Context,
        intervalHours: Int,
        projects: List<Map<String, Any?>>
    ) {
        require(intervalHours == 0 || intervalHours >= 1) {
            "自动 Fetch 周期不能短于 1 小时"
        }
        securePreferences(context).edit()
            .putString(CONFIGS_KEY, JSONArray(projects).toString())
            .apply()
        val workManager = WorkManager.getInstance(context)
        if (intervalHours == 0 || projects.isEmpty()) {
            workManager.cancelUniqueWork(UNIQUE_WORK)
            return
        }
        val request = PeriodicWorkRequestBuilder<AutoFetchWorker>(
            intervalHours.toLong(),
            TimeUnit.HOURS
        )
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .setRequiresBatteryNotLow(true)
                    .build()
            )
            .addTag(UNIQUE_WORK)
            .build()
        workManager.enqueueUniquePeriodicWork(
            UNIQUE_WORK,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    internal fun projectConfigs(context: Context): JSONArray = JSONArray(
        securePreferences(context).getString(CONFIGS_KEY, "[]") ?: "[]"
    )

    private fun securePreferences(context: Context) =
        EncryptedSharedPreferences.create(
            context,
            SECURE_PREFS,
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
}

class AutoFetchWorker(
    appContext: Context,
    parameters: WorkerParameters
) : Worker(appContext, parameters) {
    override fun doWork(): Result {
        val configs = AutoFetchScheduler.projectConfigs(applicationContext)
        if (configs.length() == 0) return Result.success()
        val analyzer = LocalGitAnalyzer(applicationContext.filesDir)
        for (index in 0 until configs.length()) {
            val config = configs.optJSONObject(index) ?: continue
            val projectId = config.optString("id")
            val url = config.optString("url")
            if (projectId.isBlank() || url.isBlank()) continue
            try {
                val report = analyzer.report(projectId)
                val branch = (report["currentBranch"] as? String)
                    ?.ifBlank { report["defaultBranch"] as? String ?: "HEAD" }
                    ?: (report["defaultBranch"] as? String ?: "HEAD")
                analyzer.analyzeBranch(
                    projectId,
                    url,
                    branch,
                    config.optString("accessToken").ifBlank { null }
                )
                markProjectFetched(projectId, System.currentTimeMillis())
            } catch (_: Exception) {
                // A single deleted, private, or temporarily unavailable repository
                // must not prevent the remaining scheduled projects from updating.
            }
        }
        // Periodic work will run again at the configured interval. Avoid a rapid
        // retry loop when every repository is temporarily unavailable or needs
        // renewed credentials.
        return Result.success()
    }

    private fun markProjectFetched(projectId: String, timestamp: Long) {
        val preferences = applicationContext.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE
        )
        val key = "flutter.projects_v2"
        val raw = preferences.getString(key, null) ?: return
        val projects = runCatching { JSONArray(raw) }.getOrNull() ?: return
        for (index in 0 until projects.length()) {
            val project = projects.optJSONObject(index) ?: continue
            if (project.optString("id") == projectId) {
                project.put("lastFetchedAt", Instant.ofEpochMilli(timestamp).toString())
                break
            }
        }
        preferences.edit().putString(key, projects.toString()).apply()
    }
}
