import 'package:api_model_scanner/src/model_field_fixer.dart';
import 'package:test/test.dart';

const _homeBanner = '''
class HomeBanner {
  final String? desktop;
  final String? mobile;
  final String? alt;
  final num? id;

  const HomeBanner({
    this.desktop,
    this.mobile,
    this.alt,
    this.id,
  });

  factory HomeBanner.fromJson(Map<String, dynamic> json) {
    return HomeBanner(
      desktop: json['desktop']?.toString(),
      mobile: json['mobile']?.toString(),
      alt: json['alt']?.toString(),
      id: json['id'] as num?,
    );
  }

  Map<String, dynamic> toJson() => {
        if (desktop != null) 'desktop': desktop,
        if (mobile != null) 'mobile': mobile,
        if (alt != null) 'alt': alt,
        if (id != null) 'id': id,
      };

  HomeBanner copyWith({String? desktop, String? mobile, String? alt, num? id}) {
    return HomeBanner(
      desktop: desktop ?? this.desktop,
      mobile: mobile ?? this.mobile,
      alt: alt ?? this.alt,
      id: id ?? this.id,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(other, this) ||
      other is HomeBanner &&
          other.desktop == desktop &&
          other.mobile == mobile &&
          other.alt == alt &&
          other.id == id;

  @override
  int get hashCode =>
      desktop.hashCode ^ mobile.hashCode ^ alt.hashCode ^ id.hashCode;
}
''';

void main() {
  test('removes a single unused field from every model construct', () {
    final result = ModelFieldFixer.removeFields(
      content: _homeBanner,
      path: 'home_banner.dart',
      className: 'HomeBanner',
      fieldNames: {'desktop'},
    );

    expect(result.error, isNull);
    expect(result.changed, isTrue);
    expect(result.removedFields, contains('desktop'));

    final out = result.newContent;
    // No trace of `desktop` should remain anywhere.
    expect(out.contains('desktop'), isFalse, reason: out);
    // Kept fields survive.
    expect(out.contains('mobile'), isTrue);
    expect(out.contains('alt'), isTrue);
    expect(out.contains('id'), isTrue);
  });

  test('removes multiple fields at once', () {
    final result = ModelFieldFixer.removeFields(
      content: _homeBanner,
      path: 'home_banner.dart',
      className: 'HomeBanner',
      fieldNames: {'desktop', 'alt', 'id'},
    );

    final out = result.newContent;
    expect(out.contains('desktop'), isFalse, reason: out);
    expect(out.contains('alt'), isFalse, reason: out);
    // `id` appears only inside removed constructs; ensure it's gone.
    expect(RegExp(r'\bid\b').hasMatch(out), isFalse, reason: out);
    // The one field we keep is still fully present.
    expect(out.contains('mobile'), isTrue);
    expect(out.contains('other.mobile == mobile'), isTrue);
    expect(out.contains('mobile.hashCode'), isTrue);
  });

  test('output still parses and keeps balanced structure', () {
    final result = ModelFieldFixer.removeFields(
      content: _homeBanner,
      path: 'home_banner.dart',
      className: 'HomeBanner',
      fieldNames: {'desktop', 'alt'},
    );
    final out = result.newContent;
    // Sanity: braces/parens remain balanced after edits.
    expect(_balanced(out, '{', '}'), isTrue);
    expect(_balanced(out, '(', ')'), isTrue);
    // The equality chain must not start or end with a dangling `&&`.
    expect(out.contains('&& &&'), isFalse);
    expect(RegExp(r'&&\s*;').hasMatch(out), isFalse);
    // The hashCode chain must not have a dangling `^`.
    expect(RegExp(r'\^\s*;').hasMatch(out), isFalse);
    expect(out.contains('^ ^'), isFalse);
  });

  test('unknown class is reported, not silently ignored', () {
    final result = ModelFieldFixer.removeFields(
      content: _homeBanner,
      path: 'home_banner.dart',
      className: 'NotHere',
      fieldNames: {'desktop'},
    );
    expect(result.changed, isFalse);
    expect(result.error, isNotNull);
  });

  test('non-existent field leaves file unchanged', () {
    final result = ModelFieldFixer.removeFields(
      content: _homeBanner,
      path: 'home_banner.dart',
      className: 'HomeBanner',
      fieldNames: {'nope'},
    );
    expect(result.changed, isFalse);
    expect(result.newContent, _homeBanner);
  });
}

bool _balanced(String s, String open, String close) {
  var depth = 0;
  for (final ch in s.split('')) {
    if (ch == open) depth++;
    if (ch == close) depth--;
    if (depth < 0) return false;
  }
  return depth == 0;
}
