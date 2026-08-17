import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_picker/image_picker.dart';
import 'models.dart';
import 'services.dart';
import 'url_policy.dart';

void main() => runApp(const ProviderScope(child: GitScopeApp()));

final appStoreProvider = Provider((ref) => AppStore());
final apiBaseProvider = StateNotifierProvider<ApiBaseController, String>(
    (ref) => ApiBaseController(ref.read(appStoreProvider)));
final apiProvider =
    Provider((ref) => GitScopeApi(baseUrl: ref.watch(apiBaseProvider)));
final localAnalysisProvider = Provider((ref) => LocalGitAnalysisService());
final remoteAnalysisProvider = Provider((ref) => RemoteAnalysisService(
    api: ref.watch(apiProvider), local: ref.watch(localAnalysisProvider)));
final analysisModeProvider =
    StateNotifierProvider<AnalysisModeController, AnalysisMode>(
        (ref) => AnalysisModeController(ref.read(appStoreProvider)));
final analysisProvider = Provider<RepositoryAnalysisService>((ref) =>
    ref.watch(analysisModeProvider) == AnalysisMode.local
        ? ref.watch(localAnalysisProvider)
        : ref.watch(remoteAnalysisProvider));
final githubAccountProvider = Provider((ref) => GithubAccountService());
final permissionServiceProvider = Provider((ref) => AppPermissionService());
final autoFetchServiceProvider = Provider((ref) => AutoFetchService());
final vaultProvider = Provider((ref) => const AccountVault(FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true))));
final themeProvider = StateNotifierProvider<ThemeController, ThemeState>(
    (ref) => ThemeController(ref.read(appStoreProvider)));
final projectProvider =
    StateNotifierProvider<ProjectController, List<SavedProject>>(
        (ref) => ProjectController(ref.read(appStoreProvider)));
final projectGeneratedAtProvider =
    FutureProvider.family<DateTime?, String>((ref, projectId) async {
  final matching =
      ref.read(projectProvider).where((project) => project.id == projectId);
  if (matching.isEmpty || matching.first.analysisMode != AnalysisMode.local) {
    return null;
  }
  try {
    return (await ref.read(localAnalysisProvider).report(projectId))
        .generatedAt;
  } catch (_) {
    return null;
  }
});
final autoFetchHoursProvider = StateNotifierProvider<AutoFetchController, int>(
    (ref) => AutoFetchController(ref.read(appStoreProvider)));
final accountProvider =
    StateNotifierProvider<AccountController, List<AccountRef>>(
        (ref) => AccountController(ref.read(appStoreProvider)));

class ApiBaseController extends StateNotifier<String> {
  ApiBaseController(this.store) : super('http://10.0.2.2:8080') {
    _load();
  }
  final AppStore store;
  Future<void> _load() async => state = await store.loadApiBase();
  void setBase(String value) {
    state = value;
    store.saveApiBase(value);
  }
}

class AnalysisModeController extends StateNotifier<AnalysisMode> {
  AnalysisModeController(this.store) : super(AnalysisMode.local) {
    _load();
  }
  final AppStore store;
  Future<void> _load() async => state = await store.loadAnalysisMode();
  void setMode(AnalysisMode value) {
    state = value;
    store.saveAnalysisMode(value);
  }
}

class AutoFetchController extends StateNotifier<int> {
  AutoFetchController(this.store) : super(0) {
    _load();
  }
  final AppStore store;
  Future<void> _load() async => state = await store.loadAutoFetchHours();
  Future<void> setHours(int value) async {
    state = value;
    await store.saveAutoFetchHours(value);
  }
}

RepositoryAnalysisService analysisServiceFor(
        WidgetRef ref, AnalysisMode mode) =>
    mode == AnalysisMode.local
        ? ref.read(localAnalysisProvider)
        : ref.read(remoteAnalysisProvider);

String freshnessLabel(DateTime? value, {DateTime? now}) {
  if (value == null) return '尚未更新';
  final elapsed = (now ?? DateTime.now()).difference(value.toLocal());
  if (elapsed.isNegative || elapsed.inMinutes < 1) return '刚刚更新';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}分钟前';
  if (elapsed.inDays < 1) return '${elapsed.inHours}小时前';
  if (elapsed.inDays < 30) return '${elapsed.inDays}天前';
  final months = math.max(1, elapsed.inDays ~/ 30);
  return months == 1 ? '一月前' : '$months月前';
}

Future<String?> projectAccessToken(WidgetRef ref, SavedProject project) async {
  if (project.isPrivate && project.accountId == null) {
    throw Exception('该私有项目未记录安全账号引用，请重新导入后再 Fetch');
  }
  if (project.accountId == null) return null;
  final token = await ref.read(vaultProvider).accessToken(project.accountId!);
  if (token == null) throw Exception('所选账号需要重新验证，请前往账号库连接');
  return token;
}

Future<void> syncAutoFetch(WidgetRef ref, {int? intervalHours}) async {
  final int hours = intervalHours ?? ref.read(autoFetchHoursProvider);
  final configs = <Map<String, Object?>>[];
  if (hours > 0) {
    for (final project in ref.read(projectProvider)) {
      if (project.analysisMode != AnalysisMode.local) continue;
      String? accessToken;
      try {
        accessToken = await projectAccessToken(ref, project);
      } catch (_) {
        // Projects whose account was removed remain in the library, but must
        // not keep stale credentials in the native background schedule.
        continue;
      }
      configs.add({
        'id': project.id,
        'url': project.url,
        if (accessToken != null) 'accessToken': accessToken,
      });
    }
  }
  await ref
      .read(autoFetchServiceProvider)
      .configure(intervalHours: hours, projects: configs);
}

Future<void> fetchSavedProject(WidgetRef ref, SavedProject project) async {
  if (project.analysisMode != AnalysisMode.local) {
    throw Exception('现有项目的 Fetch 仅支持设备内标准模式');
  }
  final service = ref.read(localAnalysisProvider);
  final current = await service.report(project.id);
  final branch = current.currentBranch.isEmpty
      ? current.defaultBranch
      : current.currentBranch;
  await service.analyzeBranch(project.id, project.url, branch,
      accessToken: await projectAccessToken(ref, project));
  ref.read(projectProvider.notifier).markFetched(project.id, DateTime.now());
}

class ThemeState {
  const ThemeState(
      {this.mode = ThemeMode.system,
      this.accent = const Color(0xFF4ADE80),
      this.backgroundPath});
  final ThemeMode mode;
  final Color accent;
  final String? backgroundPath;
  ThemeState copyWith(
          {ThemeMode? mode,
          Color? accent,
          String? backgroundPath,
          bool clearBackground = false}) =>
      ThemeState(
          mode: mode ?? this.mode,
          accent: accent ?? this.accent,
          backgroundPath:
              clearBackground ? null : backgroundPath ?? this.backgroundPath);
}

class ThemeController extends StateNotifier<ThemeState> {
  ThemeController(this.store) : super(const ThemeState()) {
    _load();
  }
  final AppStore store;

  Future<void> _load() async {
    final saved = await store.loadTheme();
    if (saved == null) return;
    state = ThemeState(
        mode: ThemeMode.values.byName(saved['mode'] as String? ?? 'system'),
        accent: Color(saved['accent'] as int? ?? 0xFF4ADE80),
        backgroundPath: saved['backgroundPath'] as String?);
  }

  Future<void> _persist() => store.saveTheme({
        'mode': state.mode.name,
        'accent': state.accent.toARGB32(),
        'backgroundPath': state.backgroundPath,
      });

  void setMode(ThemeMode mode) {
    state = state.copyWith(mode: mode);
    _persist();
  }

  void setAccent(Color accent) {
    state = state.copyWith(accent: accent);
    _persist();
  }

  void clearBackground() {
    state = state.copyWith(clearBackground: true);
    _persist();
  }

  Future<void> setBackground(String path) async {
    final decoded = await image_lib.decodeImageFile(path);
    if (decoded == null) {
      state = state.copyWith(backgroundPath: path);
      await _persist();
      return;
    }
    var red = 0, green = 0, blue = 0, count = 0;
    final stepX = math.max(1, decoded.width ~/ 24);
    final stepY = math.max(1, decoded.height ~/ 24);
    for (var y = 0; y < decoded.height; y += stepY) {
      for (var x = 0; x < decoded.width; x += stepX) {
        final pixel = decoded.getPixel(x, y);
        red += pixel.r.toInt();
        green += pixel.g.toInt();
        blue += pixel.b.toInt();
        count++;
      }
    }
    state = state.copyWith(
        backgroundPath: path,
        accent:
            Color.fromARGB(255, red ~/ count, green ~/ count, blue ~/ count));
    await _persist();
  }
}

class ProjectController extends StateNotifier<List<SavedProject>> {
  ProjectController(this.store) : super(const []) {
    _load();
  }
  final AppStore store;
  Future<void> _load() async => state = await store.loadProjects();
  Future<void> reload() => _load();
  void add(SavedProject project) {
    state = [project, ...state.where((item) => item.id != project.id)];
    store.saveProjects(state);
  }

  void togglePin(String id) {
    state = [
      for (final item in state)
        item.id == id ? item.copyWith(pinned: !item.pinned) : item
    ];
    store.saveProjects(state);
  }

