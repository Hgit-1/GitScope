import 'package:flutter_test/flutter_test.dart';
import 'package:gitscope_mobile/models.dart';
import 'package:gitscope_mobile/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('account storage starts empty', () async {
    expect(await AppStore().loadAccounts(), isEmpty);
  });

  test('account storage persists only verified account metadata', () async {
    const account = AccountRef(id: '42', login: 'real-user', isDefault: true);
    final store = AppStore();
    await store.saveAccounts([account]);
    final loaded = await store.loadAccounts();
    expect(loaded, hasLength(1));
    expect(loaded.single.login, 'real-user');
  });

  test('unversioned legacy account data is never imported', () async {
    SharedPreferences.setMockInitialValues(
        {'accounts': '[{"id":"maya","login":"mayacodes","isDefault":true}]'});
    expect(await AppStore().loadAccounts(), isEmpty);
  });

  test('custom API endpoint persists for physical device use', () async {
    final store = AppStore();
    await store.saveApiBase('https://git-api.example.com');
    expect(await store.loadApiBase(), 'https://git-api.example.com');
  });

  test('device-local analysis is the default and selected mode persists',
      () async {
    final store = AppStore();
    expect(await store.loadAnalysisMode(), AnalysisMode.local);
    await store.saveAnalysisMode(AnalysisMode.remote);
    expect(await store.loadAnalysisMode(), AnalysisMode.remote);
  });

  test('first-run permission introduction is shown only once', () async {
    final store = AppStore();
    expect(await store.hasSeenPermissionIntro(), isFalse);
    await store.markPermissionIntroSeen();
    expect(await store.hasSeenPermissionIntro(), isTrue);
  });

  test('projects created before local analysis remain remote-backed', () {
    final project = SavedProject.fromJson({
      'id': 'old-api-id',
      'owner': 'verified',
      'name': 'repository',
      'url': 'https://github.com/verified/repository',
      'provider': 'github',
    });
    expect(project.analysisMode, AnalysisMode.remote);
  });

  test(
      'project storage retains the secure account reference for branch reloads',
      () async {
    const project = SavedProject(
        id: 'project-id',
        owner: 'verified',
        name: 'repository',
        url: 'https://github.com/verified/repository',
        provider: GitProvider.github,
        accountId: '42',
        isPrivate: true);
    final store = AppStore();
    await store.saveProjects([project]);
    final loaded = await store.loadProjects();
    expect(loaded.single.accountId, '42');
    expect(loaded.single.isPrivate, isTrue);
  });
}
