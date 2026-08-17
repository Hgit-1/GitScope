import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscope_mobile/main.dart';
import 'package:gitscope_mobile/models.dart';
import 'package:gitscope_mobile/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeGithubAccountService extends GithubAccountService {
  @override
  Future<AccountRef> verifyToken(String token) async =>
      const AccountRef(id: '42', login: 'actual-user', isDefault: false);
}

class FakeAccountVault extends AccountVault {
  FakeAccountVault() : super(const FlutterSecureStorage());
  final tokens = <String, String>{};

  @override
  Future<void> saveTokens(String accountId,
      {required String accessToken, String? refreshToken}) async {
    tokens[accountId] = accessToken;
  }

  @override
  Future<String?> accessToken(String accountId) async => tokens[accountId];

  @override
  Future<void> remove(String accountId) async {
    tokens.remove(accountId);
  }

  @override
  Future<void> clear() async {
    tokens.clear();
  }
}

class FakeAppPermissionService extends AppPermissionService {
  MediaPermissionStatus status = MediaPermissionStatus.denied;
  var requestCount = 0;
  var settingsCount = 0;

  @override
  Future<MediaPermissionStatus> mediaStatus() async => status;

  @override
  Future<MediaPermissionStatus> requestMedia() async {
    requestCount++;
    return status = MediaPermissionStatus.granted;
  }

  @override
  Future<void> openSettings() async {
    settingsCount++;
  }
}

