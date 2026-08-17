import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class AccountVault {
  const AccountVault(this.storage);
  final FlutterSecureStorage storage;
  static const _accessTokenPrefix = 'github_access_token_';
  static const _refreshTokenPrefix = 'github_refresh_token_';

  Future<void> saveTokens(String accountId,
      {required String accessToken, String? refreshToken}) async {
    await storage.write(
        key: '$_accessTokenPrefix$accountId', value: accessToken);
    if (refreshToken != null) {
      await storage.write(
          key: '$_refreshTokenPrefix$accountId', value: refreshToken);
    }
  }

  Future<String?> accessToken(String accountId) =>
      storage.read(key: '$_accessTokenPrefix$accountId');
  Future<void> remove(String accountId) async {
    await storage.delete(key: '$_accessTokenPrefix$accountId');
    await storage.delete(key: '$_refreshTokenPrefix$accountId');
  }

  Future<void> clear() => storage.deleteAll();
}

class AppStore {
  static const _accountsKey = 'accounts_v2';
  static const _projectsKey = 'projects_v2';
  static const _themeKey = 'theme_v2';
  static const _apiBaseKey = 'api_base_v2';
  static const _analysisModeKey = 'analysis_mode_v3';
  static const _permissionIntroKey = 'permission_intro_v1';

  Future<List<AccountRef>> loadAccounts() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_accountsKey);
    if (raw == null) return [];
    try {
      final values = jsonDecode(raw) as List<dynamic>;
      return values
          .map((item) => AccountRef.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAccounts(List<AccountRef> accounts) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_accountsKey, encodeAccounts(accounts));
  }

  Future<List<SavedProject>> loadProjects() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_projectsKey);
    if (raw == null) return [];
    try {
      final values = jsonDecode(raw) as List<dynamic>;
      return values
          .map((item) => SavedProject.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProjects(List<SavedProject> projects) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_projectsKey, encodeProjects(projects));
  }

  Future<Map<String, dynamic>?> loadTheme() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_themeKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTheme(Map<String, dynamic> theme) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeKey, jsonEncode(theme));
  }

  Future<String> loadApiBase() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_apiBaseKey) ?? 'http://10.0.2.2:8080';
  }

  Future<void> saveApiBase(String value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_apiBaseKey, value);
  }

  Future<AnalysisMode> loadAnalysisMode() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_analysisModeKey);
    for (final mode in AnalysisMode.values) {
      if (mode.name == value) return mode;
    }
    return AnalysisMode.local;
  }

  Future<void> saveAnalysisMode(AnalysisMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_analysisModeKey, mode.name);
  }

  Future<bool> hasSeenPermissionIntro() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_permissionIntroKey) ?? false;
  }

  Future<void> markPermissionIntroSeen() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_permissionIntroKey, true);
  }

  Future<void> clearUserData() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_accountsKey);
    await preferences.remove(_projectsKey);
  }
}

class GithubAccountService {
  GithubAccountService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                baseUrl: 'https://api.github.com',
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 12)));
  final Dio _dio;

  Future<AccountRef> verifyToken(String token) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/user',
          options: Options(headers: {
            'accept': 'application/vnd.github+json',
            'authorization': 'Bearer $token',
            'x-github-api-version': '2022-11-28',
          }));
      final data = response.data!;
      return AccountRef(
          id: '${data['id']}',
          login: data['login'] as String,
          avatarUrl: data['avatar_url'] as String?,
          isDefault: false);
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        throw Exception('令牌无效或已过期');
      }
      throw Exception('无法验证 GitHub 账号，请检查网络');
    }
  }
}

