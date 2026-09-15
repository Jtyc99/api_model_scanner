import 'dart:io';

import 'package:api_model_scanner/api_model_scanner.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runCli(arguments);
}
