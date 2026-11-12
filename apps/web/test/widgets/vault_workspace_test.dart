// The three-pane vault and its keyboard shortcuts.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_ui/leopard_ui.dart';
import 'package:leopard_web/core/security/password_handoff.dart';
import 'package:leopard_web/core/security/secret_clipboard.dart';
import 'package:leopard_web/features/vault/domain/vault_repository.dart';
import 'package:leopard_web/features/vault/presentation/item_detail_page.dart'
    show describeAge;
import 'package:leopard_web/features/vault/presentation/vault_cubit.dart';
import 'package:leopard_web/features/vault/presentation/vault_workspace.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';

void main() {
  late MockVaultRepository repository;
  late MockSecretClipboard clipboard;
  late VaultCubit cubit;

  setUpAll(() => registerFallbackValue(login('fallback')));

  setUp(() {
    repository = MockVaultRepository();
    clipboard = MockSecretClipboard();
    when(() => clipboard.copy(any())).thenAnswer((_) async {});
    when(clipboard.clearNow).thenAnswer((_) async {});
    when(() => repository.sync()).thenAnswer(
      (_) async => SyncDelta(
        upserts: [
          entry(
            itemIdA,
            login('Alpha', username: 'alice', password: 'pass-alpha'),
          ),
          entry(
            itemIdB,
            login('Bravo', username: 'bob', password: 'pass-bravo'),
          ),
          entry(
            itemIdC,
            login('Charlie', username: 'carol', password: 'pass-charlie'),
          ),
        ],
        deletedIds: const {},
        unreadableIds: const {},
        serverTime: '2026-11-11T10:00:10Z',
      ),
    );
    cubit = VaultCubit(repository);
    addTearDown(cubit.close);
  });

  Future<void> pumpWorkspace(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await cubit.load();
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SecretClipboard>.value(value: clipboard),
          RepositoryProvider<PasswordHandoff>.value(value: PasswordHandoff()),
        ],
        child: BlocProvider<VaultCubit>.value(
          value: cubit,
          child: MaterialApp(
            theme: leopardTheme(desktop: true),
            home: const Scaffold(body: VaultWorkspace()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> chord(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool meta = false,
  }) async {
    final modifier = meta
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  String? openTitle(WidgetTester tester) {
    final title = find.byKey(const Key('item-title'));
    return title.evaluate().isEmpty ? null : tester.widget<Text>(title).data;
  }

  FocusNode searchFocus(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('vault-search')))
      .focusNode!;

  testWidgets('three panes: list, an empty detail, and search hint', (
    tester,
  ) async {
    await pumpWorkspace(tester);

    expect(find.byKey(Key('entry-$itemIdA')), findsOneWidget);
    expect(find.byKey(Key('entry-$itemIdC')), findsOneWidget);
    expect(find.text('Select an item'), findsOneWidget);
    expect(find.text('Ctrl K'), findsOneWidget);
  });

  testWidgets('clicking a row opens it in the right pane', (tester) async {
    await pumpWorkspace(tester);

    await tester.tap(find.byKey(Key('entry-$itemIdB')));
    await tester.pump();

    expect(openTitle(tester), 'Bravo');
    expect(find.byKey(const Key('field-password')), findsOneWidget);
    // The password is masked until revealed.
    expect(find.text('pass-bravo'), findsNothing);
  });

  testWidgets('Ctrl+K focuses the search; Cmd+K too', (tester) async {
    await pumpWorkspace(tester);
    expect(searchFocus(tester).hasFocus, isFalse);

    await chord(tester, LogicalKeyboardKey.keyK);
    expect(searchFocus(tester).hasFocus, isTrue);

    await tester.tap(find.byKey(Key('entry-$itemIdA')));
    await tester.pump();
    searchFocus(tester).unfocus();
    await tester.pump();
    expect(searchFocus(tester).hasFocus, isFalse);

    await chord(tester, LogicalKeyboardKey.keyK, meta: true);
    expect(searchFocus(tester).hasFocus, isTrue);
  });

  testWidgets('arrow keys move the selection and open the item', (
    tester,
  ) async {
    await pumpWorkspace(tester);
    expect(openTitle(tester), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(openTitle(tester), 'Alpha');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(openTitle(tester), 'Bravo');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // The last row stays selected.
    expect(openTitle(tester), 'Charlie');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(openTitle(tester), 'Bravo');
  });

  testWidgets('arrow keys work from the search field too', (tester) async {
    await pumpWorkspace(tester);
    await chord(tester, LogicalKeyboardKey.keyK);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(openTitle(tester), 'Alpha');
    expect(searchFocus(tester).hasFocus, isTrue);
  });

  testWidgets('Ctrl+C copies the password of the selected item through the '
      'clipboard service; Ctrl+B the username', (tester) async {
    await pumpWorkspace(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(openTitle(tester), 'Bravo');

    await chord(tester, LogicalKeyboardKey.keyC);
    verify(() => clipboard.copy('pass-bravo')).called(1);

    await chord(tester, LogicalKeyboardKey.keyB);
    verify(() => clipboard.copy('bob')).called(1);

    await chord(tester, LogicalKeyboardKey.keyC, meta: true);
    verify(() => clipboard.copy('pass-bravo')).called(1);
    verifyNoMoreInteractions(clipboard);
  });

  testWidgets('Ctrl+C does nothing without a selection', (tester) async {
    await pumpWorkspace(tester);
    await chord(tester, LogicalKeyboardKey.keyC);
    verifyNever(() => clipboard.copy(any()));
  });

  testWidgets('Ctrl+C in a focused text field keeps its normal behaviour', (
    tester,
  ) async {
    await pumpWorkspace(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(openTitle(tester), 'Alpha');

    await tester.tap(find.byKey(const Key('vault-search')));
    await tester.pump();
    expect(searchFocus(tester).hasFocus, isTrue);

    await chord(tester, LogicalKeyboardKey.keyC);
    await chord(tester, LogicalKeyboardKey.keyB);
    verifyNever(() => clipboard.copy(any()));
  });

  testWidgets('the copy buttons use the clipboard service too', (tester) async {
    await pumpWorkspace(tester);
    await tester.tap(find.byKey(Key('entry-$itemIdA')));
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('field-password')),
        matching: find.text('Copy'),
      ),
    );
    await tester.pump();
    verify(() => clipboard.copy('pass-alpha')).called(1);
    // The 30 s notice appears.
    expect(find.textContaining('cleared in 30 seconds'), findsOneWidget);
  });

  testWidgets('the search filters; Escape clears it', (tester) async {
    await pumpWorkspace(tester);
    await tester.enterText(find.byKey(const Key('vault-search')), 'bra');
    await tester.pump();
    expect(find.byKey(Key('entry-$itemIdA')), findsNothing);
    expect(find.byKey(Key('entry-$itemIdB')), findsOneWidget);
    expect(cubit.state.query, 'bra');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(cubit.state.query, isEmpty);
    expect(find.byKey(Key('entry-$itemIdA')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('vault-search')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('Enter in the search opens the first match', (tester) async {
    await pumpWorkspace(tester);
    await tester.enterText(find.byKey(const Key('vault-search')), 'char');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(openTitle(tester), 'Charlie');
    expect(searchFocus(tester).hasFocus, isFalse);
  });

  testWidgets('Edit opens the editor in the right pane; Escape closes it', (
    tester,
  ) async {
    await pumpWorkspace(tester);
    await tester.tap(find.byKey(Key('entry-$itemIdA')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('item-edit')));
    await tester.pump();
    expect(find.byKey(const Key('item-save')), findsOneWidget);
    // The list is still there beside it.
    expect(find.byKey(Key('entry-$itemIdB')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('item-save')), findsNothing);
    expect(openTitle(tester), 'Alpha');
  });

  testWidgets('a new item is created in the pane and then selected', (
    tester,
  ) async {
    await pumpWorkspace(tester);
    when(() => repository.create(any())).thenAnswer(
      (invocation) async => entry(
        '5b1d3e0a-7a52-4c53-9a5e-3f3f4b6f2c11',
        invocation.positionalArguments.first as VaultItem,
      ),
    );

    await tester.tap(find.byKey(const Key('vault-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-login')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-title')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('edit-title')), 'Delta');
    await tester.tap(find.byKey(const Key('item-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('item-save')), findsNothing);
    expect(openTitle(tester), 'Delta');
  });

  testWidgets('a small window shows the list, then one item with a back '
      'button', (tester) async {
    await pumpWorkspace(tester, size: const Size(420, 900));
    expect(find.byKey(Key('entry-$itemIdA')), findsOneWidget);
    expect(find.text('Select an item'), findsNothing);

    await tester.tap(find.byKey(Key('entry-$itemIdA')));
    await tester.pump();
    expect(openTitle(tester), 'Alpha');
    expect(find.byKey(Key('entry-$itemIdB')), findsNothing);

    await tester.tap(find.byKey(const Key('pane-back')));
    await tester.pump();
    expect(find.byKey(Key('entry-$itemIdB')), findsOneWidget);
    expect(openTitle(tester), isNull);
  });

  test('describeAge', () {
    final now = DateTime.utc(2026, 11, 12, 12);
    String age(Duration d) => describeAge(now.subtract(d), now);
    expect(age(const Duration(seconds: 20)), 'just now');
    expect(age(const Duration(minutes: 5)), '5 min ago');
    expect(age(const Duration(hours: 3)), '3 h ago');
    expect(age(const Duration(hours: 30)), 'yesterday');
    expect(age(const Duration(days: 2, hours: 1)), '2 days ago');
    expect(age(const Duration(days: 45)), '2026-09-28');
  });
}