  void markFetched(String id, DateTime value) {
    state = [
      for (final item in state)
        item.id == id ? item.copyWith(lastFetchedAt: value) : item
    ];
    store.saveProjects(state);
  }

  void remove(String id) {
    state = state.where((project) => project.id != id).toList();
    store.saveProjects(state);
  }

  void clear() {
    state = [];
    store.saveProjects(state);
  }
}

class AccountController extends StateNotifier<List<AccountRef>> {
  AccountController(this.store) : super(const []) {
    _load();
  }
  final AppStore store;
  Future<void> _load() async => state = await store.loadAccounts();

  void add(AccountRef account) {
    final existingDefault = state.any((item) => item.isDefault);
    final next = account.copyWith(isDefault: !existingDefault);
    state = [next, ...state.where((item) => item.id != account.id)];
    store.saveAccounts(state);
  }

  void setDefault(String id) {
    state = [for (final item in state) item.copyWith(isDefault: item.id == id)];
    store.saveAccounts(state);
  }

  void remove(String id) {
    final remaining = state.where((item) => item.id != id).toList();
    if (remaining.isNotEmpty && !remaining.any((item) => item.isDefault)) {
      remaining[0] = remaining[0].copyWith(isDefault: true);
    }
    state = remaining;
    store.saveAccounts(state);
  }

  void clear() {
    state = [];
    store.saveAccounts(state);
  }
}

class KeyboardDismissNavigatorObserver extends NavigatorObserver {
  void _dismissKeyboard({bool repeatAfterFrame = false}) {
    FocusManager.instance.primaryFocus
        ?.unfocus(disposition: UnfocusDisposition.scope);
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (repeatAfterFrame) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        FocusManager.instance.primaryFocus
            ?.unfocus(disposition: UnfocusDisposition.scope);
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      });
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) _dismissKeyboard();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _dismissKeyboard(repeatAfterFrame: true);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _dismissKeyboard(repeatAfterFrame: true);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _dismissKeyboard(repeatAfterFrame: true);
  }
}

final router = GoRouter(observers: [
  KeyboardDismissNavigatorObserver()
], routes: [
  GoRoute(path: '/', builder: (context, state) => const MainScreen()),
  GoRoute(
      path: '/project/:id',
      builder: (context, state) =>
          ProjectScreen(projectId: state.pathParameters['id']!)),
]);

ThemeData buildGitScopeTheme(Color accent, Brightness brightness,
    {bool useGoogleFonts = true}) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: dark ? const Color(0xFF101A15) : const Color(0xFFF8FBF9));
  final colors = base.copyWith(
      surface: dark ? const Color(0xFF101A15) : const Color(0xFFFFFFFF),
      onSurface: dark ? const Color(0xFFF7FAF8) : const Color(0xFF102018),
      onSurfaceVariant:
          dark ? const Color(0xFFB7C4BC) : const Color(0xFF51685B),
      outline: dark ? const Color(0xFF819188) : const Color(0xFF687D71),
      outlineVariant: dark ? const Color(0xFF4D5F55) : const Color(0xFFC1CEC6),
      error: dark ? const Color(0xFFFF8A9B) : const Color(0xFFBA1A1A));
  final platformTextTheme = ThemeData(brightness: brightness).textTheme;
  final textTheme = (useGoogleFonts
          ? GoogleFonts.ibmPlexSansTextTheme(platformTextTheme)
          : platformTextTheme)
      .apply(bodyColor: colors.onSurface, displayColor: colors.onSurface);
  return ThemeData(
      colorScheme: colors,
      brightness: brightness,
      useMaterial3: true,
      scaffoldBackgroundColor:
          dark ? const Color(0xFF080D0B) : const Color(0xFFF2F6F3),
      textTheme: textTheme,
      cardTheme: CardThemeData(
          elevation: 0,
          color: colors.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: colors.outlineVariant))),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: dark ? const Color(0xFF0D1511) : const Color(0xFFFFFFFF),
          labelStyle: TextStyle(color: colors.onSurfaceVariant),
          hintStyle: TextStyle(color: colors.onSurfaceVariant),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(13))),
      navigationBarTheme: NavigationBarThemeData(
          height: 72,
          backgroundColor:
              dark ? const Color(0xFF0D1511) : const Color(0xFFF8FBF9),
          indicatorColor: accent.withValues(alpha: .18),
          labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              fontSize: 12,
              color: states.contains(WidgetState.selected)
                  ? colors.primary
                  : colors.onSurfaceVariant))));
}

class GitScopeApp extends ConsumerWidget {
  const GitScopeApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    return MaterialApp.router(
        debugShowCheckedModeBanner: false,
        title: 'GitScope',
        theme: buildGitScopeTheme(theme.accent, Brightness.light),
        darkTheme: buildGitScopeTheme(theme.accent, Brightness.dark),
        themeMode: theme.mode,
        routerConfig: router);
  }
}

class BackgroundScaffold extends ConsumerWidget {
  const BackgroundScaffold(
      {super.key, required this.body, this.bottomNavigationBar, this.appBar});
  final Widget body;
  final Widget? bottomNavigationBar;
  final PreferredSizeWidget? appBar;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = ref.watch(themeProvider).backgroundPath;
    return Scaffold(
        appBar: appBar,
        body: Stack(fit: StackFit.expand, children: [
          if (path != null)
            Image.file(File(path),
                fit: BoxFit.cover,
                color: Colors.black.withValues(alpha: .54),
                colorBlendMode: BlendMode.darken,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          DecoratedBox(
              decoration: BoxDecoration(
                  gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                    Theme.of(context)
                        .scaffoldBackgroundColor
                        .withValues(alpha: path == null ? 1 : .92),
                    Theme.of(context).scaffoldBackgroundColor
                  ])),
              child: SafeArea(top: appBar == null, child: body)),
        ]),
        bottomNavigationBar: bottomNavigationBar);
  }
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});
  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  var index = 0;
  final pages = const [
    ImportPage(),
    ProjectsPage(),
    AccountsPage(),
    SettingsPage()
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _requestInitialPermissions());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(projectProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _requestInitialPermissions() async {
    if (!Platform.isAndroid) return;
    final store = ref.read(appStoreProvider);
    if (await store.hasSeenPermissionIntro() || !mounted) return;
    final service = ref.read(permissionServiceProvider);
    final current = await service.mediaStatus();
    if (!mounted) return;
    if (current.canSelectImages) {
      await store.markPermissionIntroSeen();
      return;
    }
    final shouldRequest = await showDialog<bool>(
        context: context, builder: (context) => const PermissionIntroDialog());
    await store.markPermissionIntroSeen();
    if (shouldRequest == true && mounted) {
      await ensureMediaPermission(context, service);
    }
  }

  @override
  Widget build(BuildContext context) => BackgroundScaffold(
        body: IndexedStack(index: index, children: pages),
        bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (value) => setState(() => index = value),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '导入'),
              NavigationDestination(
                  icon: Icon(Icons.history_outlined),
                  selectedIcon: Icon(Icons.history),
                  label: '项目'),
              NavigationDestination(
                  icon: Icon(Icons.account_circle_outlined),
                  selectedIcon: Icon(Icons.account_circle),
                  label: '账号库'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置'),
            ]),
      );
}

class PermissionIntroDialog extends StatelessWidget {
  const PermissionIntroDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.folder_open_outlined, size: 32),
        title: const Text('配置应用权限'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('GitScope 只申请功能所需的最小权限。'),
            SizedBox(height: 16),
            _PermissionFact(
                icon: Icons.image_outlined,
                title: '照片与媒体',
                detail: '用于选择自定义背景，可在系统中限制为部分照片。'),
            _PermissionFact(
                icon: Icons.storage_outlined,
                title: '项目存储',
                detail: '分析结果保存在应用私有目录，无需访问全部文件。'),
            _PermissionFact(
                icon: Icons.language,
                title: '网络访问',
                detail: '用于连接 Git 仓库，由 Android 安装时自动启用。'),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续授权')),
        ],
      );
}

class _PermissionFact extends StatelessWidget {
  const _PermissionFact(
      {required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon,
                  size: 20, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(detail,
                    style: TextStyle(
                        height: 1.4,
                        color: Theme.of(context).colorScheme.onSurfaceVariant))
              ]))
        ]),
      );
}

Future<bool> ensureMediaPermission(
    BuildContext context, AppPermissionService service) async {
  try {
    var status = await service.mediaStatus();
    if (status.canSelectImages) return true;
    status = await service.requestMedia();
    if (status.canSelectImages) return true;
    if (!context.mounted) return false;
    final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              icon: const Icon(Icons.photo_library_outlined),
              title: const Text('照片权限未开启'),
              content: Text(status == MediaPermissionStatus.blocked
                  ? '系统已停止再次询问。请在应用设置中允许照片访问，或选择“部分照片”。'
                  : '没有此权限仍可分析仓库，但无法添加自定义背景。你可以重试或前往系统设置。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, 'later'),
                    child: const Text('稍后')),
                if (status != MediaPermissionStatus.blocked)
                  TextButton(
                      onPressed: () => Navigator.pop(context, 'retry'),
                      child: const Text('重试')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, 'settings'),
                    child: const Text('系统设置')),
              ],
            ));
    if (action == 'settings') {
      await service.openSettings();
    } else if (action == 'retry') {
      status = await service.requestMedia();
      return status.canSelectImages;
    }
  } on PlatformException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message ?? '无法申请照片权限，请前往系统设置检查。')));
    }
  }
  return false;
}

