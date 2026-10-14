#!/usr/bin/env bash
#
# publish-pkg-branch.sh — 把 pi-remote/ 发布成「包根 = 分支根」的 pkg 分支
#
# 为什么需要它：pi 的 git 源不支持子目录（`git:…/remote_pi/pi-remote` 会被当成仓库路径），
# 而且只 clone、不构建（manifest 写的是 ./dist）。所以要让 pi 从 GitHub 加载这个扩展，
# 必须有一个分支，它的根目录正好是这个包 —— 内容就是 `npm pack` 出来的东西，
# 与 app-release.yml 在 tag 上发布的 remote-pi-*.tgz 完全一致。
#
#   scripts/publish-pkg-branch.sh              # 构建 + 打包 + force-push origin/pkg
#   scripts/publish-pkg-branch.sh --no-build   # 复用已有 dist（CI 里已经构建过）
#   scripts/publish-pkg-branch.sh --dry-run    # 只打印将推送的内容
#
# 分支与远端可用 PKG_BRANCH / PKG_REMOTE 覆盖。pi 侧对应源：
#   git:github.com/fenlyin0420/pi-remote@pkg
#
# 产物必须是构建后的 dist（不能只放 src）：src/bin/supervisord.ts 与
# src/daemon/install.ts 都从自身模块位置上溯找 dist/bin/supervisord.js 与
# dist/index.js，并用裸 node 起进程 —— 源码树会让 daemon/supervisor 直接断。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/pi-remote"
BRANCH="${PKG_BRANCH:-pkg}"
REMOTE="${PKG_REMOTE:-origin}"

BUILD=1
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "publish-pkg-branch: 未知参数 $arg" >&2
      exit 2
      ;;
  esac
done

command -v node >/dev/null || {
  echo "publish-pkg-branch: 需要 node" >&2
  exit 1
}
command -v npm >/dev/null || {
  echo "publish-pkg-branch: 需要 npm" >&2
  exit 1
}

if [ "$BUILD" = 1 ]; then
  if command -v pnpm >/dev/null 2>&1; then
    (cd "$PKG" && pnpm build)
  else
    (cd "$PKG" && npm run build)
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

(cd "$PKG" && npm pack --pack-destination "$TMP" >/dev/null)
tar -xzf "$TMP"/remote-pi-*.tgz -C "$TMP"
TREE="$TMP/package"

VERSION="$(node -p "require('$PKG/package.json').version")"
REV="$(git -C "$ROOT" rev-parse --short HEAD)"
MSG="pkg: remote-pi $VERSION (${REV})"

# 用临时索引在工作区之外写 tree/commit 对象：真实索引与工作区不动，
# 而对象落在同一个仓库里 —— push 因此复用该仓库的 remote 与凭据
# （CI 里 actions/checkout 的鉴权是仓库局部的 http.<url>.extraheader，
#  换个临时仓库 push 会丢）。
SUBTREE_INDEX="$TMP/index"
TREE_SHA="$(
  cd "$TREE"
  GIT_DIR="$ROOT/.git" GIT_INDEX_FILE="$SUBTREE_INDEX" git add -A -f
  GIT_DIR="$ROOT/.git" GIT_INDEX_FILE="$SUBTREE_INDEX" git write-tree
)"
COMMIT="$(git -C "$ROOT" commit-tree "$TREE_SHA" -m "$MSG")"

echo "$MSG"
echo "  远端   $REMOTE ($(git -C "$ROOT" remote get-url "$REMOTE"))"
echo "  分支   $BRANCH"
echo "  顶层   $(git -C "$ROOT" ls-tree --name-only "$COMMIT" | tr '\n' ' ')"
echo "  文件数 $(git -C "$ROOT" ls-tree -r --name-only "$COMMIT" | wc -l)"

if [ "$DRY_RUN" = 1 ]; then
  echo "(--dry-run：未推送)"
  exit 0
fi

GIT_TERMINAL_PROMPT=0 git -C "$ROOT" push --force "$REMOTE" "$COMMIT:refs/heads/$BRANCH"