class GitScopeApi {
  GitScopeApi({String baseUrl = 'http://10.0.2.2:8080', Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 20)));
  final Dio _dio;

  Future<void> health() async {
    final response = await _dio.get<Map<String, dynamic>>('/health');
    if (response.data?['status'] != 'ok') {
      throw Exception('服务健康检查返回异常');
    }
  }

  Future<AnalysisJob> createJob(String url, {String? accessToken}) async {
    final response = await _dio.post<Map<String, dynamic>>('/v1/analysis-jobs',
        data: {'url': url},
        options: Options(
            headers: accessToken == null
                ? null
                : {'Authorization': 'Bearer $accessToken'}));
    return AnalysisJob.fromJson(response.data!);
  }

  Future<AnalysisJob> waitForJob(String id,
      {void Function(AnalysisJob job)? onProgress}) async {
    for (var attempt = 0; attempt < 120; attempt++) {
      final response =
          await _dio.get<Map<String, dynamic>>('/v1/analysis-jobs/$id');
      final job = AnalysisJob.fromJson(response.data!);
      onProgress?.call(job);
      if (job.status == JobStatus.completed || job.status == JobStatus.failed) {
        return job;
      }
      await Future<void>.delayed(
          Duration(milliseconds: 750 + (attempt * 40).clamp(0, 2250)));
    }
    throw TimeoutException('仓库分析超过等待时间，请稍后重试');
  }

  Future<GraphPage> graph(String projectId, {String? cursor}) async {
    final response = await _dio.get<Map<String, dynamic>>(
        '/v1/projects/$projectId/graph',
        queryParameters: cursor == null ? null : {'cursor': cursor});
    return GraphPage.fromJson(response.data!);
  }

  Future<EngineeringReport> report(String projectId) async {
    final response =
        await _dio.get<Map<String, dynamic>>('/v1/projects/$projectId/reports');
    return EngineeringReport.fromJson(response.data!);
  }

  Future<void> deleteProject(String projectId) =>
      _dio.delete<void>('/v1/projects/$projectId');
}

typedef AnalysisProgress = void Function(double progress, String stage);

abstract interface class RepositoryAnalysisService {
  Future<void> health();
  Future<String> analyze(String url,
      {String? accessToken, AnalysisProgress? onProgress});
  Future<GraphPage> graph(String projectId, {String? cursor});
  Future<EngineeringReport> report(String projectId);
  Future<void> deleteProject(String projectId);
}

class RemoteAnalysisService implements RepositoryAnalysisService {
  RemoteAnalysisService({required this.api, LocalGitAnalysisService? local})
      : _local = local ?? LocalGitAnalysisService();
  final GitScopeApi api;
  final LocalGitAnalysisService _local;

  @override
  Future<void> health() async {
    try {
      await api.health();
    } on DioException catch (error) {
      throw Exception(await _remoteError(error));
    }
  }

  @override
  Future<String> analyze(String url,
      {String? accessToken, AnalysisProgress? onProgress}) async {
    try {
      onProgress?.call(.08, '正在连接远程分析服务');
      final created = await api.createJob(url, accessToken: accessToken);
      final job = await api.waitForJob(created.id, onProgress: (value) {
        onProgress?.call(value.progress / 100, value.stage);
      });
      if (job.status == JobStatus.failed) {
        throw Exception(job.error ?? '仓库分析失败');
      }
      return job.projectId!;
    } on DioException catch (error) {
      throw Exception(await _remoteError(error));
    }
  }

  @override
  Future<GraphPage> graph(String projectId, {String? cursor}) =>
      api.graph(projectId, cursor: cursor);
  @override
  Future<EngineeringReport> report(String projectId) => api.report(projectId);
  @override
  Future<void> deleteProject(String projectId) => api.deleteProject(projectId);