class PermissionSheet extends ConsumerStatefulWidget {
  const PermissionSheet({super.key});

  @override
  ConsumerState<PermissionSheet> createState() => _PermissionSheetState();
}

class _PermissionSheetState extends ConsumerState<PermissionSheet> {
  MediaPermissionStatus? status;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final value = await ref.read(permissionServiceProvider).mediaStatus();
    if (mounted) setState(() => status = value);
  }

  Future<void> _request() async {
    setState(() => loading = true);
    await ensureMediaPermission(context, ref.read(permissionServiceProvider));
    if (mounted) {
      setState(() => loading = false);
      await _refresh();
    }
  }

  String get statusLabel => switch (status) {
        MediaPermissionStatus.granted => '已允许',
        MediaPermissionStatus.limited => '部分照片',
        MediaPermissionStatus.blocked => '需在系统设置开启',
        MediaPermissionStatus.notRequired => '无需授权',
        MediaPermissionStatus.denied => '未允许',
        null => '正在检查',
      };

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('应用权限',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('只显示 GitScope 实际使用的权限。',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 16),
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.image_outlined),
                    title: const Text('照片与媒体'),
                    subtitle: const Text('选择自定义背景'),
                    trailing: Text(statusLabel)),
                const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.storage_outlined),
                    title: Text('项目存储'),
                    subtitle: Text('应用私有目录，不读取其他文件'),
                    trailing: Text('无需授权')),
                const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.language),
                    title: Text('网络访问'),
                    subtitle: Text('连接 GitHub、GitLab 与其他 Git 服务'),
                    trailing: Text('已启用')),
                const SizedBox(height: 12),
                FilledButton.icon(
                    onPressed: loading ? null : _request,
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                    icon: loading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.admin_panel_settings_outlined),
                    label: Text(status?.canSelectImages == true
                        ? '检查或调整权限'
                        : '申请照片权限')),
                TextButton(
                    onPressed: () async {
                      await ref.read(permissionServiceProvider).openSettings();
                    },
                    child: const Text('打开系统应用设置'))
              ]),
        ),
      );
}

class PageContent extends StatelessWidget {
  const PageContent({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => CustomScrollView(slivers: [
        SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            sliver: SliverList.list(children: children))
      ]);
}

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
            width: 16, height: 1, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 7),
        Text(text,
            style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.primary))
      ]);
}

class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});
  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  final controller = TextEditingController();
  final List<String> analysisLogs = [];
  String selectedAccountId = 'public';
  var loading = false;
  String? error;
  double progress = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void updateAnalysisProgress(double value, String message) {
    if (!mounted) return;
    final now = DateTime.now();
    final timestamp = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      progress = math.max(progress, value.clamp(0.0, 1.0).toDouble());
      final line = '$timestamp  $message';
      if (analysisLogs.isEmpty || analysisLogs.last != line) {
        analysisLogs.add(line);
        if (analysisLogs.length > 80) analysisLogs.removeAt(0);
      }
    });
  }

  Future<void> analyze() async {
    late final Uri uri;
    try {
      uri = validateRepositoryUrl(controller.text);
    } on RepositoryUrlException catch (exception) {
      setState(() => error = exception.message);
      return;
    }
    setState(() {
      loading = true;
      error = null;
      progress = .08;
      analysisLogs
        ..clear()
        ..add('—  PREP · 已创建临时分析任务');
    });
    try {
      String? accessToken;
      if (selectedAccountId != 'public') {
        if (uri.host.toLowerCase() != 'github.com') {
          throw Exception('GitHub 账号令牌只能用于 github.com；其他平台目前仅支持公开仓库');
        }
        accessToken =
            await ref.read(vaultProvider).accessToken(selectedAccountId);
        if (accessToken == null) {
          throw Exception('所选账号需要重新验证，请前往账号库连接');
        }
      }
      final mode = ref.read(analysisModeProvider);
      final projectId = await ref.read(analysisProvider).analyze(uri.toString(),
          accessToken: accessToken, onProgress: updateAnalysisProgress);
      final project = SavedProject(
          id: projectId,
          owner: uri.pathSegments[uri.pathSegments.length - 2],
          name: uri.pathSegments.last.replaceAll('.git', ''),
          url: uri.toString(),
          provider: uri.host.contains('github')
              ? GitProvider.github
              : uri.host.contains('gitlab')
                  ? GitProvider.gitlab
                  : uri.host.contains('bitbucket')
                      ? GitProvider.bitbucket
                      : GitProvider.generic,
          analysisMode: mode,
          accountId: selectedAccountId == 'public' ? null : selectedAccountId,
          isPrivate: selectedAccountId != 'public',
          lastFetchedAt: DateTime.now());
      ref.read(projectProvider.notifier).add(project);
      if (ref.read(autoFetchHoursProvider) > 0) {
        await syncAutoFetch(ref);
      }
      if (mounted) context.push('/project/${project.id}');
    } catch (exception) {
      if (mounted) {
        setState(
            () => error = exception.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          progress = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final recent = ref.watch(projectProvider).take(2).toList();
    final accounts = ref.watch(accountProvider);
    final analysisMode = ref.watch(analysisModeProvider);
    if (selectedAccountId != 'public' &&
        !accounts.any((account) => account.id == selectedAccountId)) {
      selectedAccountId = 'public';
    }
    return PageContent(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('仓库工作台',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
              '${ref.watch(projectProvider).length} 个项目 · ${accounts.length} 个账号',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))
        ])),
        Chip(
            avatar: Icon(
                analysisMode == AnalysisMode.local
                    ? Icons.memory
                    : Icons.cloud_done_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.primary),
            label: Text(analysisMode == AnalysisMode.local ? '设备内' : '远程 API'),
            labelStyle: const TextStyle(fontSize: 12))
      ]),
      const SizedBox(height: 18),
      AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.add_link,
              size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 9),
          Text('导入仓库',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          const Icon(Icons.lock_outline, size: 16),
          const SizedBox(width: 4),
          const Text('只读分析', style: TextStyle(fontSize: 12))
        ]),
        const SizedBox(height: 22),
        const Text('Git 仓库链接',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
        const SizedBox(height: 7),
        TextField(
            controller: controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.link),
                suffixIcon: const Icon(Icons.code),
                border: const OutlineInputBorder(),
                errorText: error)),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
            key: ValueKey(selectedAccountId),
            initialValue: selectedAccountId,
            decoration: const InputDecoration(
                labelText: '分析账号',
                prefixIcon: Icon(Icons.account_circle_outlined),
                border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem(
                  value: 'public', child: Text('公开仓库 · 不使用账号')),
              ...accounts.map((account) => DropdownMenuItem(
                  value: account.id,
                  child: Text(
                      '${account.login}${account.isDefault ? ' · 默认' : ''}')))
            ],
            onChanged: loading
                ? null
                : (value) =>
                    setState(() => selectedAccountId = value ?? 'public')),
        if (loading || (error != null && analysisLogs.isNotEmpty)) ...[
          const SizedBox(height: 16),
          if (loading) LinearProgressIndicator(value: progress),
          const SizedBox(height: 10),
          TemporaryCloneLogPanel(lines: analysisLogs, taskRunning: loading)
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: loading ? null : analyze,
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: loading
                ? const SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(analysisMode == AnalysisMode.local
                    ? Icons.memory
                    : Icons.cloud_download_outlined),
            label: Text(loading ? '正在分析仓库' : '导入并分析')),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.lock_outline, size: 17),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  analysisMode == AnalysisMode.local
                      ? 'Git 历史在本机临时目录分析；完成后删除源码，仅保留聚合结果。'
                      : '仓库由已配置的远程 API 分析；完成后删除临时源码。',
                  style: const TextStyle(fontSize: 12, height: 1.5)))
        ])
      ])),
      const SizedBox(height: 28),
      Text('最近分析',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      if (recent.isEmpty)
        const AppEmptyState(
            icon: Icons.account_tree_outlined,
            title: '尚无项目',
            message: '完成第一次仓库分析后会显示在这里。')
      else
        ...recent.map((project) => ProjectTile(project: project)),
    ]);
  }
}

class TemporaryCloneLogPanel extends StatelessWidget {
  const TemporaryCloneLogPanel(
      {super.key, required this.lines, required this.taskRunning});

