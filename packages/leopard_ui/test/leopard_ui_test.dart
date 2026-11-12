import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_ui/leopard_ui.dart';

void main() {
  for (final desktop in [false, true]) {
    test('leopardTheme(desktop: $desktop) is a Material 3 dark theme', () {
      final theme = leopardTheme(desktop: desktop);
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.dark);
      expect(theme.colorScheme.primary, LeopardColors.primary);
      expect(theme.scaffoldBackgroundColor, LeopardColors.background);
      expect(
        theme.navigationBarTheme.indicatorColor,
        LeopardColors.primaryContainer,
      );
    });
  }

  test('every item type has a tint and round-trips its type name', () {
    for (final type in LeopardItemType.values) {
      expect(LeopardItemType.fromTypeName(type.typeName), type);
      expect(LeopardTypeTint.of(type).background, isNot(Colors.transparent));
    }
    expect(LeopardItemType.fromTypeName('nope'), isNull);
  });

  testWidgets('renders every icon, the mark and the item type tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: leopardTheme(desktop: false),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Wrap(
              children: [
                for (final icon in LeopardIcons.all)
                  LeopardIcon(icon, size: 24, color: Colors.white),
                const LeopardMark(size: 40),
                for (final type in LeopardItemType.values) ItemTypeIcon(type),
              ],
            ),
          ),
        ),
      ),
    );
    // Let the SVG assets load and parse.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(LeopardIcon), findsWidgets);
  });
}