  Future<String> _remoteError(DioException error) async {
    final base = error.requestOptions.baseUrl;
    final host = Uri.tryParse(base)?.host ?? '';
    final status = await _local.networkStatus();
    if (host == '10.0.2.2') {
      return status.vpnActive
          ? 'VPN 正在接管 10.0.0.0/8，而 10.0.2.2 仅是 Android 模拟器的宿主机别名。请改用设备内分析，或关闭 VPN 后重试。'
          : '10.0.2.2 仅在 Android 模拟器中有效；真机请使用设备内分析或可访问的 HTTPS 服务。';
    }
    if (host == '127.0.0.1' || host == 'localhost') {
      return '该地址指向手机自身；只有配置 adb reverse 时才能转发到电脑上的分析服务。';
    }
    if (status.vpnActive) {
      return 'VPN 已开启且远程分析服务不可达。请允许 GitScope/局域网流量绕过 VPN，或切换到设备内分析。';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return '连接分析服务超时，请确认服务已启动、监听 0.0.0.0，且手机可以访问该地址。';
    }
    return '无法连接远程分析服务：${error.message ?? '连接失败'}';
  }
}

class NetworkStatus {
  const NetworkStatus(
      {required this.connected,
      required this.vpnActive,
      required this.wifi,
      required this.cellular});
  final bool connected;
  final bool vpnActive;
  final bool wifi;
  final bool cellular;

  factory NetworkStatus.fromMap(Map<String, dynamic> value) => NetworkStatus(
      connected: value['connected'] as bool? ?? false,
      vpnActive: value['vpnActive'] as bool? ?? false,
      wifi: value['wifi'] as bool? ?? false,
      cellular: value['cellular'] as bool? ?? false);
}

enum MediaPermissionStatus {
  granted,
  limited,
  denied,
  blocked,
  notRequired;

  bool get canSelectImages =>
      this == MediaPermissionStatus.granted ||
      this == MediaPermissionStatus.limited ||
      this == MediaPermissionStatus.notRequired;

  static MediaPermissionStatus parse(Object? value) => switch (value) {
        'granted' => MediaPermissionStatus.granted,
        'limited' => MediaPermissionStatus.limited,
        'blocked' => MediaPermissionStatus.blocked,
        'notRequired' => MediaPermissionStatus.notRequired,
        _ => MediaPermissionStatus.denied,
      };
}

class AppPermissionService {
  AppPermissionService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);
  static const channelName = 'com.gitscope.mobile/local_git';
  final MethodChannel _channel;

  Future<MediaPermissionStatus> mediaStatus() async {
    try {
      final value =
          await _channel.invokeMethod<Object?>('mediaPermissionStatus');
      return MediaPermissionStatus.parse(value);
    } on MissingPluginException {
      return MediaPermissionStatus.notRequired;
    }
  }

  Future<MediaPermissionStatus> requestMedia() async {
    try {
      final value =
          await _channel.invokeMethod<Object?>('requestMediaPermission');
      return MediaPermissionStatus.parse(value);
    } on MissingPluginException {
      return MediaPermissionStatus.notRequired;
    }
  }

  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<Object?>('openAppSettings');
    } on MissingPluginException {
      // Desktop and web builds do not expose Android application settings.
    }
  }
}

class LocalGitAnalysisService implements RepositoryAnalysisService {
  LocalGitAnalysisService(
      {MethodChannel? channel, Stream<Object?>? analysisEvents})
      : _channel = channel ?? const MethodChannel(_channelName),
        _analysisEvents = analysisEvents ??
            const EventChannel(_eventChannelName).receiveBroadcastStream();
  static const _channelName = 'com.gitscope.mobile/local_git';
  static const _eventChannelName = 'com.gitscope.mobile/analysis_events';
  final MethodChannel _channel;
  final Stream<Object?> _analysisEvents;