  final List<String> lines;
  final bool taskRunning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visibleLines = lines.isEmpty ? const ['—  等待 Git 引擎输出'] : lines;
    return Semantics(
        liveRegion: true,
        label: visibleLines.last,
        child: Container(
            height: 164,
            decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: .72),
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 9, 8),
                  child: Row(children: [
                    Icon(Icons.terminal, size: 16, color: colors.primary),
                    const SizedBox(width: 7),
                    Text('实时克隆日志',
                        style: GoogleFonts.jetBrainsMono(
                            fontSize: 11, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                            color: taskRunning
                                ? colors.primaryContainer
                                : colors.errorContainer,
                            borderRadius: BorderRadius.circular(999)),
                        child: Text(taskRunning ? '任务中 · 临时' : '失败 · 已保留',
                            style: TextStyle(
                                fontSize: 10,
                                color: taskRunning
                                    ? colors.onPrimaryContainer
                                    : colors.onErrorContainer)))
                  ])),
              Divider(height: 1, color: colors.outlineVariant),
              Expanded(
                  child: ListView.builder(
                      key: const ValueKey('temporary-clone-log-list'),
                      reverse: true,
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                      itemCount: visibleLines.length,
                      itemBuilder: (context, index) {
                        final line =
                            visibleLines[visibleLines.length - 1 - index];
                        return Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(line,
                                style: GoogleFonts.jetBrainsMono(
                                    fontSize: 10.5,
                                    height: 1.35,
                                    color: colors.onSurfaceVariant)));
                      }))
            ])));
  }
}

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface.withValues(alpha: .98),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side:
              BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      child: Padding(padding: const EdgeInsets.all(17), child: child));
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState(
      {super.key,
      required this.icon,
      required this.title,
      required this.message,
      this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => AppCard(
      child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(children: [
            CircleAvatar(radius: 26, child: Icon(icon, size: 27)),
            const SizedBox(height: 12),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    height: 1.55,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 16), action!]
          ])));
}

class ProjectTile extends ConsumerWidget {
  const ProjectTile({super.key, required this.project});
  final SavedProject project;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportTime = project.lastFetchedAt == null
        ? ref
            .watch(projectGeneratedAtProvider(project.id))
            .whenOrNull(data: (value) => value)
        : null;
    return Card(
        elevation: 0,
        child: ListTile(
            minTileHeight: 76,
            leading: const CircleAvatar(child: Icon(Icons.code)),
            title: Text('${project.owner} / ${project.name}', maxLines: 2),
            subtitle: Text(
                '${project.isPrivate ? '私有仓库' : '公开仓库'} · ${freshnessLabel(project.lastFetchedAt ?? reportTime)}'),
            trailing: PopupMenuButton<String>(
                tooltip: '项目操作',
                onSelected: (action) async {
                  if (action == 'pin') {
                    ref.read(projectProvider.notifier).togglePin(project.id);
                  } else if (action == 'fetch') {
                    try {
                      await fetchSavedProject(ref, project);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Fetch 完成，项目数据已更新')));
                      }
                    } catch (exception) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(exception
                                .toString()
                                .replaceFirst('Exception: ', ''))));
                      }
                    }
                  } else if (action == 'delete') {
                    ref.read(projectProvider.notifier).remove(project.id);
                    await analysisServiceFor(ref, project.analysisMode)
                        .deleteProject(project.id)
                        .catchError((_) {});
                    await syncAutoFetch(ref).catchError((_) {});
                  }
                },
                itemBuilder: (context) => [
                      PopupMenuItem(
                          value: 'pin',
                          child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(project.pinned
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined),
                              title: Text(project.pinned ? '取消置顶' : '置顶'))),
                      const PopupMenuItem(
                          value: 'fetch',
                          child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.sync),
                              title: Text('Fetch 更新'))),
                      const PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.delete_outline),
                              title: Text('删除项目历史')))
                    ]),
            onTap: () => context.push('/project/${project.id}')));
  }
}

class ProjectsPage extends ConsumerStatefulWidget {
  const ProjectsPage({super.key});
  @override
  ConsumerState<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends ConsumerState<ProjectsPage> {
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final projects = [
      ...ref.watch(projectProvider).where((project) =>
          '${project.owner}/${project.name}'.toLowerCase().contains(query))
    ]..sort((a, b) => b.pinned.toString().compareTo(a.pinned.toString()));
    return PageContent(children: [
      const Eyebrow('PROJECT LIBRARY'),
      const SizedBox(height: 12),
      Text('项目库',
          style: Theme.of(context)
              .textTheme
              .displaySmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('快速回到最近查询和收藏的仓库。',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 22),
      TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索所有者或仓库',
              border: OutlineInputBorder())),
      const SizedBox(height: 12),
      if (projects.isEmpty)
        AppEmptyState(
            icon: Icons.folder_open_outlined,
            title: ref.watch(projectProvider).isEmpty ? '项目库为空' : '没有匹配项目',
            message: ref.watch(projectProvider).isEmpty
                ? '从导入页分析仓库后，项目会保存在此设备。'
                : '请尝试其他搜索词。')
      else
        ...projects.map((project) => ProjectTile(project: project))
    ]);
  }
}

class AccountsPage extends ConsumerWidget {
  const AccountsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountProvider);
    void openConnect() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => const AccountConnectSheet());
    return PageContent(children: [
      const Eyebrow('SECURE ACCOUNT VAULT'),
      const SizedBox(height: 12),
      Text('账号库',
          style: Theme.of(context)
              .textTheme
              .displaySmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('授权信息保存在 Android Keystore，应用不会保存 GitHub 密码。',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 22),
      if (accounts.isEmpty)
        AppEmptyState(
            icon: Icons.account_circle_outlined,
            title: '尚未连接账号',
            message: '公开仓库无需账号；私有仓库需要验证 GitHub 访问令牌。',
            action: FilledButton.icon(
                onPressed: openConnect,
                icon: const Icon(Icons.add),
                label: const Text('连接 GitHub 账号')))
      else
        ...accounts.map((account) => Card(
            child: ListTile(
                minTileHeight: 76,
                leading: CircleAvatar(
                    child: Text(account.login.substring(0, 2).toUpperCase())),
                title: Text(account.login),
                subtitle: const Text('GitHub · 只读访问'),
                trailing: PopupMenuButton<String>(
                    tooltip: '${account.login} 账号操作',
                    onSelected: (action) async {
                      if (action == 'default') {
                        ref
                            .read(accountProvider.notifier)
                            .setDefault(account.id);
                      } else if (action == 'remove') {
                        await ref.read(vaultProvider).remove(account.id);
                        ref.read(accountProvider.notifier).remove(account.id);
                        if (ref.read(autoFetchHoursProvider) > 0) {
                          await syncAutoFetch(ref).catchError((_) {});
                        }
                      }
                    },
                    itemBuilder: (context) => [
                          if (!account.isDefault)
                            const PopupMenuItem(
                                value: 'default', child: Text('设为默认账号')),
                          const PopupMenuItem(
                              value: 'remove', child: Text('从设备移除'))
                        ]),
                leadingAndTrailingTextStyle: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)))),
      const SizedBox(height: 12),
      OutlinedButton.icon(
          onPressed: openConnect,
          style:
              OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.add),
          label: Text(accounts.isEmpty ? '连接 GitHub 账号' : '连接另一个 GitHub 账号'))
    ]);
  }
}

class AccountConnectSheet extends ConsumerStatefulWidget {
  const AccountConnectSheet({super.key});
  @override
  ConsumerState<AccountConnectSheet> createState() =>
      _AccountConnectSheetState();
}

class _AccountConnectSheetState extends ConsumerState<AccountConnectSheet> {
  final token = TextEditingController();
  bool loading = false;
  String? error;

