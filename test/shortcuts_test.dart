import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/player/shortcuts.dart';

void main() {
  group('KeyBinding equality', () {
    test('matches on key and modifiers together', () {
      expect(
        const KeyBinding(LogicalKeyboardKey.keyF),
        const KeyBinding(LogicalKeyboardKey.keyF),
      );
      expect(
        const KeyBinding(LogicalKeyboardKey.keyF),
        isNot(const KeyBinding(LogicalKeyboardKey.keyF, meta: true)),
      );
      expect(
        const KeyBinding(LogicalKeyboardKey.arrowLeft, shift: true),
        isNot(const KeyBinding(LogicalKeyboardKey.arrowLeft)),
      );
    });

    test('hashes consistently so map lookup works', () {
      const a = KeyBinding(LogicalKeyboardKey.keyO, meta: true);
      const b = KeyBinding(LogicalKeyboardKey.keyO, meta: true);

      expect(a.hashCode, b.hashCode);
      expect({a: 1}[b], 1);
    });
  });

  group('default bindings', () {
    test('no binding is defined twice', () {
      // A duplicate key would silently shadow whichever entry came first.
      final seen = <KeyBinding>{};
      for (final binding in PlayerShortcuts.defaults.keys) {
        expect(seen.add(binding), isTrue,
            reason: 'duplicate binding: ${binding.describe(isMacOS: false)}');
      }
    });

    test('every action in the help sheet has a binding', () {
      for (final group in PlayerShortcuts.helpGroups.values) {
        for (final (action, label) in group) {
          expect(PlayerShortcuts.bindingFor(action), isNotNull,
              reason: '"$label" is listed in help but has no key');
        }
      }
    });

    test('space and the arrows are bound to the expected actions', () {
      expect(
        PlayerShortcuts.defaults[const KeyBinding(LogicalKeyboardKey.space)],
        PlayerAction.playPause,
      );
      expect(
        PlayerShortcuts
            .defaults[const KeyBinding(LogicalKeyboardKey.arrowLeft)],
        PlayerAction.seekBack,
      );
      expect(
        PlayerShortcuts.defaults[
            const KeyBinding(LogicalKeyboardKey.arrowRight, shift: true)],
        PlayerAction.seekForwardLong,
      );
    });

    test('open file is bound for both macOS and non-macOS modifiers', () {
      expect(
        PlayerShortcuts
            .defaults[const KeyBinding(LogicalKeyboardKey.keyO, meta: true)],
        PlayerAction.openFile,
      );
      expect(
        PlayerShortcuts
            .defaults[const KeyBinding(LogicalKeyboardKey.keyO, control: true)],
        PlayerAction.openFile,
      );
    });

    test('plain letter keys carry no modifiers', () {
      // A bare letter binding must not accidentally require a modifier,
      // or it would never fire during normal playback.
      for (final entry in PlayerShortcuts.defaults.entries) {
        final b = entry.key;
        if (entry.value == PlayerAction.openFile) continue;
        expect(b.control || b.alt || b.meta, isFalse,
            reason: '${b.describe(isMacOS: false)} needs a modifier');
      }
    });
  });

  group('describe', () {
    test('uses symbols on macOS', () {
      expect(
        const KeyBinding(LogicalKeyboardKey.keyO, meta: true)
            .describe(isMacOS: true),
        '⌘O',
      );
      expect(
        const KeyBinding(LogicalKeyboardKey.arrowLeft, shift: true)
            .describe(isMacOS: true),
        '⇧←',
      );
    });

    test('uses words elsewhere', () {
      expect(
        const KeyBinding(LogicalKeyboardKey.keyO, control: true)
            .describe(isMacOS: false),
        'Ctrl+O',
      );
      expect(
        const KeyBinding(LogicalKeyboardKey.arrowLeft, shift: true)
            .describe(isMacOS: false),
        'Shift+←',
      );
    });

    test('names special keys readably', () {
      expect(
        const KeyBinding(LogicalKeyboardKey.space).describe(isMacOS: true),
        'Space',
      );
      expect(
        const KeyBinding(LogicalKeyboardKey.bracketRight)
            .describe(isMacOS: true),
        ']',
      );
    });
  });

  group('step sizes', () {
    test('long seek is larger than short seek', () {
      expect(ShortcutSteps.longSeek, greaterThan(ShortcutSteps.shortSeek));
    });

    test('a frame step is under a tenth of a second', () {
      expect(ShortcutSteps.frame.inMilliseconds, lessThan(100));
    });
  });
}
