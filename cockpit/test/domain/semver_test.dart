import 'package:cockpit/app/cockpit/domain/value_objects/semver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compareSemver', () {
    test('iguais → 0', () {
      expect(compareSemver('1.0.0', '1.0.0'), 0);
      expect(compareSemver('1.2', '1.2.0'), 0); // componente ausente = 0
    });

    test('maior/menor por componente (numérico, não lexical)', () {
      expect(compareSemver('1.0.10', '1.0.9'), 1); // 10 > 9 numérico
      expect(compareSemver('1.0.9', '1.0.10'), -1);
      expect(compareSemver('2.0.0', '1.9.9'), 1);
      expect(compareSemver('1.1.0', '1.0.99'), 1);
    });

    test('ignora build metadata', () {
      expect(compareSemver('1.0.1+5', '1.0.0'), 1);
      expect(compareSemver('1.0.0+5', '1.0.0+9'), 0);
    });

    test('componentes não-numéricos contam como 0', () {
      expect(compareSemver('1.x.0', '1.0.0'), 0);
    });

    group('pré-release (semver §11)', () {
      test('a versão final supera as próprias pré-releases', () {
        expect(compareSemver('1.0.0', '1.0.0-beta'), 1);
        expect(compareSemver('1.0.0-beta', '1.0.0'), -1);
        expect(compareSemver('1.0.0-beta.2', '1.0.0'), -1);
      });

      test('pré-release de core maior supera a release anterior', () {
        expect(compareSemver('1.5.11-beta.1', '1.5.10'), 1);
        expect(compareSemver('1.5.11-beta.1', '1.5.11-alpha.9'), 1);
      });

      test('identificadores comparam como número, depois alfabético', () {
        expect(compareSemver('1.0.0-beta.2', '1.0.0-beta.10'), -1);
        expect(compareSemver('1.0.0-beta.b', '1.0.0-beta.a'), 1);
        // identificador numérico vale MENOS que o alfanumérico
        expect(compareSemver('1.0.0-beta.2', '1.0.0-beta.alpha'), -1);
      });

      test('mais identificadores ganham quando o prefixo comum empata', () {
        expect(compareSemver('1.0.0-beta.1', '1.0.0-beta'), 1);
        expect(compareSemver('1.0.0-beta', '1.0.0-beta.1'), -1);
      });

      test('pré-release vazio (malformado) lê como final', () {
        expect(compareSemver('1.0.0-', '1.0.0'), 0);
      });
    });
  });

  group('isNewerVersion', () {
    test('só true quando candidato é estritamente maior', () {
      expect(isNewerVersion('1.1.0', '1.0.0'), isTrue);
      expect(isNewerVersion('1.0.0', '1.0.0'), isFalse); // igual
      expect(isNewerVersion('0.9.0', '1.0.0'), isFalse); // menor
      expect(isNewerVersion('1.0.10', '1.0.2'), isTrue);
    });

    test('a beta do próximo core avisa; a final do mesmo core avisa de novo', () {
      expect(isNewerVersion('1.5.11-beta.1', '1.5.10'), isTrue);
      expect(isNewerVersion('1.5.11', '1.5.11-beta.1'), isTrue);
      expect(isNewerVersion('1.5.11-beta.1', '1.5.11'), isFalse);
    });
  });
}