  @override
  void dispose() {
    token.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    final value = token.text.trim();
    final supportedPrefix =
        value.startsWith('github_pat_') || value.startsWith('ghp_');
    if (value.length < 20 ||
        !supportedPrefix ||
        value.contains(RegExp(r'\s'))) {
      setState(() => error = '请输入有效的 GitHub fine-grained 或 classic token');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final account = await ref.read(githubAccountProvider).verifyToken(value);
      await ref.read(vaultProvider).saveTokens(account.id, accessToken: value);
      ref.read(accountProvider.notifier).add(account);
      if (ref.read(autoFetchHoursProvider) > 0) {
        await syncAutoFetch(ref).catchError((_) {});
      }
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (mounted) {
        setState(
            () => error = exception.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('安全连接 GitHub',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                    '支持 fine-grained PAT 和 classic PAT。令牌会先通过 GitHub API 验证，再写入 Android Keystore。'),
                const SizedBox(height: 16),
                TextField(
                    controller: token,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                        labelText: 'GitHub 访问令牌',
                        hintText: 'github_pat_… 或 ghp_…',
                        helperText: 'classic token 访问私有仓库需要 repo 权限',
                        errorText: error,
                        prefixIcon: const Icon(Icons.key_outlined))),
                const SizedBox(height: 20),
                FilledButton.icon(
                    onPressed: loading ? null : connect,
                    icon: loading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.verified_user_outlined),
                    label: Text(loading ? '正在验证账号' : '验证并安全保存'))
              ])));
}

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(themeProvider);
    final apiBase = ref.watch(apiBaseProvider);
    final analysisMode = ref.watch(analysisModeProvider);
    final autoFetchHours = ref.watch(autoFetchHoursProvider);
    return PageContent(children: [
      const Eyebrow('PREFERENCES'),
      const SizedBox(height: 12),
      Text('设置',
          style: Theme.of(context)
              .textTheme
              .displaySmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('控制主题、隐私、缓存与分析偏好。',
          style:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 22),
      Card(
          child: ListTile(
              minTileHeight: 76,
              leading: const Icon(Icons.palette_outlined),
              title: const Text('外观与背景'),
              subtitle: Text(
                  '${state.mode.name} · ${state.backgroundPath == null ? '动态渐变' : '自定义图片'}'),
              trailing: CircleAvatar(radius: 11, backgroundColor: state.accent),
              onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (context) => const ThemeSheet()))),
      Card(
          child: ListTile(
              minTileHeight: 76,
              leading: const Icon(Icons.dns_outlined),
              title: const Text('分析服务'),
              subtitle: Text(
                  analysisMode == AnalysisMode.local
                      ? '设备内标准模式 · JGit 6.4 无 Blob 浅克隆'
                      : apiBase,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (context) => const ApiServerSheet()))),
      Card(
          child: ListTile(
              minTileHeight: 76,
              leading: const Icon(Icons.schedule_send_outlined),
              title: const Text('自动 Fetch'),
              subtitle: Text(autoFetchHours == 0
                  ? '已关闭'
                  : '约每 ${autoFetchHours == 24 ? '天' : autoFetchHours == 168 ? '周' : '$autoFetchHours 小时'}自动更新'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (context) => const AutoFetchSheet()))),
      Card(
          child: ListTile(
              minTileHeight: 76,
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('应用权限'),
              subtitle: const Text('照片访问、网络与私有存储'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (context) => const PermissionSheet()))),
      Card(
          child: ListTile(
              minTileHeight: 76,
              leading: const Icon(Icons.lock_outline),
              title: const Text('隐私与数据'),
              subtitle: const Text('查看存储策略 · 清除本地用户数据'),
              onTap: () async {
                final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                            title: const Text('清除本地用户数据？'),
                            content: const Text(
                                '将移除账号元数据、Keystore 令牌与项目历史，不会删除远程 Git 仓库。'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('确认清除'))
                            ]));
                if (confirmed != true) return;
                for (final project in ref.read(projectProvider)) {
                  await analysisServiceFor(ref, project.analysisMode)
                      .deleteProject(project.id)
                      .catchError((_) {});
                }
                await ref.read(vaultProvider).clear();
                await ref.read(appStoreProvider).clearUserData();
                ref.read(accountProvider.notifier).clear();
                ref.read(projectProvider.notifier).clear();
                await ref.read(autoFetchHoursProvider.notifier).setHours(0);
                await syncAutoFetch(ref, intervalHours: 0).catchError((_) {});
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('本地用户数据已清除')));
                }
              })),
      Card(
          child: ListTile(
              minTileHeight: 76,
              leading: const Icon(Icons.tune),
              title: const Text('分析限制'),
              subtitle: const Text('每分支历史深度 500 · 1 GB 临时空间'),
              onTap: () => showModalBottomSheet<void>(
                  context: context,
                  showDragHandle: true,
                  builder: (context) => const SafeArea(
                      child: Padding(
                          padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('分析限制',
                                    style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700)),
                                SizedBox(height: 12),
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('最长任务'),
                                    trailing: Text('5 分钟')),
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('单分支浅克隆深度'),
                                    trailing: Text('500')),
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('图谱分页'),
                                    trailing: Text('每页 300')),
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text('临时空间'),
                                    trailing: Text('1 GB'))
                              ])))))),
      const SizedBox(height: 28),
      Center(
          child: Text('GitScope 0.7.0',
              style: GoogleFonts.jetBrainsMono(fontSize: 11)))
    ]);
  }
}

class AutoFetchSheet extends ConsumerStatefulWidget {
  const AutoFetchSheet({super.key});

  @override
  ConsumerState<AutoFetchSheet> createState() => _AutoFetchSheetState();
}

class _AutoFetchSheetState extends ConsumerState<AutoFetchSheet> {
  late int selected = ref.read(autoFetchHoursProvider);
  bool saving = false;
  String? error;

  static const options = <(int, String, String)>[
    (0, '关闭自动 Fetch', '仅在手动点击 Fetch 时更新'),
    (1, '每小时', '适合活跃开发仓库'),
    (6, '每 6 小时', '平衡时效与电量'),
    (24, '每天', '适合一般项目'),
    (168, '每周', '适合归档或低频项目'),
  ];

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await ref.read(autoFetchHoursProvider.notifier).setHours(selected);
      await syncAutoFetch(ref, intervalHours: selected);
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (mounted) {
        setState(() {
          saving = false;
          error = exception.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('自动 Fetch',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('Android 会在联网且电量允许时批量更新设备内项目。执行时间由系统调度，可能晚于设定周期。',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                RadioGroup<int>(
                    groupValue: selected,
                    onChanged: saving
                        ? (_) {}
                        : (value) => setState(() => selected = value ?? 0),
                    child: Column(
                        children: options
                            .map((option) => RadioListTile<int>(
                                key: ValueKey('auto-fetch-${option.$1}'),
                                contentPadding: EdgeInsets.zero,
                                value: option.$1,
                                title: Text(option.$2),
                                subtitle: Text(option.$3)))
                            .toList())),
                const SizedBox(height: 4),
                Text('HarmonyOS 可能因电池优化延后后台任务；如需更及时，请允许 GitScope 后台活动。',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error))
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                    onPressed: saving ? null : save,
                    icon: saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.schedule),
                    label: const Text('保存自动任务'))
              ])));
}

class ApiServerSheet extends ConsumerStatefulWidget {
  const ApiServerSheet({super.key});
  @override
  ConsumerState<ApiServerSheet> createState() => _ApiServerSheetState();
}

class _ApiServerSheetState extends ConsumerState<ApiServerSheet> {
  late final TextEditingController controller;
  bool loading = false;
  String? error;
  late AnalysisMode selectedMode;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: ref.read(apiBaseProvider));
    selectedMode = ref.read(analysisModeProvider);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (selectedMode == AnalysisMode.local) {
      ref.read(analysisModeProvider.notifier).setMode(AnalysisMode.local);
      if (mounted) Navigator.pop(context);
      return;
    }
    final value = controller.text.trim().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => error = '请输入完整的 HTTP 或 HTTPS 服务地址');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await RemoteAnalysisService(
              api: GitScopeApi(baseUrl: value),
              local: ref.read(localAnalysisProvider))
          .health();
      ref.read(apiBaseProvider.notifier).setBase(value);
      ref.read(analysisModeProvider.notifier).setMode(AnalysisMode.remote);
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (mounted) {
        setState(
            () => error = exception.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('分析服务',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                    '标准模式使用 JGit 6.4 浅克隆：首次加载默认分支 500 层历史；切换分支时仅按需下载该分支，完成后删除临时仓库。'),
                const SizedBox(height: 16),
                SegmentedButton<AnalysisMode>(
                    segments: const [
                      ButtonSegment(
                          value: AnalysisMode.local,
                          icon: Icon(Icons.memory),
                          label: Text('标准模式')),
                      ButtonSegment(
                          value: AnalysisMode.remote,
                          icon: Icon(Icons.cloud_outlined),
                          label: Text('远程 API'))
                    ],
                    selected: {
                      selectedMode
                    },
                    onSelectionChanged: loading
                        ? null
                        : (value) => setState(() {
                              selectedMode = value.first;
                              error = null;
                            })),
                const SizedBox(height: 14),
                if (selectedMode == AnalysisMode.local)
                  FutureBuilder<NetworkStatus>(
                      future: ref.read(localAnalysisProvider).networkStatus(),
                      builder: (context, snapshot) {
                        final status = snapshot.data;
                        return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.security_outlined),
                            title: const Text('本机分析引擎已内置'),
                            subtitle: Text(status?.vpnActive == true
                                ? '检测到 VPN；无需连接分析服务器，但仓库域名仍需允许访问。'
                                : '不经过 10.0.2.2 或局域网分析服务器。'));
                      })
                else
                  TextField(
                      controller: controller,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: InputDecoration(
                          labelText: '远程服务地址',
                          hintText: 'https://git-api.example.com',
                          errorText: error,
                          prefixIcon: const Icon(Icons.link))),
                if (selectedMode == AnalysisMode.remote) ...[
                  const SizedBox(height: 8),
                  const Text(
                      '10.0.2.2 只适用于模拟器；VPN 可能接管该私网路由。真机建议使用 HTTPS，或通过 adb reverse 使用 127.0.0.1。',
                      style: TextStyle(fontSize: 12, height: 1.45))
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                    onPressed: loading ? null : save,
                    icon: loading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(selectedMode == AnalysisMode.local
                            ? Icons.check
                            : Icons.wifi_tethering),
                    label: Text(loading
                        ? '正在测试连接'
                        : selectedMode == AnalysisMode.local
                            ? '使用标准模式'
                            : '测试并保存'))
              ])));
}

class ThemeSheet extends ConsumerWidget {
  const ThemeSheet({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(themeProvider);
    final controller = ref.read(themeProvider.notifier);
    return SafeArea(
        child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('主题与背景',
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 18),
                  SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                            value: ThemeMode.system,
                            icon: Icon(Icons.brightness_auto),
                            label: Text('自动')),
                        ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode),
                            label: Text('深色')),
                        ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode),
                            label: Text('浅色'))
                      ],
                      selected: {
                        state.mode
                      },
                      onSelectionChanged: (value) =>
                          controller.setMode(value.first)),
                  const SizedBox(height: 20),
                  const Text('强调色',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                      spacing: 10,
                      children: [
                        const Color(0xFF4ADE80),
                        const Color(0xFF38BDF8),
                        const Color(0xFFA78BFA),
                        const Color(0xFFFB7185),
                        const Color(0xFFFBBF24)
                      ]
                          .map((color) => InkWell(
                              borderRadius: BorderRadius.circular(24),
                              onTap: () => controller.setAccent(color),
                              child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: state.accent == color
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                              : Colors.transparent,
                                          width: 3)),
                                  child: state.accent == color
                                      ? const Icon(Icons.check,
                                          color: Colors.black)
                                      : null)))
                          .toList()),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                      onPressed: () async {
                        final allowed = await ensureMediaPermission(
                            context, ref.read(permissionServiceProvider));
                        if (!allowed || !context.mounted) return;
                        final picked = await ImagePicker().pickImage(
                            source: ImageSource.gallery, maxWidth: 1800);
                        if (picked != null) {
                          await controller.setBackground(picked.path);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('选择背景并自动取色')),
                  TextButton(
                      onPressed: controller.clearBackground,
                      child: const Text('清除背景'))
                ])));
  }
}

