import 'package:api_model_scanner/src/cli/style.dart';
import 'package:test/test.dart';

void main() {
  group('styling', () {
    // These run without a terminal, which is also how a piped run and every
    // CI log sees the tool.
    test('emits no escape codes when nobody can see them', () {
      for (final styled in [
        bold('x'),
        dim('x'),
        accent('x'),
        good('x'),
        bad('x'),
      ]) {
        expect(styled, 'x', reason: 'a piped log should stay readable');
      }
    });

    test('a heading rule is as wide as its title', () {
      expect(headingLine('Scan'), '── Scan ${'─' * 44}');
    });

    test('a labelled value lines its columns up', () {
      expect(labelled('Project', 'demo', width: 8), '  Project   demo');
    });
  });

  group('shortening a path for display', () {
    test('a path inside the project loses the project prefix', () {
      expect(shortPath('/home/me/app/lib/a.dart', '/home/me/app'), 'lib/a.dart');
    });

    test('the project root itself reads as a dot', () {
      expect(shortPath('/home/me/app', '/home/me/app'), '.');
    });

    test('a path outside the project is left alone', () {
      expect(shortPath('/etc/thing.json', '/home/me/app'), '/etc/thing.json');
    });

    test('a home path is abbreviated', () {
      expect(
        shortPath('/home/me/.config/amscan/config.json', '/home/me/app',
            home: '/home/me'),
        '~/.config/amscan/config.json',
      );
    });
  });

  group('abbreviating home', () {
    test('a path under home gets a tilde', () {
      expect(homePath('/home/me/app', home: '/home/me'), '~/app');
    });

    test('home itself is just the tilde', () {
      expect(homePath('/home/me', home: '/home/me'), '~');
    });

    test('a path elsewhere is left alone', () {
      expect(homePath('/opt/app', home: '/home/me'), '/opt/app');
    });
  });
}
