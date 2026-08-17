import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscope_mobile/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gitscope.test/local_git');

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('device-local service analyzes and reads native graph/report data',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'analyze':
          return {'projectId': '11111111-1111-1111-1111-111111111111'};
        case 'analyzeBranch':
          return {
            'projectId': '11111111-1111-1111-1111-111111111111',
            'branch': 'feature/mobile'
          };
        case 'graph':
          return {
            'commits': [
              {
                'id': 'abcdef012345',
                'shortId': 'abcdef0',
                'message': 'native commit',
                'author': 'Verified User',
                'authoredAt': '2026-08-17T08:00:00Z',
                'lane': 0,
                'refs': ['main']
              }
            ],
            'truncated': false
          };
        case 'report':
          return {
            'totalCommits': 1,
            'branches': 1,
            'tags': 0,
            'defaultBranch': 'main',
            'currentBranch': 'main',
            'branchDetails': [
              {
                'name': 'main',
                'tip': 'abcdef012345',
                'isDefault': true,
                'isCurrent': true,
                'relation': 'default',
                'commitCount': 1,
                'ahead': 0,
                'behind': 0
              }
            ],
            'contributors': [
              {'name': 'Verified User', 'commits': 1}
            ],
            'commitsByWeekday': [0, 1, 0, 0, 0, 0, 0],
            'hotspots': [
              {'path': 'README.md', 'changes': 1}
            ],
            'generatedAt': '2026-08-17T08:00:00Z'
          };
        case 'deleteProject':
          return true;
      }
      return null;
    });

    final service = LocalGitAnalysisService(channel: channel);
    final id = await service.analyze('https://github.com/verified/repository');
    await service.analyzeBranch(
        id, 'https://github.com/verified/repository', 'feature/mobile');
    final graph = await service.graph(id);
    final report = await service.report(id);
    await service.deleteProject(id);

    expect(graph.commits.single.message, 'native commit');
    expect(report.contributors.single.name, 'Verified User');
    expect(report.hotspots.single.path, 'README.md');
    expect(report.currentBranch, 'main');
    expect(report.currentBranchMetric?.commitCount, 1);
    expect(report.commitsByWeekday, hasLength(7));
    expect(calls,
        ['analyze', 'analyzeBranch', 'graph', 'report', 'deleteProject']);
  });

  test('VPN connection failures return a specific local-analysis hint',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'networkStatus') {
        return {
          'connected': true,
          'vpnActive': true,
          'wifi': false,
          'cellular': false,
        };
      }
      throw PlatformException(code: 'GIT_CONNECTION', message: '无法连接 Git 仓库');
    });
    final service = LocalGitAnalysisService(channel: channel);
    await expectLater(
        service.analyze('https://github.com/verified/repository'),
        throwsA(predicate((error) =>
            error.toString().contains('当前检测到 VPN；请为 GitScope 或仓库域名启用分流'))));
  });

  test('device-local service streams only matching live clone events',
      () async {
    final events = StreamController<Object?>.broadcast();
    addTearDown(events.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'analyze') return null;
      final arguments = call.arguments as Map<Object?, Object?>;
      final sessionId = arguments['sessionId'] as String;
      events.add({
        'sessionId': 'another-task',
        'progress': .4,
        'stage': 'CLONE',
        'message': '不应显示'
      });
      events.add({
        'sessionId': sessionId,
        'progress': .55,
        'stage': 'CLONE',
        'message': '正在接收对象 · 55%'
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return {'projectId': '11111111-1111-1111-1111-111111111111'};
    });

    final progress = <String>[];
    final service = LocalGitAnalysisService(
        channel: channel, analysisEvents: events.stream);
    await service.analyze('https://github.com/verified/repository',
        onProgress: (_, message) => progress.add(message));

    expect(progress, contains('CLONE · 正在接收对象 · 55%'));
    expect(progress.any((line) => line.contains('不应显示')), isFalse);
  });

  test('remote 10.0.2.2 diagnostic identifies VPN route capture', () async {
    final adapter = _FailingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://10.0.2.2:8080'))
      ..httpClientAdapter = adapter;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'connected': true,
                  'vpnActive': true,
                  'wifi': false,
                  'cellular': false,
                });
    final service = RemoteAnalysisService(
        api: GitScopeApi(dio: dio),
        local: LocalGitAnalysisService(channel: channel));
    await expectLater(
        service.health(),
        throwsA(predicate(
            (error) => error.toString().contains('VPN 正在接管 10.0.0.0/8'))));
  });
}

class _FailingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    throw DioException.connectionTimeout(
        requestOptions: options, timeout: const Duration(seconds: 1));
  }

  @override
  void close({bool force = false}) {}
}
