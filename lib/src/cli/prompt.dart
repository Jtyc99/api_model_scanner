import 'dart:io';

/// ANSI helpers.
const _hideCursor = '\x1b[?25l';
const _showCursor = '\x1b[?25h';
const _clearLine = '\x1b[2K';
const _dim = '\x1b[2m';
const _cyan = '\x1b[36m';
const _reset = '\x1b[0m';

/// Whether an interactive prompt can be shown.
///
/// Requires both a terminal to draw on and a keyboard to read from, so piped
/// or CI invocations fall back to an explicit default instead of hanging.
bool get canPrompt => stdout.hasTerminal && stdin.hasTerminal;

/// The pure key-handling half of [selectSingle].
///
/// Kept free of any IO so the navigation logic — including multi-byte arrow
/// escape sequences, which arrive one byte at a time — can be tested without
/// a terminal.
class SelectionState {
  final int length;
  final int defaultIndex;

  int current;
  bool done = false;
  bool cancelled = false;

  /// Tracks how much of an `ESC [ X` sequence has been consumed.
  int _escape = 0;

  SelectionState(this.length, {this.defaultIndex = 0})
      : current = defaultIndex.clamp(0, length - 1);

  void _up() => current = (current - 1 + length) % length;
  void _down() => current = (current + 1) % length;

  /// Feeds one byte. Returns true when the selection is finished.
  bool feed(int byte) {
    if (_escape == 1) {
      // Expecting '[' (CSI).
      _escape = byte == 0x5b ? 2 : 0;
      return done;
    }

    if (_escape == 2) {
      _escape = 0;
      if (byte == 0x41) {
        _up();
      } else if (byte == 0x42) {
        _down();
      }
      return done;
    }

    switch (byte) {
      case -1: // stdin closed
      case 3: // Ctrl-C
      case 113: // q
        current = defaultIndex;
        cancelled = true;
        done = true;

      case 10: // LF
      case 13: // CR
        done = true;

      case 107: // k
        _up();

      case 106: // j
        _down();

      case 27: // ESC — may begin an arrow sequence
        _escape = 1;
    }

    return done;
  }
}

/// Presents [options] as an arrow-key driven single-select list and returns
/// the index of the chosen entry.
///
/// Up/Down (or k/j) move, Enter confirms, q or Ctrl-C cancels and returns
/// [defaultIndex]. When no terminal is attached this returns [defaultIndex]
/// immediately without drawing anything.
int selectSingle(
  String prompt,
  List<String> options, {
  int defaultIndex = 0,
}) {
  if (options.isEmpty || !canPrompt) {
    return defaultIndex;
  }

  final state = SelectionState(options.length, defaultIndex: defaultIndex);

  stdout.writeln(prompt);
  stdout.write(_hideCursor);

  void draw() {
    for (var i = 0; i < options.length; i++) {
      final selected = i == state.current;
      final pointer = selected ? '$_cyan❯$_reset ' : '  ';
      final label = selected ? '$_cyan${options[i]}$_reset' : options[i];
      stdout.writeln('$_clearLine$pointer$label');
    }
  }

  /// Move the cursor back up over the list so it can be redrawn in place.
  void rewind() => stdout.write('\x1b[${options.length}A');

  final previousEcho = stdin.echoMode;
  final previousLine = stdin.lineMode;

  // lineMode must be disabled before echoMode on some terminals.
  stdin.lineMode = false;
  stdin.echoMode = false;

  try {
    draw();
    while (!state.feed(stdin.readByteSync())) {
      rewind();
      draw();
    }
  } finally {
    stdin.lineMode = previousLine;
    stdin.echoMode = previousEcho;
    stdout.write(_showCursor);
  }

  // Redraw once more so the final choice is the one left on screen.
  rewind();
  draw();

  stdout.writeln('$_dim  → ${options[state.current]}$_reset');
  stdout.writeln();

  return state.current;
}

/// Asks for a line of text and returns it trimmed, or null if nothing usable
/// was given.
///
/// Returns null immediately when no terminal is attached, for the same reason
/// [selectSingle] falls back to its default: a prompt that waited on stdin
/// anyway would hang an unattended run rather than fail it.
///
/// Line mode is restored around the read because [selectSingle] leaves the
/// terminal raw while it draws, and a wizard alternates between the two.
String? promptLine(String prompt) {
  if (!canPrompt) {
    return null;
  }

  final previousEcho = stdin.echoMode;
  final previousLine = stdin.lineMode;

  stdin.lineMode = true;
  stdin.echoMode = true;

  try {
    stdout.write('$prompt ');
    final answer = stdin.readLineSync()?.trim();
    return answer == null || answer.isEmpty ? null : answer;
  } finally {
    stdin.lineMode = previousLine;
    stdin.echoMode = previousEcho;
  }
}
