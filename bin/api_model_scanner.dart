import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;

class ModelField {
  final String className;
  final String fieldName;
  final String filePath;
  final int offset;
  final int line;
  final int column;

  ModelField({
    required this.className,
    required this.fieldName,
    required this.filePath,
    required this.offset,
    required this.line,
    required this.column,
  });

  @override
  String toString() {
    return '$className.$fieldName';
  }
}

class Reference {
  final String filePath;
  final int line;
  final int column;

  Reference({required this.filePath, required this.line, required this.column});
}

class DartLanguageServer {
  late Process _process;

  int _nextId = 1;

  final Map<int, Completer<dynamic>> _pending = {};

  List<int> _buffer = [];

  Future<void> start(String projectRoot) async {
    _process = await Process.start(
      'dart',
      [
        'language-server',
        '--protocol=lsp',
        '--client-id=api-model-scanner',
        '--client-version=1.0.0',
      ],
      workingDirectory: projectRoot,
      runInShell: true,
    );

    _process.stdout.listen(
      _handleStdoutBytes,
      onError: (Object error) {
        stderr.writeln('LSP stdout error: $error');
      },
      onDone: () {
        stderr.writeln('Dart language server stdout closed.');
      },
    );

    _process.stderr.transform(utf8.decoder).listen((data) {
      stderr.write('[Dart LSP] $data');
    });

    // Give the process a moment to start.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await _initialize(projectRoot);
  }

  Future<void> _initialize(String projectRoot) async {
    final result = await request('initialize', {
      'processId': pid,
      'clientInfo': {'name': 'api-model-scanner', 'version': '1.0.0'},
      'locale': 'en',
      'rootPath': projectRoot,
      'rootUri': Uri.file(projectRoot).toString(),
      'workspaceFolders': [
        {'uri': Uri.file(projectRoot).toString(), 'name': p.basename(projectRoot)},
      ],
      'capabilities': {
        'workspace': {'applyEdit': false, 'workspaceFolders': true, 'configuration': false},
        'textDocument': {
          'references': {'dynamicRegistration': false},
        },
      },
    });

    if (result is! Map) {
      throw Exception('Invalid initialize response from Dart language server.');
    }

    await notify('initialized', {});
  }

  Future<dynamic> request(String method, Map<String, dynamic> params) async {
    final id = _nextId++;

    final completer = Completer<dynamic>();

    _pending[id] = completer;

    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});

    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pending.remove(id);

        throw TimeoutException('LSP request timed out: $method');
      },
    );
  }

  Future<void> notify(String method, Map<String, dynamic> params) async {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void _send(Map<String, dynamic> message) {
    final body = utf8.encode(jsonEncode(message));

    final header = utf8.encode(
      'Content-Length: ${body.length}\r\n'
      'Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n'
      '\r\n',
    );

    _process.stdin.add(header);
    _process.stdin.add(body);
  }

  void _handleStdoutBytes(List<int> bytes) {
    _buffer.addAll(bytes);

    while (true) {
      final headerEnd = _findHeaderEnd(_buffer);

      if (headerEnd == -1) {
        return;
      }

      final headerBytes = _buffer.sublist(0, headerEnd);

      final header = utf8.decode(headerBytes);

      final contentLengthMatch = RegExp(
        r'Content-Length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(header);

      if (contentLengthMatch == null) {
        throw Exception('LSP response does not contain Content-Length.');
      }

      final contentLength = int.parse(contentLengthMatch.group(1)!);

      final bodyStart = headerEnd + 4;

      if (_buffer.length < bodyStart + contentLength) {
        return;
      }

      final bodyBytes = _buffer.sublist(bodyStart, bodyStart + contentLength);

      _buffer = _buffer.sublist(bodyStart + contentLength);

      final body = utf8.decode(bodyBytes);

      final message = jsonDecode(body) as Map<String, dynamic>;

      _handleMessage(message);
    }
  }

  int _findHeaderEnd(List<int> bytes) {
    for (var i = 0; i < bytes.length - 3; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
        return i;
      }
    }

    return -1;
  }

  void _handleMessage(Map<String, dynamic> message) {
    final id = message['id'];

    if (id is int && _pending.containsKey(id)) {
      final completer = _pending.remove(id)!;

      if (message.containsKey('error')) {
        completer.completeError(Exception('LSP error: ${message['error']}'));
      } else {
        completer.complete(message['result']);
      }

      return;
    }

    // Server notifications / requests.
    //
    // We currently don't need to handle them.
  }

  Future<List<Reference>> findReferences({
    required String filePath,
    required int line,
    required int character,
  }) async {
    final result = await request('textDocument/references', {
      'textDocument': {'uri': Uri.file(filePath).toString()},
      'position': {'line': line, 'character': character},
      'context': {'includeDeclaration': false},
    });

    if (result is! List) {
      return [];
    }

    return result.map<Reference>((item) {
      final map = item as Map<String, dynamic>;

      final uri = map['uri'] as String;

      final range = map['range'] as Map<String, dynamic>;

      final start = range['start'] as Map<String, dynamic>;

      return Reference(
        filePath: Uri.parse(uri).toFilePath(),
        line: start['line'] as int,
        column: start['character'] as int,
      );
    }).toList();
  }

  Future<void> shutdown() async {
    try {
      await request('shutdown', {});
    } catch (_) {}

    _send({'jsonrpc': '2.0', 'method': 'exit', 'params': null});

    await Future<void>.delayed(const Duration(milliseconds: 100));

    _process.kill();
  }
}

