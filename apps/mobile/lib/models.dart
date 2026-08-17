import 'dart:convert';

enum GitProvider { github, gitlab, bitbucket, generic }

enum JobStatus { queued, validating, cloning, analyzing, completed, failed }

enum AnalysisMode { local, remote }

class AccountRef {
  const AccountRef(
      {required this.id,
      required this.login,
      required this.isDefault,
      this.avatarUrl});
  final String id;
  final String login;
  final bool isDefault;
  final String? avatarUrl;

  AccountRef copyWith({bool? isDefault}) => AccountRef(
      id: id,
      login: login,
      isDefault: isDefault ?? this.isDefault,
      avatarUrl: avatarUrl);

  Map<String, dynamic> toJson() => {
        'id': id,
        'login': login,
        'isDefault': isDefault,
        'avatarUrl': avatarUrl,
      };

  factory AccountRef.fromJson(Map<String, dynamic> json) => AccountRef(
      id: json['id'] as String,
      login: json['login'] as String,
      isDefault: json['isDefault'] as bool? ?? false,
      avatarUrl: json['avatarUrl'] as String?);
}

class SavedProject {
  const SavedProject(
      {required this.id,
      required this.owner,
      required this.name,
      required this.url,
      required this.provider,
      this.analysisMode = AnalysisMode.local,
      this.accountId,
      this.pinned = false,
      this.isPrivate = false});
  final String id;
  final String owner;
  final String name;
  final String url;
  final GitProvider provider;
  final AnalysisMode analysisMode;
  final String? accountId;
  final bool pinned;
  final bool isPrivate;

  SavedProject copyWith({bool? pinned}) => SavedProject(
      id: id,
      owner: owner,
      name: name,
      url: url,
      provider: provider,
      analysisMode: analysisMode,
      accountId: accountId,
      pinned: pinned ?? this.pinned,
      isPrivate: isPrivate);

  Map<String, dynamic> toJson() => {
        'id': id,
        'owner': owner,
        'name': name,
        'url': url,
        'provider': provider.name,
        'analysisMode': analysisMode.name,
        'accountId': accountId,
        'pinned': pinned,
        'isPrivate': isPrivate,
      };

  factory SavedProject.fromJson(Map<String, dynamic> json) => SavedProject(
      id: json['id'] as String,
      owner: json['owner'] as String,
      name: json['name'] as String,
      url: json['url'] as String,
      provider: GitProvider.values.byName(json['provider'] as String),
      // Projects written before local analysis existed were API-backed.
      analysisMode: AnalysisMode.values
          .byName(json['analysisMode'] as String? ?? 'remote'),
      accountId: json['accountId'] as String?,
      pinned: json['pinned'] as bool? ?? false,
      isPrivate: json['isPrivate'] as bool? ?? false);
}

class GraphPage {
  const GraphPage(
      {required this.commits, required this.truncated, this.nextCursor});
  final List<CommitNode> commits;
  final bool truncated;
  final String? nextCursor;

  factory GraphPage.fromJson(Map<String, dynamic> json) => GraphPage(
      commits: (json['commits'] as List<dynamic>? ?? const [])
          .map((item) => CommitNode.fromJson(item as Map<String, dynamic>))
          .toList(),
      truncated: json['truncated'] as bool? ?? false,
      nextCursor: json['nextCursor'] as String?);
}

class ContributorMetric {
  const ContributorMetric({required this.name, required this.commits});
  final String name;
  final int commits;

  factory ContributorMetric.fromJson(Map<String, dynamic> json) =>
      ContributorMetric(
          name: json['name'] as String, commits: json['commits'] as int);
}

class BranchMetric {
  const BranchMetric(
      {required this.name,
      required this.tip,
      required this.isDefault,
      required this.isCurrent,
      required this.relation,
      this.commitCount,
      this.truncated = false,
      this.ahead,
      this.behind});
  final String name;
  final String tip;
  final bool isDefault;
  final bool isCurrent;
  final String relation;
  final int? commitCount;
  final bool truncated;
  final int? ahead;
  final int? behind;

  factory BranchMetric.fromJson(Map<String, dynamic> json) => BranchMetric(
      name: json['name'] as String,
      tip: json['tip'] as String? ?? '',
      isDefault: json['isDefault'] as bool? ?? false,
      isCurrent: json['isCurrent'] as bool? ?? false,
      relation: json['relation'] as String? ?? 'unloaded',
      commitCount: json['commitCount'] as int?,
      truncated: json['truncated'] as bool? ?? false,
      ahead: json['ahead'] as int?,
      behind: json['behind'] as int?);
}