class ProjectScreen extends ConsumerStatefulWidget {
  const ProjectScreen({super.key, required this.projectId});
  final String projectId;
  @override
  ConsumerState<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends ConsumerState<ProjectScreen>
    with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 3, vsync: this);
  List<CommitNode> commits = [];
  EngineeringReport? report;
  bool loading = true;
  bool switchingBranch = false;
  String? error;

  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  Future<void> load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final project = ref
          .read(projectProvider)
          .firstWhere((item) => item.id == widget.projectId);
      final service = analysisServiceFor(ref, project.analysisMode);
      final results = await Future.wait(
          [service.graph(widget.projectId), service.report(widget.projectId)]);
      if (!mounted) return;
      setState(() {
        commits = (results[0] as GraphPage).commits;
        report = results[1] as EngineeringReport;
      });
    } catch (exception) {
      if (mounted) {
        setState(() => error = exception
            .toString()
            .replaceFirst('DioException [bad response]: ', ''));
      }
    } finally {
      if (mounted && showLoading) setState(() => loading = false);
    }
  }

  Future<void> selectBranch(SavedProject project, String branch) async {
    if (switchingBranch || branch == report?.currentBranch) return;
    if (project.analysisMode != AnalysisMode.local) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('远程 API 暂不支持按需分支图谱，请使用设备内标准模式。')));
      return;
    }
    setState(() => switchingBranch = true);
    try {
      String? accessToken;
      if (project.isPrivate && project.accountId == null) {
        throw Exception('该项目由旧版本导入，未记录安全账号引用。请删除后重新导入以切换私有分支');
      }
      if (project.accountId != null) {
        accessToken =
            await ref.read(vaultProvider).accessToken(project.accountId!);
        if (accessToken == null) {
          throw Exception('所选账号需要重新验证，请前往账号库连接');
        }
      }
      await ref.read(localAnalysisProvider).analyzeBranch(
          project.id, project.url, branch,
          accessToken: accessToken);
      await load(showLoading: false);
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(exception.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => switchingBranch = false);
    }
  }

  Future<void> fetchProject(SavedProject project) async {
    if (switchingBranch) return;
    setState(() => switchingBranch = true);
    try {
      await fetchSavedProject(ref, project);
      await load(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Fetch 完成，已重新生成当前图谱与报表')));
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(exception.toString().replaceFirst('Exception: ', ''))));
      }
    } finally {
      if (mounted) setState(() => switchingBranch = false);
    }
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectProvider);
    final matching = projects.where((item) => item.id == widget.projectId);
    if (matching.isEmpty) {
      return Scaffold(
          appBar: AppBar(title: const Text('项目不可用')),
          body: const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('项目历史不存在或仍在加载，请返回项目库后重试。'))));
    }
    final project = matching.first;
    return BackgroundScaffold(
        appBar: AppBar(
            title:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(project.owner, style: const TextStyle(fontSize: 12)),
              Text(project.name,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700))
            ]),
            actions: [
              IconButton(
                  tooltip: 'Fetch 远程更新',
                  onPressed: loading || switchingBranch
                      ? null
                      : () => fetchProject(project),
                  icon: switchingBranch
                      ? const SizedBox.square(
                          dimension: 19,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync))
            ],
            bottom: TabBar(controller: tabs, tabs: const [
              Tab(icon: Icon(Icons.account_tree_outlined), text: '图谱'),
              Tab(icon: Icon(Icons.bar_chart_outlined), text: '报表'),
              Tab(icon: Icon(Icons.history), text: '动态')
            ])),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null && commits.isEmpty
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.error_outline, size: 40),
                          const SizedBox(height: 12),
                          Text('项目数据加载失败',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          Text(error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                              onPressed: load,
                              icon: const Icon(Icons.refresh),
                              label: const Text('重试'))
                        ])))
                : TabBarView(controller: tabs, children: [
                    GitGraphView(
                        commits: commits,
                        report: report,
                        switchingBranch: switchingBranch,
                        onBranchSelected: (branch) =>
                            selectBranch(project, branch)),
                    ReportsView(report: report),
                    ActivityView(commits: commits)
                  ]));
  }
}

class GitGraphView extends StatefulWidget {
  const GitGraphView(
      {super.key,
      required this.commits,
      required this.report,
      required this.switchingBranch,
      required this.onBranchSelected});
  final List<CommitNode> commits;
  final EngineeringReport? report;
  final bool switchingBranch;
  final ValueChanged<String> onBranchSelected;
  @override
  State<GitGraphView> createState() => _GitGraphViewState();
}

class _GitGraphViewState extends State<GitGraphView> {
  final searchController = TextEditingController();
  final scrollController = ScrollController();
  final commitKeys = <String, GlobalKey>{};
  String searchQuery = '';
  String? selectedSearchCommitId;

  @override
  void dispose() {
    searchController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  bool commitMatches(CommitNode commit, String query) => [
        commit.message,
        commit.author,
        commit.id,
        commit.fullId,
        ...commit.refs
      ].any((value) => value.toLowerCase().contains(query));

  Future<void> copyCommitValue(
      BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label 已复制')));
    }
  }

