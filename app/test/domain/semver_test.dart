import 'package:app/domain/value_objects/semver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compareSemver', () {
    test('equal versions → 0', () {
      expect(compareSemver('1.1.0', '1.1.0'), 0);
    });

    test('greater major/minor/patch → 1', () {
      expect(compareSemver('2.0.0', '1.9.9'), 1);
      expect(compareSemver('1.2.0', '1.1.9'), 1);
      expect(compareSemver('1.1.1', '1.1.0'), 1);
    });

    test('smaller → -1', () {
      expect(compareSemver('1.0.0', '1.0.1'), -1);
      expect(compareSemver('1.9.9', '2.0.0'), -1);
    });

    test('numeric per-component (not lexical) — 1.10.0 > 1.9.0', () {
      expect(compareSemver('1.10.0', '1.9.0'), 1);
    });

    test('missing components count as 0 (1.2 == 1.2.0)', () {
      expect(compareSemver('1.2', '1.2.0'), 0);
    });

    test('build metadata is ignored', () {
      expect(compareSemver('1.1.0+5', '1.1.0'), 0);
      expect(compareSemver('1.1.0+5', '1.1.0+9'), 0);
    });

    test('non-numeric components count as 0', () {
      expect(compareSemver('x.y.z', '0.0.0'), 0);
    });

    group('pre-release (semver §11)', () {
      test('a final version outranks its own pre-releases', () {
        expect(compareSemver('1.1.0', '1.1.0-beta'), 1);
        expect(compareSemver('1.1.0-beta', '1.1.0'), -1);
        expect(compareSemver('1.1.0-beta.2', '1.1.0'), -1);
      });

      test('a pre-release of a higher core still outranks the previous release', () {
        expect(compareSemver('1.5.11-beta.1', '1.5.10'), 1);
        expect(compareSemver('1.5.11-beta.1', '1.5.11-alpha.9'), 1);
      });

      test('identifiers compare numerically, then alphabetically', () {
        expect(compareSemver('1.1.0-beta.2', '1.1.0-beta.10'), -1);
        expect(compareSemver('1.1.0-beta.b', '1.1.0-beta.a'), 1);
        // numeric identifiers rank below alphanumeric ones
        expect(compareSemver('1.1.0-beta.2', '1.1.0-beta.alpha'), -1);
      });

      test('more identifiers win when the shared prefix ties', () {
        expect(compareSemver('1.1.0-beta.1', '1.1.0-beta'), 1);
        expect(compareSemver('1.1.0-beta', '1.1.0-beta.1'), -1);
      });

      test('a malformed empty pre-release reads as final', () {
        expect(compareSemver('1.1.0-', '1.1.0'), 0);
      });
    });
  });

  group('isNewerVersion', () {
    test('true only when candidate is strictly greater', () {
      expect(isNewerVersion('1.2.0', '1.1.0'), isTrue);
      expect(isNewerVersion('1.1.0', '1.1.0'), isFalse);
      expect(isNewerVersion('1.0.0', '1.1.0'), isFalse);
    });

    test('a beta of the next core prompts, the final of the same core prompts again', () {
      expect(isNewerVersion('1.5.11-beta.1', '1.5.10'), isTrue);
      expect(isNewerVersion('1.5.11', '1.5.11-beta.1'), isTrue);
      expect(isNewerVersion('1.5.11-beta.1', '1.5.11'), isFalse);
    });
  });
}