  Future<NetworkStatus> networkStatus() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('networkStatus');
      return NetworkStatus.fromMap(result ?? const {});
    } on MissingPluginException {
      return const NetworkStatus(
          connected: true, vpnActive: false, wifi: false, cellular: false);
    }
  }

  @override
  Future<void> health() async {
    await _channel.invokeMethod<Object?>('health');
  }

  @override
  Future<String> analyze(String url,
      {String? accessToken, AnalysisProgress? onProgress}) async {
    final sessionId = _newSessionId();
    final subscription = _listenToAnalysisEvents(sessionId, onProgress);
    onProgress?.call(.02, 'PREP · 正在启动设备内 Git 引擎');
    try {
      final result =
          await _channel.invokeMapMethod<Object?, Object?>('analyze', {
        'url': url,
        'sessionId': sessionId,
        if (accessToken != null) 'accessToken': accessToken
      });
      final projectId = result?['projectId'] as String?;
      if (projectId == null) throw Exception('设备内分析未返回项目标识');
      onProgress?.call(1, 'DONE · 设备内分析完成，临时源码已删除');
      return projectId;
    } on PlatformException catch (error) {
      final status = await networkStatus();
      final suffix = status.vpnActive && error.code == 'GIT_CONNECTION'
          ? ' 当前检测到 VPN；请为 GitScope 或仓库域名启用分流。'
          : '';
      throw Exception('${error.message ?? '设备内 Git 分析失败'}$suffix');
    } finally {
      await subscription?.cancel();
    }
  }

  Future<void> analyzeBranch(String projectId, String url, String branch,
      {String? accessToken, AnalysisProgress? onProgress}) async {
    final sessionId = _newSessionId();
    final subscription = _listenToAnalysisEvents(sessionId, onProgress);
    onProgress?.call(.02, 'PREP · 正在准备分支 $branch');
    try {
      await _channel.invokeMethod<Object?>('analyzeBranch', {
        'projectId': projectId,
        'url': url,
        'branch': branch,
        'sessionId': sessionId,
        if (accessToken != null) 'accessToken': accessToken,
      });
      onProgress?.call(1, 'DONE · 分支图谱已更新');
    } on PlatformException catch (error) {
      final status = await networkStatus();
      final suffix = status.vpnActive && error.code == 'GIT_CONNECTION'
          ? ' 当前检测到 VPN；请为 GitScope 或仓库域名启用分流。'
          : '';
      throw Exception('${error.message ?? '分支分析失败'}$suffix');
    } finally {
      await subscription?.cancel();
    }
  }

  StreamSubscription<Object?>? _listenToAnalysisEvents(
      String sessionId, AnalysisProgress? onProgress) {
    if (onProgress == null) return null;
    return _analysisEvents.listen((event) {
      try {
        final value = _normalizeMap(event);
        if (value['sessionId'] != sessionId) return;
        final progress = (value['progress'] as num?)?.toDouble();
        final stage = value['stage'] as String? ?? 'GIT';
        final message = value['message'] as String? ?? '任务状态已更新';
        onProgress(
            (progress ?? 0).clamp(0.0, 1.0).toDouble(), '$stage · $message');
      } catch (_) {
        // Ignore malformed native progress events; the analysis result remains authoritative.
      }
    }, onError: (_) {
      // Progress is optional and must never make a clone fail.
    });
  }

  String _newSessionId() =>
      'local-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  @override
  Future<GraphPage> graph(String projectId, {String? cursor}) async {
    final value = await _channel.invokeMethod<Object?>('graph', {
      'projectId': projectId,
      'cursor': int.tryParse(cursor ?? '0') ?? 0,
    });
    return GraphPage.fromJson(_normalizeMap(value));
  }

  @override
  Future<EngineeringReport> report(String projectId) async {
    final value = await _channel
        .invokeMethod<Object?>('report', {'projectId': projectId});
    return EngineeringReport.fromJson(_normalizeMap(value));
  }

  @override
  Future<void> deleteProject(String projectId) async {
    await _channel
        .invokeMethod<Object?>('deleteProject', {'projectId': projectId});
  }
}

Map<String, dynamic> _normalizeMap(Object? value) {
  final normalized = _normalizePlatformValue(value);
  if (normalized is! Map<String, dynamic>) {
    throw const FormatException('设备内分析返回了无效数据');
  }
  return normalized;
}

Object? _normalizePlatformValue(Object? value) {
  if (value is Map) {
    return value.map<String, dynamic>(
        (key, item) => MapEntry(key.toString(), _normalizePlatformValue(item)));
  }
  if (value is List) return value.map(_normalizePlatformValue).toList();
  return value;
}