Future<List<ModelField>> findModelFields({
  required String projectRoot,
  required String modelsPath,
}) async {
  final result = <ModelField>[];

  final directory = Directory(modelsPath);

  if (!directory.existsSync()) {
    throw Exception('Models directory does not exist: $modelsPath');
  }

  final files = directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));

  for (final file in files) {
    final path = file.path;

    final content = await file.readAsString();

    final parseResult = parseString(content: content, path: path);

    final unit = parseResult.unit;

    for (final declaration in unit.declarations) {
      if (declaration is! ClassDeclaration) {
        continue;
      }

      final className = declaration.namePart.typeName.lexeme;

      for (final member in declaration.body.members) {
        if (member is! FieldDeclaration) {
          continue;
        }

        // Ignore static fields.
        if (member.isStatic) {
          continue;
        }

        for (final variable in member.fields.variables) {
          final nameNode = variable.name;

          final lineInfo = parseResult.lineInfo;

          final location = lineInfo.getLocation(nameNode.offset);

          result.add(
            ModelField(
              className: className,
              fieldName: nameNode.lexeme,
              filePath: path,
              offset: nameNode.offset,
              line: location.lineNumber - 1,
              column: location.columnNumber - 1,
            ),
          );
        }
      }
    }
  }

  return result;
}

bool isInsideModelFile(Reference reference, ModelField field) {
  return p.normalize(p.absolute(reference.filePath)) == p.normalize(p.absolute(field.filePath));
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'models',
      defaultsTo: 'lib/server/response',
      help: 'Directory containing API models.',
    )
    ..addFlag(
      'all',
      defaultsTo: false,
      help: 'Scan all Dart files instead of only models directory.',
    );

  final args = parser.parse(arguments);

  final projectRoot = Directory.current.absolute.path;

  final modelsPath = p.normalize(p.join(projectRoot, args['models'] as String));

  print('');
  print('API Model Field Scanner');
  print('=======================');
  print('');
  print('Project: $projectRoot');
  print('Models:  $modelsPath');
  print('');

  final fields = await findModelFields(projectRoot: projectRoot, modelsPath: modelsPath);

  print('Found ${fields.length} model fields.');
  print('');

  final server = DartLanguageServer();

  try {
    print('Starting Dart language server...');

    await server.start(projectRoot);

    print('Dart language server ready.');
    print('');

    final unused = <ModelField>[];

    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];

      stdout.write(
        '\rScanning '
        '${i + 1}/${fields.length}: '
        '${field.className}.${field.fieldName}'
        '                    ',
      );

      try {
        final references = await server.findReferences(
          filePath: field.filePath,
          line: field.line,
          character: field.column,
        );

        final externalReferences = references
            .where((reference) => !isInsideModelFile(reference, field))
            .toList();

        if (externalReferences.isEmpty) {
          unused.add(field);
        }
      } catch (e) {
        stderr.writeln(
          '\nFailed to inspect '
          '${field.className}.${field.fieldName}: $e',
        );
      }
    }

    print('\n');

    if (unused.isEmpty) {
      print('No unused model fields found.');
      return;
    }

    print(
      'Potentially unused model fields: '
      '${unused.length}',
    );
    print('');

    String? currentClass;

    for (final field in unused) {
      if (currentClass != field.className) {
        currentClass = field.className;

        print('');
        print('${field.className}:');
      }

      print(
        '  - ${field.fieldName}'
        ' (${p.relative(field.filePath, from: projectRoot)}'
        ':${field.line + 1})',
      );
    }

    print('');
  } finally {
    await server.shutdown();
  }
}
