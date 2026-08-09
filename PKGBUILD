# Maintainer: ctype-lab <https://github.com/ctype-lab>

pkgname=codegraph-git
pkgver=1.5.0.r108.g526fb01
pkgrel=1
pkgdesc='Local-first code intelligence graph for coding agents (development build)'
arch=('x86_64' 'aarch64')
url='https://github.com/ctype-lab/codegraph'
license=('MIT')
depends=('nodejs')
makedepends=('git' 'npm' 'rust')
provides=('codegraph')
conflicts=('codegraph')
source=("${pkgname}::git+https://github.com/ctype-lab/codegraph.git#branch=devel")
sha256sums=('SKIP')

pkgver() {
  cd "$srcdir/$pkgname"
  git describe --long --tags --abbrev=7 2>/dev/null \
    | sed 's/^v//;s/-/.r/;s/-/./g'
}

build() {
  cd "$srcdir/$pkgname"
  npm ci --ignore-scripts --cache "$srcdir/npm-cache"
  npm run build:kernel
  npm run build
}

package() {
  cd "$srcdir/$pkgname"

  # The build needs TypeScript and test tooling, but the installed CLI does not.
  npm prune --omit=dev --ignore-scripts

  install -d "$pkgdir/usr/lib/codegraph"
  cp -a dist node_modules package.json "$pkgdir/usr/lib/codegraph/"
  case "$CARCH" in
    x86_64) kernel_platform='linux-x64' ;;
    aarch64) kernel_platform='linux-arm64' ;;
  esac
  install -Dm755 "codegraph-kernel/prebuilds/$kernel_platform/codegraph-kernel.node" \
    "$pkgdir/usr/lib/codegraph/codegraph-kernel/prebuilds/$kernel_platform/codegraph-kernel.node"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"

  install -Dm755 /dev/stdin "$pkgdir/usr/bin/codegraph" <<'EOF'
#!/bin/sh
exec /usr/bin/node --liftoff-only --disable-warning=ExperimentalWarning \
  /usr/lib/codegraph/dist/bin/codegraph.js "$@"
EOF
}
