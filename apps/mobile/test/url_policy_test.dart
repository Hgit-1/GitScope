import 'package:flutter_test/flutter_test.dart';
import 'package:gitscope_mobile/url_policy.dart';

void main() {
  test('accepts a normal HTTPS repository URL', () {
    expect(validateRepositoryUrl('https://github.com/flutter/flutter.git').host,
        'github.com');
  });

  test('rejects credentials, local hosts and unsafe schemes', () {
    expect(() => validateRepositoryUrl('http://github.com/flutter/flutter'),
        throwsA(isA<RepositoryUrlException>()));
    expect(
        () => validateRepositoryUrl('https://token@github.com/flutter/flutter'),
        throwsA(isA<RepositoryUrlException>()));
    expect(() => validateRepositoryUrl('https://localhost/acme/mobile'),
        throwsA(isA<RepositoryUrlException>()));
  });
}