class EngineeringReport {
  const EngineeringReport(
      {required this.totalCommits,
      required this.branches,
      required this.tags,
      required this.contributors,
      required this.commitsByWeekday,
      required this.hotspots,
      required this.generatedAt,
      this.defaultBranch = 'HEAD',
      this.currentBranch = 'HEAD',
      this.branchDetails = const []});
  final int totalCommits;
  final int branches;
  final int tags;
  final List<ContributorMetric> contributors;
  final List<int> commitsByWeekday;
  final List<({String path, int changes})> hotspots;
  final DateTime generatedAt;
  final String defaultBranch;
  final String currentBranch;
  final List<BranchMetric> branchDetails;

  BranchMetric? get currentBranchMetric {
    for (final branch in branchDetails) {
      if (branch.isCurrent || branch.name == currentBranch) return branch;
    }
    return null;
  }

  factory EngineeringReport.fromJson(Map<String, dynamic> json) =>
      EngineeringReport(
          totalCommits: json['totalCommits'] as int? ?? 0,
          branches: json['branches'] as int? ?? 0,
          tags: json['tags'] as int? ?? 0,
          contributors: (json['contributors'] as List<dynamic>? ?? const [])
              .map((item) =>
                  ContributorMetric.fromJson(item as Map<String, dynamic>))
              .toList(),
          commitsByWeekday: List<int>.generate(7, (index) {
            final values =
                json['commitsByWeekday'] as List<dynamic>? ?? const [];
            return index < values.length ? values[index] as int : 0;
          }),
          hotspots:
              (json['hotspots'] as List<dynamic>? ?? const []).map((item) {
            final value = item as Map<String, dynamic>;
            return (
              path: value['path'] as String,
              changes: value['changes'] as int
            );
          }).toList(),
          generatedAt: DateTime.parse(json['generatedAt'] as String),
          defaultBranch: json['defaultBranch'] as String? ?? 'HEAD',
          currentBranch: json['currentBranch'] as String? ??
              json['defaultBranch'] as String? ??
              'HEAD',
          branchDetails: (json['branchDetails'] as List<dynamic>? ?? const [])
              .map(
                  (item) => BranchMetric.fromJson(item as Map<String, dynamic>))
              .toList());
}

String encodeAccounts(List<AccountRef> accounts) =>
    jsonEncode(accounts.map((account) => account.toJson()).toList());
String encodeProjects(List<SavedProject> projects) =>
    jsonEncode(projects.map((project) => project.toJson()).toList());

class CommitNode {
  const CommitNode(
      {required this.id,
      required this.fullId,
      required this.message,
      required this.author,
      required this.date,
      required this.lane,
      this.refs = const [],
      this.parentIds = const []});
  final String id;
  final String fullId;
  final String message;
  final String author;
  final DateTime date;
  final int lane;
  final List<String> refs;
  final List<String> parentIds;

  factory CommitNode.fromJson(Map<String, dynamic> json) {
    final fullId = json['id'] as String;
    return CommitNode(
        id: json['shortId'] as String? ?? fullId.substring(0, 7),
        fullId: fullId,
        message: json['message'] as String,
        author: json['author'] as String,
        date: DateTime.parse(json['authoredAt'] as String),
        lane: json['lane'] as int? ?? 0,
        refs: (json['refs'] as List<dynamic>? ?? const []).cast<String>(),
        parentIds:
            (json['parentIds'] as List<dynamic>? ?? const []).cast<String>());
  }
}

class AnalysisJob {
  const AnalysisJob(
      {required this.id,
      required this.status,
      required this.stage,
      required this.progress,
      this.projectId,
      this.error});
  final String id;
  final JobStatus status;
  final String stage;
  final int progress;
  final String? projectId;
  final String? error;

  factory AnalysisJob.fromJson(Map<String, dynamic> json) => AnalysisJob(
        id: json['id'] as String,
        status: JobStatus.values.byName(json['status'] as String),
        stage: json['stage'] as String,
        progress: json['progress'] as int,
        projectId: json['projectId'] as String?,
        error: json['error'] as String?,
      );
}
