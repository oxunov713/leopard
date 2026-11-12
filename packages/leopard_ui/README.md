# leopard_ui

Shared visual design of Leopard (dark only): colour tokens, the Material 3
theme, bundled fonts and the icon set. Used by `apps/mobile` and `apps/web`.

```dart
import 'package:leopard_ui/leopard_ui.dart';

MaterialApp(theme: leopardTheme(desktop: false)); // Android
MaterialApp(theme: leopardTheme(desktop: true));  // web: denser, smaller radii
```

## Tokens (`LeopardColors`)

| Token | Value | Use |
| --- | --- | --- |
| `background` | `#0E0E10` | page / scaffold |
| `surface` | `#17171A` | cards, sheets, dialogs |
| `surfaceHigh` | `#1F1F23` | inputs, raised surfaces |
| `sidebar` | `#121214` | navigation bar / rail |
| `divider` | `#26262B` | dividers |
| `outline` | `#2E2E34` | card and input borders |
| `outlineStrong` | `#3A3A41` | outlined buttons, scheme outline |
| `text` | `#ECE8E1` | primary text |
| `textMuted` | `#A09C94` | secondary text |
| `textSoft` | `#D6D2CA` | softer body text |
| `primary` | `#E8743B` | accent |
| `onPrimary` | `#1A0D06` | text on the accent |
| `primaryContainer` | `#3D2519` | selected indicator |
| `markTile` | `#17140F` | tile behind the mark (launcher, favicon) |
| `ok` | `#86C29A` | success |
| `danger` | `#E5776B` | errors |

Item type tints (`LeopardTypeTint.of(type)`, background / foreground):
login `#2C1D16` / `#E8743B`, card `#16212A` / `#7FB8E8`, wifi `#172A22` /
`#86C29A`, apiKey `#241A2C` / `#C9A2E8`, sshKey `#2A1C18` / `#E8957F`,
secureNote `#24231A` / `#E0D27A`.

Radii: cards 20 (web 16), chips 10, inputs and buttons 28 (web 10), FAB 18
(web 14).

## Fonts

Inter (body), Space Grotesk (headings), JetBrains Mono (secrets, codes) are
bundled as variable TTFs in `assets/fonts` (SIL OFL, licences next to them).
Nothing is fetched at runtime. From app code use the family names in
`LeopardFonts` (`packages/leopard_ui/...`), or `leopardSecretTextStyle` for a
password or code.

## Icons

```dart
LeopardIcon(LeopardIcons.copy, size: 20, color: LeopardColors.textMuted)
ItemTypeIcon(LeopardItemType.card, size: 48) // tinted rounded square
LeopardMark(size: 28)                        // brand mark
```

`LeopardItemType.fromTypeName(item.type)` maps `leopard_core`'s
`VaultItem.type` string to the enum. Icons are 24-unit SVGs in
`assets/icons` with `currentColor` strokes, tinted through a `colorFilter`.
To add one, put the SVG there and add a constant to `LeopardIcons` (and to
`LeopardIcons.all`).
