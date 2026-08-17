package com.gitscope.mobile

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private lateinit var analyzer: LocalGitAnalyzer
    private var pendingMediaPermissionResult: MethodChannel.Result? = null
    @Volatile private var analysisEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        analyzer = LocalGitAnalyzer(filesDir)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethod)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, ANALYSIS_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    analysisEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    analysisEventSink = null
                }
            })
    }

    private fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "networkStatus" -> result.success(networkStatus())
            "health" -> result.success(
                mapOf("status" to "ok", "engine" to "jgit-android-shallow", "version" to "6.4")
            )
            "mediaPermissionStatus" -> result.success(mediaPermissionStatus())
            "requestMediaPermission" -> requestMediaPermission(result)
            "openAppSettings" -> openAppSettings(result)
            "configureAutoFetch" -> {
                try {
                    AutoFetchScheduler.configure(
                        this,
                        call.argument<Int>("intervalHours") ?: 0,
                        call.argument<List<Map<String, Any?>>>("projects").orEmpty()
                    )
                    result.success(true)
                } catch (error: Exception) {
                    result.error("AUTO_FETCH_CONFIG", error.safeMessage(), null)
                }
            }
            "analyze", "analyzeBranch", "graph", "report", "deleteProject" -> executor.execute {
                val sessionId = call.argument<String>("sessionId").orEmpty()
                val logger = { progress: Double, stage: String, message: String ->
                    emitAnalysisLog(sessionId, progress, stage, message)
                }
                try {
                    val value = when (call.method) {
                        "analyze" -> analyzer.analyze(
                            requireNotNull(call.argument<String>("url")),
                            call.argument<String>("accessToken"),
                            logger
                        )
                        "analyzeBranch" -> analyzer.analyzeBranch(
                            requireNotNull(call.argument<String>("projectId")),
                            requireNotNull(call.argument<String>("url")),
                            requireNotNull(call.argument<String>("branch")),
                            call.argument<String>("accessToken"),
                            logger
                        )
                        "graph" -> analyzer.graph(
                            requireNotNull(call.argument<String>("projectId")),
                            call.argument<Int>("cursor") ?: 0
                        )
                        "report" -> analyzer.report(requireNotNull(call.argument<String>("projectId")))
                        else -> analyzer.deleteProject(requireNotNull(call.argument<String>("projectId")))
                    }
                    if (call.method == "analyze" || call.method == "analyzeBranch") {
                        emitAnalysisLog(sessionId, 1.0, "DONE", "设备内分析完成")
                    }
                    runOnUiThread { result.success(value) }
                } catch (error: LocalGitException) {
                    emitAnalysisLog(sessionId, null, "ERROR", error.message)
                    runOnUiThread { result.error(error.code, error.message, null) }
                } catch (error: Exception) {
                    emitAnalysisLog(sessionId, null, "ERROR", "设备内 Git 任务异常：${error.javaClass.simpleName}")
                    runOnUiThread { result.error("LOCAL_GIT_ERROR", error.safeMessage(), null) }
                } catch (error: LinkageError) {
                    emitAnalysisLog(sessionId, null, "ERROR", "Git 引擎与当前系统不兼容")
                    // Missing Java/runtime classes must be reported to Flutter instead
                    // of escaping the worker thread and terminating the Android app.
                    runOnUiThread {
                        result.error(
                            "LOCAL_ENGINE_INCOMPATIBLE",
                            "当前设备无法启动内置 Git 引擎，请升级应用后重试。",
                            error.javaClass.simpleName
                        )
                    }
                } catch (error: Throwable) {
                    // A repository can still exhaust a vendor runtime in unusual ways.
                    // Keep every native failure on the MethodChannel boundary.
                    val message = if (error is OutOfMemoryError) {
                        "仓库超出当前设备可用内存，请改用远程分析服务。"
                    } else {
                        error.safeMessage()
                    }
                    emitAnalysisLog(sessionId, null, "ERROR", message)
                    runOnUiThread { result.error("LOCAL_ENGINE_FAILURE", message, null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun emitAnalysisLog(
        sessionId: String,
        progress: Double?,
        stage: String,
        message: String
    ) {
        if (sessionId.isBlank()) return
        runOnUiThread {
            analysisEventSink?.success(
                mapOf(
                    "sessionId" to sessionId,
                    "progress" to progress,
                    "stage" to stage,
                    "message" to message,
                    "timestamp" to System.currentTimeMillis()
                )
            )
        }
    }

    private fun mediaPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= 34 -> arrayOf(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
        )
        Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    private fun mediaPermissionStatus(): String {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
        ) return "granted"
        if (Build.VERSION.SDK_INT >= 34 &&
            checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
        ) return "limited"
        if (Build.VERSION.SDK_INT < 33 &&
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        ) return "granted"
        return "denied"
    }

    private fun requestMediaPermission(result: MethodChannel.Result) {
        val current = mediaPermissionStatus()
        if (current == "granted" || current == "limited") {
            result.success(current)
            return
        }
        if (pendingMediaPermissionResult != null) {
            result.error("PERMISSION_REQUEST_ACTIVE", "已有权限请求正在进行", null)
            return
        }
        pendingMediaPermissionResult = result
        requestPermissions(mediaPermissions(), MEDIA_PERMISSION_REQUEST)
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                }
            )
            result.success(true)
        } catch (error: Exception) {
            result.error("OPEN_SETTINGS_FAILED", "无法打开系统应用设置", error.safeMessage())
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != MEDIA_PERMISSION_REQUEST) return
        val result = pendingMediaPermissionResult ?: return
        pendingMediaPermissionResult = null
        val current = mediaPermissionStatus()
        if (current == "granted" || current == "limited") {
            result.success(current)
            return
        }
        val canAskAgain = permissions.any(::shouldShowRequestPermissionRationale)
        result.success(if (canAskAgain) "denied" else "blocked")
    }

    private fun networkStatus(): Map<String, Any> {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
        return mapOf(
            "connected" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true),
            "vpnActive" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true),
            "wifi" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
            "cellular" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true)
        )
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "com.gitscope.mobile/local_git"
        private const val ANALYSIS_EVENTS = "com.gitscope.mobile/analysis_events"
        private const val MEDIA_PERMISSION_REQUEST = 4107
    }
}

private fun Throwable.safeMessage(): String =
    (message ?: "设备内 Git 分析失败").replace(Regex("(?i)(bearer|token|password)[=: ]+\\S+"), "$1 [REDACTED]")
