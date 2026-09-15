import 'package:api_model_scanner/src/cli/prompt.dart';
import 'package:test/test.dart';

/// Feeds a byte sequence into a fresh [SelectionState] and returns it.
SelectionState run(List<int> bytes, {int length = 2, int defaultIndex = 0}) {
  final state = SelectionState(length, defaultIndex: defaultIndex);
  for (final byte in bytes) {
    if (state.feed(byte)) break;
  }
  return state;
}

/// Arrow keys arrive as three separate bytes: ESC, '[', then 'A'/'B'.
const arrowUp = [27, 0x5b, 0x41];
const arrowDown = [27, 0x5b, 0x42];
const enter = [13];

void main() {
  test('Enter alone confirms the default option', () {
    final state = run([...enter]);
    expect(state.current, 0);
    expect(state.done, isTrue);
    expect(state.cancelled, isFalse);
  });

  test('Down then Enter selects the second option', () {
    final state = run([...arrowDown, ...enter]);
    expect(state.current, 1);
    expect(state.done, isTrue);
  });

  test('Up from the first option wraps to the last', () {
    final state = run([...arrowUp, ...enter], length: 3);
    expect(state.current, 2);
  });

  test('Down past the last option wraps to the first', () {
    final state = run([...arrowDown, ...arrowDown, ...enter]);
    expect(state.current, 0);
  });

  test('j and k navigate like Down and Up', () {
    expect(run([106, ...enter]).current, 1); // j
    expect(run([106, 107, ...enter]).current, 0); // j then k
  });

  test('Ctrl-C cancels and falls back to the default', () {
    final state = run([...arrowDown, 3], defaultIndex: 0);
    expect(state.current, 0);
    expect(state.cancelled, isTrue);
    expect(state.done, isTrue);
  });

  test('q cancels and falls back to the default', () {
    final state = run([...arrowDown, 113], defaultIndex: 0);
    expect(state.current, 0);
    expect(state.cancelled, isTrue);
  });

  test('a non-default starting index is honoured', () {
    final state = run([...enter], length: 3, defaultIndex: 2);
    expect(state.current, 2);
  });

  test('a bare ESC that is not an arrow sequence does not move', () {
    // ESC followed by something other than '[' resets the escape state.
    final state = run([27, 0x5a, ...enter]);
    expect(state.current, 0);
  });

  test('partial escape bytes are not treated as navigation', () {
    // ESC and '[' alone should leave the selection untouched.
    final state = run([27, 0x5b, ...enter]);
    // The Enter byte (13) is consumed as the arrow's final byte, so the
    // selection is still open and unmoved.
    expect(state.current, 0);
    expect(state.done, isFalse);
  });

  test('LF confirms as well as CR', () {
    final state = run([...arrowDown, 10]);
    expect(state.current, 1);
    expect(state.done, isTrue);
  });

  test('repeated navigation lands on the expected option', () {
    final state = run([
      ...arrowDown,
      ...arrowDown,
      ...arrowDown,
      ...arrowUp,
      ...enter,
    ], length: 4);
    expect(state.current, 2);
  });
}
