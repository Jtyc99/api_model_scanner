import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model.dart';

/// A thin LSP client that drives `dart language-server` over stdio.
///
/// LSP messages are framed with a `Content-Length` header and are *not*
/// line-delimited JSON, so stdout is consumed as raw bytes and each message
/// body is sliced out by its declared byte length.
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
      onDone: () {},
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
        {
          'uri': Uri.file(projectRoot).toString(),
          'name': p.basename(projectRoot),
        },
      ],
      'capabilities': {
        'workspace': {
          'applyEdit': false,
          'workspaceFolders': true,
          'configuration': false,
        },
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
    // Content-Length is measured in UTF-8 bytes, not Dart string length.
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
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
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
