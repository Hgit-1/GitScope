class RepositoryUrlException implements Exception {
  const RepositoryUrlException(this.message);
  final String message;
  @override
  String toString() => message;
}

Uri validateRepositoryUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !uri.hasScheme || uri.scheme != 'https') {
    throw const RepositoryUrlException('请输入 HTTPS 仓库地址');
  }
  if (uri.userInfo.isNotEmpty) throw const RepositoryUrlException('仓库地址不能包含凭据');
  if (uri.hasPort && uri.port != 443) {
    throw const RepositoryUrlException('仅允许标准 HTTPS 端口');
  }
  if (uri.host == 'localhost' || uri.host.endsWith('.local')) {
    throw const RepositoryUrlException('不允许本机或局域网地址');
  }
  final segments =
      uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  if (segments.length < 2) {
    throw const RepositoryUrlException('地址中需要包含所有者和仓库名称');
  }
  return uri.replace(fragment: '');
}