void main() {
  testWidgets('returning from a repository keeps the home link field unfocused',
      (tester) async {
    final repositoryController = TextEditingController();
    final repositoryFocus = FocusNode();
    addTearDown(repositoryController.dispose);
    addTearDown(repositoryFocus.dispose);
    await tester.pumpWidget(MaterialApp(
        navigatorObservers: [KeyboardDismissNavigatorObserver()],
        home: Scaffold(
            body: Column(children: [
          TextField(
              key: const ValueKey('repository-link'),
              focusNode: repositoryFocus,
              controller: repositoryController),
          FilledButton(
              onPressed: () => Navigator.of(tester
                      .element(find.byKey(const ValueKey('open-repository'))))
                  .push(MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Repository')),
                          body: const Center(
                              child: Text('Repository details'))))),
              key: const ValueKey('open-repository'),
              child: const Text('Open repository'))
        ]))));

    await tester.showKeyboard(find.byKey(const ValueKey('repository-link')));
    await tester.enterText(find.byKey(const ValueKey('repository-link')),
        'https://github.com/example/repository');
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byKey(const ValueKey('open-repository')));
    await tester.pumpAndSettle();
    expect(find.text('Repository details'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('repository-link')), findsOneWidget);
    expect(repositoryController.text, 'https://github.com/example/repository');
    expect(tester.testTextInput.isVisible, isFalse);
    expect(repositoryFocus.hasFocus, isFalse);
  });

  testWidgets('GitScope renders its repository workspace', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: GitScopeApp()));
    await tester.pumpAndSettle();

    expect(find.text('Git 仓库链接'), findsOneWidget);
    expect(find.text('导入并分析'), findsOneWidget);
    expect(find.text('设备内'), findsOneWidget);
  });

  testWidgets('account vault accepts and securely saves a classic GitHub PAT',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final vault = FakeAccountVault();
    await tester.pumpWidget(ProviderScope(overrides: [
      githubAccountProvider.overrideWithValue(FakeGithubAccountService()),
      vaultProvider.overrideWithValue(vault),
    ], child: const GitScopeApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('账号库').last);
    await tester.pumpAndSettle();
    expect(find.text('尚未连接账号'), findsOneWidget);
    expect(find.text('mayacodes'), findsNothing);
    expect(find.text('acme-mobile'), findsNothing);

    await tester.tap(find.text('连接 GitHub 账号').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ghp_unit_test_1234567');
    await tester.tap(find.text('验证并安全保存'));
    await tester.pumpAndSettle();

    expect(find.text('actual-user'), findsOneWidget);
    expect(vault.tokens['42'], 'ghp_unit_test_1234567');
  });

  testWidgets('all primary tabs remain operable on a compact dark-mode phone',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'theme_v2': '{"mode":"dark","accent":4283096704}'});
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const ProviderScope(child: GitScopeApp()));
    await tester.pumpAndSettle();
    for (final label in ['项目', '账号库', '设置', '导入']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'tab: $label');
    }
    expect(find.text('仓库工作台'), findsOneWidget);

    tester.view.physicalSize = const Size(667, 375);
    await tester.pumpAndSettle();
    for (final label in ['项目', '账号库', '设置', '导入']) {
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'landscape tab: $label');
    }
  });

  testWidgets('analysis mode sheet works in portrait and landscape',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const ProviderScope(child: GitScopeApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析服务'));
    await tester.pumpAndSettle();
    expect(find.text('本机分析引擎已内置'), findsOneWidget);
    expect(find.text('使用标准模式'), findsOneWidget);

    tester.view.physicalSize = const Size(667, 375);
    await tester.pumpAndSettle();
    await tester.tap(find.text('远程 API'));
    await tester.pumpAndSettle();
    expect(find.text('远程服务地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto fetch schedule offers system-friendly intervals',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const ProviderScope(child: GitScopeApp()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动 Fetch'));
    await tester.pumpAndSettle();

    expect(find.text('每小时'), findsOneWidget);
    expect(find.text('每 6 小时'), findsOneWidget);
    expect(find.text('每天'), findsOneWidget);
    expect(find.text('每周'), findsOneWidget);
    expect(find.textContaining('HarmonyOS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission center explains and requests only media access',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final permissions = FakeAppPermissionService();
    await tester.pumpWidget(ProviderScope(overrides: [
      permissionServiceProvider.overrideWithValue(permissions),
    ], child: const GitScopeApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用权限'));
    await tester.pumpAndSettle();

    expect(find.text('照片与媒体'), findsOneWidget);
    expect(find.text('项目存储'), findsOneWidget);
    expect(find.text('应用私有目录，不读取其他文件'), findsOneWidget);
    expect(find.text('申请照片权限'), findsOneWidget);

    await tester.tap(find.text('申请照片权限'));
    await tester.pumpAndSettle();
    expect(permissions.requestCount, 1);
    expect(find.text('已允许'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'weekday distribution renders exact values instead of a blank line',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: WeekdayDistribution(values: [1, 3, 0, 7, 2, 0, 4]))));
    await tester.pumpAndSettle();
    for (final label in ['日', '一', '二', '三', '四', '五', '六']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('branch selector exposes branch width and switches one branch',
      (tester) async {
    String? selected;
    final report = EngineeringReport(
        totalCommits: 12,
        branches: 2,
        tags: 0,
        contributors: const [],
        commitsByWeekday: const [1, 2, 3, 2, 1, 2, 1],
        hotspots: const [],
        generatedAt: DateTime.utc(2026, 8, 17),
        defaultBranch: 'main',
        currentBranch: 'main',
        branchDetails: const [
          BranchMetric(
              name: 'main',
              tip: 'a',
              isDefault: true,
              isCurrent: true,
              relation: 'default',
              commitCount: 12),
          BranchMetric(
              name: 'feature/mobile',
              tip: 'b',
              isDefault: false,
              isCurrent: false,
              relation: 'unloaded')
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BranchSelectorCard(
                report: report,
                loading: false,
                onSelected: (value) => selected = value))));
    await tester.tap(find.text('main · 12'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('feature/mobile').last);
    await tester.pumpAndSettle();
    expect(selected, 'feature/mobile');
    expect(find.text('分支宽度 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('branch overview exposes every remote branch on a compact phone',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    String? selected;
    final report = EngineeringReport(
        totalCommits: 38,
        branches: 3,
        tags: 2,
        contributors: const [],
        commitsByWeekday: const [4, 5, 6, 7, 8, 4, 4],
        hotspots: const [],
        generatedAt: DateTime.utc(2026, 8, 17),
        defaultBranch: 'main',
        currentBranch: branchOverviewName,
        branchDetails: const [
          BranchMetric(
              name: 'main',
              tip: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              isDefault: true,
              isCurrent: false,
              relation: 'overview',
              commitCount: 30),
          BranchMetric(
              name: 'feature/mobile',
              tip: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              isDefault: false,
              isCurrent: false,
              relation: 'overview',
              commitCount: 12),
          BranchMetric(
              name: 'release/0.7',
              tip: 'cccccccccccccccccccccccccccccccccccccccc',
              isDefault: false,
              isCurrent: false,
              relation: 'overview',
              commitCount: 21)
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: BranchSelectorCard(
                    report: report,
                    loading: false,
                    onSelected: (value) => selected = value)))));
    await tester.pumpAndSettle();

    expect(find.text('全部分支图谱'), findsOneWidget);
    expect(find.text('分支 Overview · 全部 3 个'), findsOneWidget);
    expect(find.text('唯一提交 38'), findsOneWidget);
    expect(find.text('全部远程分支'), findsOneWidget);
    for (final branch in ['main', 'feature/mobile', 'release/0.7']) {
      expect(find.byKey(ValueKey('branch-overview-$branch')), findsOneWidget);
    }
    expect(find.text('默认'), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('branch-overview-feature/mobile')));
    await tester.pump();
    expect(selected, 'feature/mobile');
    expect(tester.takeException(), isNull);
  });

  testWidgets('temporary clone log remains readable while a task is running',
      (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Padding(
                padding: EdgeInsets.all(16),
                child: TemporaryCloneLogPanel(taskRunning: true, lines: [
                  '13:20:01  CLONE · 正在接收对象 · 45%',
                  '13:20:02  CLONE · 正在解析增量 · 60%'
                ])))));
    await tester.pumpAndSettle();

    expect(find.text('实时克隆日志'), findsOneWidget);
    expect(find.text('任务中 · 临时'), findsOneWidget);
    expect(find.textContaining('正在接收对象'), findsOneWidget);
    expect(find.textContaining('正在解析增量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('graph edges keep a fixed diagonal across long parent gaps', () {
    final points = graphEdgePoints(const Offset(12, 20), const Offset(42, 240));
    expect(points, const [Offset(12, 20), Offset(12, 210), Offset(42, 240)]);
    expect(points[1].dx, points.first.dx,
        reason: 'a diverged branch stays straight on its new lane');
    final diagonal = points[2] - points[1];
    expect(diagonal.dx.abs(), diagonal.dy.abs());

    final mergePoints = graphEdgePoints(
        const Offset(12, 20), const Offset(42, 240),
        anchor: GraphEdgeAnchor.child);
    expect(
        mergePoints, const [Offset(12, 20), Offset(42, 50), Offset(42, 240)]);
    expect(mergePoints[1].dy, 50,
        reason: 'a merge changes lanes directly at its merge node');
  });

  testWidgets('commit search finds content and branch names on a phone',
      (tester) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    String? selectedBranch;
    final commits = [
      CommitNode(
          id: 'aaaaaaa',
          fullId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          message: 'Merge feature mobile',
          author: 'Merge User',
          date: DateTime.utc(2026, 8, 17),
          lane: 0,
          refs: const [
            'main'
          ],
          parentIds: const [
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'cccccccccccccccccccccccccccccccccccccccc'
          ]),
      CommitNode(
          id: 'bbbbbbb',
          fullId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          message: 'Fix feature search',
          author: 'Search User',
          date: DateTime.utc(2026, 8, 16),
          lane: 0,
          refs: const ['feature/mobile'])
    ];
    final report = EngineeringReport(
        totalCommits: 2,
        branches: 2,
        tags: 0,
        contributors: const [],
        commitsByWeekday: const [0, 0, 0, 0, 0, 0, 0],
        hotspots: const [],
        generatedAt: DateTime.utc(2026, 8, 17),
        defaultBranch: 'main',
        currentBranch: 'main',
        branchDetails: const [
          BranchMetric(
              name: 'main',
              tip: 'a',
              isDefault: true,
              isCurrent: true,
              relation: 'default'),
          BranchMetric(
              name: 'feature/mobile',
              tip: 'b',
              isDefault: false,
              isCurrent: false,
              relation: 'unloaded')
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GitGraphView(
                commits: commits,
                report: report,
                switchingBranch: false,
                onBranchSelected: (branch) => selectedBranch = branch))));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'feature');
    await tester.pumpAndSettle();
    expect(
        find.byKey(
            const ValueKey('search-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')),
        findsOneWidget);
    final branchChip = find.widgetWithText(ActionChip, 'feature/mobile');
    expect(branchChip, findsOneWidget);
    await tester.tap(branchChip);
    expect(selectedBranch, 'feature/mobile');

    await tester.tap(find.byKey(
        const ValueKey('search-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')));
    await tester.pump();
    expect(find.byKey(const ValueKey('jump-to-search-commit')), findsOneWidget);
    final jumpButton = find.byKey(const ValueKey('jump-to-search-commit'));
    await tester.ensureVisible(jumpButton);
    await tester.pumpAndSettle();
    await tester.tap(jumpButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('MERGE · 2 parents'), findsOneWidget);

    await tester.tap(find.text('Fix feature search').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('copy-commit-hash')), findsOneWidget);
    tester
        .widget<ListTile>(find.byKey(const ValueKey('copy-commit-hash')))
        .onTap!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(copiedText, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    expect(tester.takeException(), isNull);
  });

  test('project freshness uses concise Chinese relative times', () {
    final now = DateTime(2026, 8, 17, 12);
    expect(freshnessLabel(now.subtract(const Duration(seconds: 20)), now: now),
        '刚刚更新');
    expect(freshnessLabel(now.subtract(const Duration(hours: 1)), now: now),
        '1小时前');
    expect(
        freshnessLabel(now.subtract(const Duration(days: 1)), now: now), '1天前');
    expect(freshnessLabel(now.subtract(const Duration(days: 31)), now: now),
        '一月前');
  });
}