  Future<void> jumpToCommit(CommitNode commit) async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => selectedSearchCommitId = commit.fullId);
    await WidgetsBinding.instance.endOfFrame;
    var target = commitKeys[commit.fullId]?.currentContext;
    if (target == null && scrollController.hasClients) {
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
      target = commitKeys[commit.fullId]?.currentContext;
    }
    if (target == null || !mounted || !target.mounted) return;
    await Scrollable.ensureVisible(target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        alignment: .18);
  }

  void showCommitDetails(BuildContext pageContext, CommitNode commit) {
    showModalBottomSheet<void>(
        context: pageContext,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(
                            commit.parentIds.length > 1
                                ? Icons.merge
                                : Icons.commit,
                            color: Theme.of(sheetContext).colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text(
                                commit.parentIds.length > 1
                                    ? 'Merge commit · ${commit.parentIds.length} 个父提交'
                                    : 'Commit 详情',
                                style: Theme.of(sheetContext)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700)))
                      ]),
                      const SizedBox(height: 16),
                      ListTile(
                          key: const ValueKey('copy-commit-hash'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.tag),
                          title: const Text('Commit Hash'),
                          subtitle: Text(commit.fullId,
                              style: GoogleFonts.jetBrainsMono(fontSize: 12)),
                          trailing: const Icon(Icons.copy, size: 19),
                          onTap: () => copyCommitValue(
                              pageContext, 'Commit Hash', commit.fullId)),
                      ListTile(
                          key: const ValueKey('copy-commit-name'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.subject),
                          title: const Text('Commit 名称'),
                          subtitle: Text(commit.message,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700)),
                          trailing: const Icon(Icons.copy, size: 19),
                          onTap: () => copyCommitValue(
                              pageContext, 'Commit 名称', commit.message)),
                      const SizedBox(height: 8),
                      Text('${commit.author} · ${commit.date.toLocal()}',
                          style: TextStyle(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurfaceVariant)),
                      if (commit.refs.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: commit.refs
                                .map((ref) => Chip(label: Text(ref)))
                                .toList())
                      ]
                    ]))));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.commits.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: const [
        AppEmptyState(
            icon: Icons.commit, title: '仓库没有提交', message: '分析服务未在默认分支中找到提交记录。')
      ]);
    }
    final report = widget.report;
    final currentMetric = report?.currentBranchMetric;
    final branchLength = currentMetric?.commitCount ?? widget.commits.length;
    final branchLengthLabel =
        '${currentMetric?.truncated == true ? '≥' : ''}$branchLength';
    final normalizedQuery = searchQuery.trim().toLowerCase();
    final matchingCommits = normalizedQuery.isEmpty
        ? const <CommitNode>[]
        : widget.commits
            .where((commit) => commitMatches(commit, normalizedQuery))
            .toList();
    final matchingBranches = normalizedQuery.isEmpty
        ? const <BranchMetric>[]
        : (report?.branchDetails ?? const <BranchMetric>[])
            .where(
                (branch) => branch.name.toLowerCase().contains(normalizedQuery))
            .toList();
    final laneCount = math.max(
        1,
        widget.commits.fold<int>(
                0, (maximum, commit) => math.max(maximum, commit.lane)) +
            1);
    return ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(16),
        children: [
          if (report != null) ...[
            BranchSelectorCard(
                report: report,
                loading: widget.switchingBranch,
                onSelected: widget.onBranchSelected),
            const SizedBox(height: 12),
          ],
          SearchBar(
              controller: searchController,
              leading: const Icon(Icons.search),
              hintText: '搜索提交内容、作者、哈希或分支',
              constraints: const BoxConstraints(minHeight: 52),
              trailing: [
                if (searchQuery.isNotEmpty)
                  IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        searchController.clear();
                        setState(() {
                          searchQuery = '';
                          selectedSearchCommitId = null;
                        });
                      },
                      icon: const Icon(Icons.close))
              ],
              onChanged: (value) => setState(() => searchQuery = value)),
          if (normalizedQuery.isNotEmpty) ...[
            const SizedBox(height: 10),
            AppCard(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(children: [
                    const Icon(Icons.manage_search, size: 19),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            '${matchingCommits.length} 个提交 · ${matchingBranches.length} 个分支',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)))
                  ]),
                  if (matchingBranches.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: matchingBranches
                            .take(8)
                            .map((branch) => ActionChip(
                                avatar: Icon(
                                    branch.isCurrent
                                        ? Icons.check_circle
                                        : Icons.call_split,
                                    size: 17),
                                label: Text(branch.name),
                                onPressed: widget.switchingBranch ||
                                        branch.isCurrent
                                    ? null
                                    : () =>
                                        widget.onBranchSelected(branch.name)))
                            .toList())
                  ],
                  if (matchingCommits.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...matchingCommits.take(8).map((commit) => ListTile(
                        key: ValueKey('search-${commit.fullId}'),
                        minTileHeight: 52,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(commit.parentIds.length > 1
                            ? Icons.merge
                            : Icons.commit),
                        title: Text(commit.message,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${commit.id} · ${commit.author}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        selected: selectedSearchCommitId == commit.fullId,
                        onTap: () => setState(
                            () => selectedSearchCommitId = commit.fullId))),
                    if (matchingCommits.length > 8)
                      Text(
                          '另有 ${matchingCommits.length - 8} 个匹配提交，请输入更多关键词缩小范围。',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                    if (selectedSearchCommitId != null &&
                        matchingCommits.any((commit) =>
                            commit.fullId == selectedSearchCommitId)) ...[
                      const SizedBox(height: 10),
                      FilledButton.icon(
                          key: const ValueKey('jump-to-search-commit'),
                          onPressed: () => jumpToCommit(
                              matchingCommits.firstWhere((commit) =>
                                  commit.fullId == selectedSearchCommitId)),
                          icon: const Icon(Icons.south),
                          label: const Text('跳转到该提交'))
                    ]
                  ],
                  if (matchingCommits.isEmpty && matchingBranches.isEmpty) ...[
                    const SizedBox(height: 12),
                    Text('当前已加载历史中没有匹配结果。',
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant))
                  ]
                ])),
          ],
          const SizedBox(height: 14),
          const Eyebrow('COMMIT EVOLUTION'),
          const SizedBox(height: 5),
          Text('$branchLengthLabel commits · $laneCount lanes',
              style: GoogleFonts.jetBrainsMono(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          AppCard(child: LayoutBuilder(builder: (context, constraints) {
            final graphWidth = math.min(
                constraints.maxWidth * .42, 52.0 + (laneCount - 1) * 18.0);
            return SizedBox(
                height: widget.commits.length * 74,
                child: Stack(children: [
                  Positioned.fill(
                      child: CustomPaint(
                          painter: GraphPainter(widget.commits,
                              Theme.of(context).colorScheme, graphWidth))),
                  ...widget.commits.indexed.map((entry) {
                    final index = entry.$1;
                    final commit = entry.$2;
                    return Positioned(
                        top: index * 74.0,
                        left: graphWidth + 8,
                        right: 0,
                        height: 70,
                        child: Material(
                            key: commitKeys.putIfAbsent(
                                commit.fullId, () => GlobalKey()),
                            color: selectedSearchCommitId == commit.fullId
                                ? Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: .72)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => showCommitDetails(context, commit),
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(commit.message,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600)),
                                          const SizedBox(height: 4),
                                          Text(
                                              '${commit.id} · ${commit.author}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: GoogleFonts.jetBrainsMono(
                                                  fontSize: 11,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant)),
                                          if (commit.parentIds.length > 1 ||
                                              commit.refs.isNotEmpty)
                                            Row(children: [
                                              if (commit.parentIds.length >
                                                  1) ...[
                                                Icon(Icons.merge,
                                                    size: 12,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .tertiary),
                                                const SizedBox(width: 3),
                                              ],
                                              Expanded(
                                                  child: Text(
                                                      [
                                                        if (commit.parentIds
                                                                .length >
                                                            1)
                                                          'MERGE · ${commit.parentIds.length} parents',
                                                        ...commit.refs
                                                      ].join(' · '),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                          fontSize: 10,
                                                          color:
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .primary)))
                                            ])
                                        ])))));
                  })
                ]));
          })),
        ]);
  }
}

class BranchSelectorCard extends StatelessWidget {
  const BranchSelectorCard(
      {super.key,
      required this.report,
      required this.loading,
      required this.onSelected});
  final EngineeringReport report;
  final bool loading;
  final ValueChanged<String> onSelected;

  String relationLabel(BranchMetric? branch) {
    if (branch == null || branch.relation == 'default') return '默认分支';
    if (branch.ahead == null || branch.behind == null) return '关联度待分析';
    if (branch.ahead == 0 && branch.behind == 0) return '与默认分支一致';
    return '领先 ${branch.ahead} · 落后 ${branch.behind}';
  }

  @override
  Widget build(BuildContext context) {
    final branches = report.branchDetails;
    final current = report.currentBranchMetric;
    return AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.account_tree_outlined,
            color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
            child: Text(report.isBranchOverview ? '全部分支图谱' : '单分支图谱',
                style: const TextStyle(fontWeight: FontWeight.w700))),
        if (loading)
          const SizedBox.square(
              dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
      ]),
      const SizedBox(height: 12),
      InputDecorator(
          decoration: const InputDecoration(
              labelText: '当前分支', prefixIcon: Icon(Icons.call_split_outlined)),
          child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                  value: report.isBranchOverview
                      ? branchOverviewName
                      : branches
                              .any((item) => item.name == report.currentBranch)
                          ? report.currentBranch
                          : null,
                  isExpanded: true,
                  hint: Text(report.currentBranch),
                  onChanged: loading
                      ? null
                      : (value) {
                          if (value != null && value != report.currentBranch) {
                            onSelected(value);
                          }
                        },
                  items: [
                DropdownMenuItem(
                    value: branchOverviewName,
                    child: Row(children: [
                      const Icon(Icons.hub_outlined, size: 19),
                      const SizedBox(width: 9),
                      Expanded(
                          child: Text('分支 Overview · 全部 ${branches.length} 个',
                              maxLines: 1, overflow: TextOverflow.ellipsis))
                    ])),
                ...branches.map((branch) => DropdownMenuItem(
                    value: branch.name,
                    child: Text(
                        branch.commitCount == null
                            ? branch.name
                            : '${branch.name} · ${branch.truncated ? '≥' : ''}${branch.commitCount}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)))
              ]))),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        DataBadge(
            icon: Icons.commit,
            label: report.isBranchOverview
                ? '唯一提交 ${report.totalCommits}'
                : current?.commitCount == null
                    ? '长度待分析'
                    : '长度 ${current!.truncated ? '≥' : ''}${current.commitCount}'),
        DataBadge(icon: Icons.width_normal, label: '分支宽度 ${report.branches}'),
        DataBadge(
            icon: report.isBranchOverview
                ? Icons.hub_outlined
                : Icons.compare_arrows,
            label: report.isBranchOverview ? '全部远程分支' : relationLabel(current))
      ]),
      const SizedBox(height: 8),
      Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
              key: ValueKey('branch-overview-${report.currentBranch}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              initiallyExpanded: report.isBranchOverview,
              leading: const Icon(Icons.schema_outlined),
              title: const Text('分支 Overview',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${branches.length} 个远程分支 · 展开查看全部'),
              children: branches
                  .map((branch) => Padding(
                      key: ValueKey('branch-overview-${branch.name}'),
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                          type: MaterialType.card,
                          clipBehavior: Clip.antiAlias,
                          color: branch.isCurrent
                              ? Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: .7)
                              : Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                              minTileHeight: 56,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              leading: Icon(branch.isCurrent ? Icons.check_circle : Icons.call_split,
                                  color: branch.isCurrent
                                      ? Theme.of(context).colorScheme.primary
                                      : null),
                              title: Text(branch.name,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text('${branch.tip.isEmpty ? '无远程 Tip' : branch.tip.substring(0, math.min(7, branch.tip.length))} · ${branch.commitCount == null ? '尚未加载长度' : '${branch.truncated ? '≥' : ''}${branch.commitCount} commits'}', maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: branch.isDefault ? const Chip(label: Text('默认')) : const Icon(Icons.chevron_right),
                              enabled: !loading,
                              onTap: branch.isCurrent || loading ? null : () => onSelected(branch.name)))))
                  .toList()))
    ]));
  }
}

class DataBadge extends StatelessWidget {
  const DataBadge({super.key, required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon,
            size: 15, color: Theme.of(context).colorScheme.onPrimaryContainer),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onPrimaryContainer))
      ]));
}

enum GraphEdgeAnchor { parent, child }

