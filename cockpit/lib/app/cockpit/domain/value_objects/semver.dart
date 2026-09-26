/// Comparação de versões semver `x.y.z[-pre][+build]` — numérica por componente.
///
/// Ordem do semver §11: decide pelos três componentes numéricos; empate no core
/// → a versão **sem** pré-release é maior (`1.5.11` > `1.5.11-beta.1`); ambas com
/// pré-release → identificador por identificador (numérico compara como número e
/// é menor que alfanumérico; mais identificadores desempata pra cima:
/// `1.0.0-beta` < `1.0.0-beta.1`). Build metadata (`+…`) é ignorado.
///
/// Componentes ausentes contam como 0 (`1.2` == `1.2.0`); não-numéricos contam
/// como 0.
library;

class _Version {
  const _Version(this.core, this.pre);

  final List<int> core;

  /// Identificadores de pré-release; `null` = versão final.
  final List<String>? pre;
}

_Version _parse(String raw) {
  final withoutBuild = raw.trim().split('+').first;
  final dash = withoutBuild.indexOf('-');
  final coreText = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
  final parts = coreText.split('.');
  final core = List<int>.generate(3, (i) {
    if (i >= parts.length) return 0;
    return int.tryParse(parts[i].trim()) ?? 0;
  });
  if (dash < 0) return _Version(core, null);
  final pre = withoutBuild.substring(dash + 1).split('.');
  // `1.0.0-` (pré-release vazio) é malformado: trata como versão final.
  return _Version(core, pre.isEmpty || pre.first.isEmpty ? null : pre);
}

int _comparePreRelease(List<String> a, List<String> b) {
  final shared = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < shared; i++) {
    final c = _compareIdentifier(a[i], b[i]);
    if (c != 0) return c;
  }
  if (a.length == b.length) return 0;
  return a.length < b.length ? -1 : 1;
}

int _compareIdentifier(String a, String b) {
  final na = int.tryParse(a);
  final nb = int.tryParse(b);
  if (na != null && nb != null) {
    if (na == nb) return 0;
    return na < nb ? -1 : 1;
  }
  // Identificador numérico tem precedência MENOR que o alfanumérico.
  if (na != null) return -1;
  if (nb != null) return 1;
  return a.compareTo(b);
}

/// `-1` se [a] < [b], `0` se iguais, `1` se [a] > [b].
int compareSemver(String a, String b) {
  final va = _parse(a);
  final vb = _parse(b);
  for (var i = 0; i < 3; i++) {
    if (va.core[i] != vb.core[i]) return va.core[i] < vb.core[i] ? -1 : 1;
  }
  final pa = va.pre;
  final pb = vb.pre;
  if (pa == null && pb == null) return 0;
  if (pa == null) return 1; // versão final > pré-release do mesmo core
  if (pb == null) return -1;
  return _comparePreRelease(pa, pb);
}

/// `true` se [candidate] é uma versão **maior** que [current].
bool isNewerVersion(String candidate, String current) =>
    compareSemver(candidate, current) > 0;
