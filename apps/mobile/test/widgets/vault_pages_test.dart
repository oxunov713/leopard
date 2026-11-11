import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leopard_core/leopard_core.dart';
import 'package:leopard_mobile/core/lock/app_lock_cubit.dart';
import 'package:leopard_mobile/features/vault/presentation/conflict_dialog.dart';
import 'package:leopard_mobile/features/vault/presentation/item_detail_page.dart';
import 'package:leopard_mobile/features/vault/presentation/item_edit_page.dart';
import 'package:leopard_mobile/features/vault/presentation/vault_cubit.dart';
import 'package:leopard_mobile/features/vault/presentation/vault_list_page.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fakes.dart';
import 'support.dart';

void main() {
  late MockVaultCubit vault;
  late MockAppLockCubit lock;
  final alpha = entry(
    itemIdA,
    login('Alpha', username: 'aziz', password: 'hunter2-hunter2'),
  );
  final bravo = entry(
    itemIdB,
    WifiItem(
      title: 'Bravo',
      ssid: 'home-5g',
      password: 'wifi-secret',
      createdAt: t0,
      updatedAt: t0,
    ),
  );

  setUpAll(() => registerFallbackValue(login('fallback')));

  setUp(() {
    vault = MockVaultCubit();
    lock = MockAppLockCubit();
    givenState(lock, const AppLockState(AppLockStatus.unlocked));
    when(vault.refresh).thenAnswer((_) async {});
    when(vault.load).thenAnswer((_) async {});
  });

  List<BlocProvider<dynamic>> providers() => [
    BlocProvider<VaultCubit>.value(value: vault),
    BlocProvider<AppLockCubit>.value(value: lock),
  ];

  group('VaultListPage', () {
    testWidgets('lists items with a non-secret subtitle', (tester) async {
      givenState(
        vault,
        VaultState(status: VaultStatus.ready, entries: [alpha, bravo]),
      );
      await pumpPage(tester, const VaultListPage(), providers: providers());

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('aziz'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('home-5g'), findsOneWidget);
      expect(find.textContaining('hunter2'), findsNothing);
      expect(find.textContaining('wifi-secret'), findsNothing);
    });

    testWidgets('search, filter, sync and lock reach the cubits', (
      tester,
    ) async {
      givenState(
        vault,
        VaultState(status: VaultStatus.ready, entries: [alpha, bravo]),
      );
      await pumpPage(tester, const VaultListPage(), providers: providers());

      await tester.enterText(find.byKey(const Key('vault-search')), 'alp');
      verify(() => vault.setQuery('alp')).called(1);

      await tester.tap(find.byKey(const Key('filter-${WifiItem.typeName}')));
      verify(() => vault.setTypeFilter(WifiItem.typeName)).called(1);

      await tester.tap(find.byKey(const Key('vault-sync')));
      verify(vault.refresh).called(1);

      await tester.tap(find.byKey(const Key('vault-lock')));
      verify(lock.lock).called(1);
    });

    testWidgets('only the filtered items are shown', (tester) async {
      givenState(
        vault,
        VaultState(
          status: VaultStatus.ready,
          entries: [alpha, bravo],
          typeFilter: WifiItem.typeName,
        ),
      );
      await pumpPage(tester, const VaultListPage(), providers: providers());
      expect(find.text('Alpha'), findsNothing);
      expect(find.text('Bravo'), findsWidgets);
    });

    testWidgets('warns about items that could not be decrypted', (
      tester,
    ) async {
      givenState(
        vault,
        VaultState(
          status: VaultStatus.ready,
          entries: [alpha],
          unreadableCount: 2,
        ),
      );
      await pumpPage(tester, const VaultListPage(), providers: providers());
      expect(
        find.textContaining('2 items on the server could not be decrypted'),
        findsOneWidget,
      );
    });

    testWidgets('load failure offers a retry', (tester) async {
      givenState(
        vault,
        const VaultState(
          status: VaultStatus.failure,
          error: 'Cannot reach the server. Check the connection.',
        ),
      );
      await pumpPage(tester, const VaultListPage(), providers: providers());
      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
      await tester.tap(find.byKey(const Key('vault-retry')));
      verify(vault.load).called(1);
    });
  });

  group('ItemDetailPage', () {
    testWidgets('secrets are masked, revealed on tap and hidden again', (
      tester,
    ) async {
      givenState(
        vault,
        VaultState(status: VaultStatus.ready, entries: [alpha]),
      );
      await pumpPage(
        tester,
        const ItemDetailPage(id: itemIdA),
        providers: providers(),
      );

      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('aziz'), findsOneWidget, reason: 'not a secret');
      expect(find.text('hunter2-hunter2'), findsNothing);

      await tester.tap(find.byKey(const Key('field-password')));
      await tester.pump();
      expect(find.text('hunter2-hunter2'), findsOneWidget);

      // Hides itself again after the timeout.
      await tester.pump(const Duration(seconds: 21));
      expect(find.text('hunter2-hunter2'), findsNothing);

      // And on a second tap.
      await tester.tap(find.byKey(const Key('field-password')));
      await tester.pump();
      expect(find.text('hunter2-hunter2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('field-password')));
      await tester.pump();
      expect(find.text('hunter2-hunter2'), findsNothing);
    });

    testWidgets('copy goes through the self-clearing clipboard', (
      tester,
    ) async {
      givenState(
        vault,
        VaultState(status: VaultStatus.ready, entries: [alpha]),
      );
      final clipboard = await pumpPage(
        tester,
        const ItemDetailPage(id: itemIdA),
        providers: providers(),
      );

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('field-password')),
          matching: find.byIcon(Icons.copy_outlined),
        ),
      );
      await tester.pump();

      verify(() => clipboard.copy('hunter2-hunter2')).called(1);
      expect(find.textContaining('cleared in 30 seconds'), findsOneWidget);
      // Copying does not reveal.
      expect(find.text('hunter2-hunter2'), findsNothing);
      // Let the snack bar finish.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('an item that vanished (deleted elsewhere) is handled', (
      tester,
    ) async {
      givenState(vault, const VaultState(status: VaultStatus.ready));
      await pumpPage(
        tester,
        const ItemDetailPage(id: itemIdA),
        providers: providers(),
      );
      expect(find.text('This item is no longer in the vault.'), findsOneWidget);
    });
  });

  group('ItemEditPage', () {
    testWidgets('a card has no CVV field and says so', (tester) async {
      givenState(vault, const VaultState(status: VaultStatus.ready));
      await pumpPage(
        tester,
        const ItemEditPage.create(type: CardItem.typeName),
        providers: providers(),
      );
      expect(find.byKey(const Key('edit-number')), findsOneWidget);
      expect(find.byKey(const Key('edit-cvv')), findsNothing);
      expect(find.byKey(const Key('edit-cvc')), findsNothing);
      expect(
        find.text('The security code (CVV) is never stored.'),
        findsOneWidget,
      );
    });

    testWidgets('secret inputs are hardened and pre-filled from the '
        'generator', (tester) async {
      givenState(vault, const VaultState(status: VaultStatus.ready));
      await pumpPage(
        tester,
        const ItemEditPage.create(
          type: LoginItem.typeName,
          initialPassword: 'generated-secret',
        ),
        providers: providers(),
      );
      final field = textFieldOf(tester, const Key('edit-password'));
      expect(field.controller!.text, 'generated-secret');
      expect(field.obscureText, isTrue);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.enableIMEPersonalizedLearning, isFalse);
      expect(field.autofillHints, isNull);
    });

    testWidgets('saving a new login builds the item and creates it', (
      tester,
    ) async {
      givenState(vault, const VaultState(status: VaultStatus.ready));
      when(() => vault.create(any())).thenAnswer((_) async => SaveResult.saved);
      await pumpPage(
        tester,
        const ItemEditPage.create(type: LoginItem.typeName),
        providers: providers(),
      );
      await tester.enterText(find.byKey(const Key('edit-title')), 'Example');
      await tester.enterText(find.byKey(const Key('edit-username')), 'aziz');
      await tester.enterText(find.byKey(const Key('edit-password')), 'pw 1');
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pump();

      final created =
          verify(() => vault.create(captureAny())).captured.single as LoginItem;
      expect(created.title, 'Example');
      expect(created.username, 'aziz');
      expect(created.password, 'pw 1');
    });

    testWidgets('a missing title is reported without calling the server', (
      tester,
    ) async {
      givenState(vault, const VaultState(status: VaultStatus.ready));
      await pumpPage(
        tester,
        const ItemEditPage.create(type: SecureNoteItem.typeName),
        providers: providers(),
      );
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pump();
      expect(find.text('Give the item a title.'), findsOneWidget);
      verifyNever(() => vault.create(any()));
    });
  });

  group('ConflictDialog', () {
    Future<ConflictChoice?> ask(
      WidgetTester tester,
      PendingConflict conflict,
      Key button,
    ) async {
      useTallSurface(tester);
      ConflictChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                choice = await showDialog<ConflictChoice>(
                  context: context,
                  builder: (_) => ConflictDialog(conflict: conflict),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(button));
      await tester.pumpAndSettle();
      return choice;
    }

    final conflict = PendingConflict(
      id: itemIdA,
      serverVersion: 4,
      mine: login('Alpha', password: 'my-secret-pw'),
      server: entry(itemIdA, login('Alpha (server)'), version: 4),
    );

    testWidgets('keep mine', (tester) async {
      expect(
        await ask(tester, conflict, const Key('conflict-keep-mine')),
        ConflictChoice.keepMine,
      );
    });

    testWidgets('take server', (tester) async {
      expect(
        await ask(tester, conflict, const Key('conflict-take-server')),
        ConflictChoice.takeServer,
      );
    });

    testWidgets('describes the server copy without showing secrets', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(home: ConflictDialog(conflict: conflict)),
      );
      expect(find.textContaining('Alpha (server)'), findsOneWidget);
      expect(find.textContaining('version 4'), findsOneWidget);
      expect(find.text('KEEP MINE'), findsOneWidget);
      expect(find.text('TAKE SERVER'), findsOneWidget);
      expect(find.textContaining('my-secret-pw'), findsNothing);
    });
  });
}