List<Offset> graphEdgePoints(Offset start, Offset end,
    {GraphEdgeAnchor anchor = GraphEdgeAnchor.parent}) {
  if ((start.dx - end.dx).abs() < .01) return [start, end];
  final verticalDirection = end.dy >= start.dy ? 1.0 : -1.0;
  final availableHeight = (end.dy - start.dy).abs();
  final diagonalHeight = (end.dx - start.dx).abs();
  if (availableHeight <= diagonalHeight) return [start, end];
  // Every lane change uses the same 1:1 diagonal. A branch edge remains
  // straight on its new lane and joins exactly at the parent node; a merge
  // edge does the inverse and joins exactly at the merge commit node.
  return anchor == GraphEdgeAnchor.parent
      ? [
          start,
          Offset(start.dx, end.dy - verticalDirection * diagonalHeight),
          end
        ]
      : [
          start,
          Offset(end.dx, start.dy + verticalDirection * diagonalHeight),
          end
        ];
}

class GraphPainter extends CustomPainter {
  GraphPainter(this.commits, this.colors, this.graphWidth);
  final List<CommitNode> commits;
  final ColorScheme colors;
  final double graphWidth;

  Color laneColor(int lane) {
    final base = HSLColor.fromColor(colors.primary);
    return base
        .withHue((base.hue + lane * 47) % 360)
        .withSaturation(math.max(.55, base.saturation))
        .toColor();
  }

  double laneX(int lane, int laneCount) {
    if (laneCount <= 1) return graphWidth / 2;
    return 16 + lane * (graphWidth - 32) / (laneCount - 1);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = math.max(
        1,
        commits.fold<int>(
                0, (maximum, commit) => math.max(maximum, commit.lane)) +
            1);
    final indexById = <String, int>{
      for (final entry in commits.indexed) entry.$2.fullId: entry.$1
    };
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = laneCount > 12 ? 1.5 : 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var index = 0; index < commits.length; index++) {
      final commit = commits[index];
      final start = Offset(laneX(commit.lane, laneCount), index * 74 + 35);
      if (commit.parentIds.isEmpty) continue;
      // Paint merged parents first and the first-parent mainline last. This
      // keeps the mainline visually continuous at the merge node.
      for (final parentEntry in commit.parentIds.indexed.toList().reversed) {
        final parentOrder = parentEntry.$1;
        final parentId = parentEntry.$2;
        final parentIndex = indexById[parentId];
        if (parentIndex == null) {
          edgePaint
            ..color = laneColor(commit.lane).withValues(alpha: .62)
            ..strokeWidth = laneCount > 12 ? 1.5 : 2.3;
          canvas.drawLine(start, Offset(start.dx, start.dy + 38), edgePaint);
          continue;
        }
        final parent = commits[parentIndex];
        final end =
            Offset(laneX(parent.lane, laneCount), parentIndex * 74.0 + 35);
        edgePaint
          ..color = laneColor(parent.lane)
              .withValues(alpha: parentOrder == 0 ? .88 : .72)
          ..strokeWidth = laneCount > 12
              ? (parentOrder == 0 ? 1.8 : 1.35)
              : (parentOrder == 0 ? 2.7 : 2.0);
        final points = graphEdgePoints(start, end,
            anchor: commit.parentIds.length > 1
                ? GraphEdgeAnchor.child
                : GraphEdgeAnchor.parent);
        final path = Path()..moveTo(points.first.dx, points.first.dy);
        for (final point in points.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawPath(path, edgePaint);
      }
    }
    for (var i = 0; i < commits.length; i++) {
      final commit = commits[i];
      final center = Offset(laneX(commit.lane, laneCount), i * 74.0 + 35);
      final radius = laneCount > 12 ? 6.0 : 8.0;
      final nodePaint = Paint()..color = laneColor(commit.lane);
      if (commit.parentIds.length > 1) {
        final mergeRadius = radius + 1.5;
        canvas.drawPath(
            Path()
              ..moveTo(center.dx, center.dy - mergeRadius)
              ..lineTo(center.dx + mergeRadius, center.dy)
              ..lineTo(center.dx, center.dy + mergeRadius)
              ..lineTo(center.dx - mergeRadius, center.dy)
              ..close(),
            nodePaint);
      } else {
        canvas.drawCircle(center, radius, nodePaint);
      }
      canvas.drawCircle(center, radius - 3, Paint()..color = colors.surface);
    }
  }

  @override
  bool shouldRepaint(covariant GraphPainter oldDelegate) =>
      oldDelegate.commits != commits ||
      oldDelegate.colors != colors ||
      oldDelegate.graphWidth != graphWidth;
}

class ReportsView extends StatelessWidget {
  const ReportsView({super.key, required this.report});
  final EngineeringReport? report;
  @override
  Widget build(BuildContext context) {
    final value = report;
    if (value == null) {
      return ListView(padding: const EdgeInsets.all(16), children: const [
        AppEmptyState(
            icon: Icons.bar_chart_outlined,
            title: '报表不可用',
            message: '当前项目没有可显示的聚合数据。')
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Eyebrow('ENGINEERING REPORT'),
      const SizedBox(height: 12),
      GridView.count(
          crossAxisCount: 2,
          childAspectRatio: 1.45,
          mainAxisSpacing: 9,
          crossAxisSpacing: 9,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            MetricCard(
                label: '当前分支长度',
                value:
                    '${value.currentBranchMetric?.truncated == true ? '≥' : ''}${value.totalCommits}',
                delta: value.currentBranch),
            MetricCard(
                label: '贡献者',
                value: '${value.contributors.length}',
                delta: '按作者'),
            MetricCard(
                label: '分支宽度', value: '${value.branches}', delta: '远程 heads'),
            MetricCard(label: '标签', value: '${value.tags}', delta: 'refs')
          ]),
      const SizedBox(height: 12),
      AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('每周提交分布', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        WeekdayDistribution(values: value.commitsByWeekday),
        const SizedBox(height: 8),
        const Text('按 UTC 提交时间聚合，柱顶数字为精确提交数。', style: TextStyle(fontSize: 12))
      ])),
      const SizedBox(height: 12),
      AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('核心贡献者', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (value.contributors.isEmpty)
          const Text('暂无贡献者数据')
        else
          ...value.contributors.take(20).map((person) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const CircleAvatar(
                  radius: 16, child: Icon(Icons.person, size: 17)),
              title: Text(person.name),
              trailing: Text('${person.commits}')))
      ])),
      const SizedBox(height: 12),
      AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('文件热点', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (value.hotspots.isEmpty)
          const Text('当前仓库没有可用热点数据')
        else
          ...value.hotspots.take(10).map((item) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title:
                  Text(item.path, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: Text('${item.changes} 行')))
      ]))
    ]);
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard(
      {super.key,
      required this.label,
      required this.value,
      required this.delta});
  final String label, value, delta;
  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(13),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            const Spacer(),
            Text(value,
                style: GoogleFonts.jetBrainsMono(
                    fontSize: 23, fontWeight: FontWeight.w600)),
            Text(delta,
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).colorScheme.primary))
          ])));
}

class WeekdayDistribution extends StatelessWidget {
  const WeekdayDistribution({super.key, required this.values});
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    const labels = ['日', '一', '二', '三', '四', '五', '六'];
    final normalized = List<int>.generate(
        7, (index) => index < values.length ? values[index] : 0);
    final total = normalized.fold<int>(0, (sum, value) => sum + value);
    if (total == 0) {
      return const SizedBox(
          height: 132, child: Center(child: Text('当前分支暂无可统计的提交时间数据')));
    }
    final maximum = math.max(1, normalized.reduce(math.max));
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
        height: 168,
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: normalized.indexed.map((entry) {
              final index = entry.$1;
              final value = entry.$2;
              return Expanded(
                  child: Semantics(
                      label: '周${labels[index]} $value 次提交',
                      child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Column(children: [
                            Text('$value',
                                style: GoogleFonts.jetBrainsMono(
                                    fontSize: 10, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 5),
                            Expanded(
                                child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: FractionallySizedBox(
                                        heightFactor:
                                            value == 0 ? .025 : value / maximum,
                                        widthFactor: .62,
                                        child: DecoratedBox(
                                            decoration: BoxDecoration(
                                                color: value == 0
                                                    ? Theme.of(context)
                                                        .colorScheme
                                                        .outlineVariant
                                                    : color,
                                                borderRadius:
                                                    const BorderRadius.vertical(
                                                        top: Radius.circular(
                                                            5))))))),
                            const SizedBox(height: 7),
                            Text(labels[index],
                                style: const TextStyle(fontSize: 11))
                          ]))));
            }).toList()));
  }
}

class ActivityView extends StatelessWidget {
  const ActivityView({super.key, required this.commits});
  final List<CommitNode> commits;
  @override
  Widget build(BuildContext context) {
    if (commits.isEmpty) {
      return ListView(padding: const EdgeInsets.all(16), children: const [
        AppEmptyState(
            icon: Icons.history, title: '暂无动态', message: '提交记录加载后会按时间显示在这里。')
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Eyebrow('REPOSITORY ACTIVITY'),
      const SizedBox(height: 12),
      ...commits.take(30).map((commit) => Card(
          child: ListTile(
              minTileHeight: 74,
              leading: const CircleAvatar(child: Icon(Icons.commit)),
              title: Text(commit.message),
              subtitle: Text('${commit.author} · ${commit.date.toLocal()}'))))
    ]);
  }
}
