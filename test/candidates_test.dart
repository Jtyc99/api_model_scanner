import 'dart:io';

import 'package:api_model_scanner/src/scanning/model_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('amscan_cand'));
  tearDown(() => temp.deleteSync(recursive: true));

  void write(String relative, String content) {
    final file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String model(String name) => '''
class $name {
  final String id;
  $name({required this.id});
  factory $name.fromJson(Map<String, dynamic> json) =>
      $name(id: json['id'] as String);
  Map<String, dynamic> toJson() => {'id': id};
}
''';

  group('suggesting where the models live', () {
    test('reports a directory of model classes, and how many', () async {
      write('lib/server/response/user.dart', model('User'));
      write('lib/server/response/order.dart', model('Order'));

      final found = await findModelsCandidates(projectRoot: temp.path);

      expect(found, hasLength(1));
      expect(found.single.relative, p.join('lib', 'server', 'response'));
      expect(found.single.classCount, 2);
    });

    test('a file that only calls fromJson is not a models directory',
        () async {
      write('lib/models/user.dart', model('User'));
      write('lib/ui/profile_page.dart', '''
class ProfilePage {
  void load(Map<String, dynamic> json) {
    final user = User.fromJson(json);
    print(user);
  }
}
''');

      final found = await findModelsCandidates(projectRoot: temp.path);

      expect(found.map((c) => c.relative), [p.join('lib', 'models')]);
    });

    test('the richest directory is offered first', () async {
      write('lib/small/a.dart', model('A'));
      write('lib/big/b.dart', model('B'));
      write('lib/big/c.dart', model('C'));

      final found = await findModelsCandidates(projectRoot: temp.path);

      expect(found.map((c) => c.relative).first, p.join('lib', 'big'));
    });

    test('no lib directory yields nothing rather than throwing', () async {
      expect(await findModelsCandidates(projectRoot: temp.path), isEmpty);
    });
  });
}
