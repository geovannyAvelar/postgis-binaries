#!/usr/bin/env bash
# macOS counterpart to build-linux.sh. Same shape: fetch the theseus-rs
# Postgres binary, build PostGIS against it via Homebrew deps, bundle
# runtime dylibs with install_name_tool (macOS's patchelf equivalent).
#
# NOT YET VALIDATED -- written from the same design as the Linux script,
# which was verified end-to-end, but this has not been run on real macOS
# hardware/CI yet. Treat it as a strong first draft, not a proven artifact.
#
# Usage: ./build-macos.sh <postgis-version> <pg-major> <target-triple>
# Example: ./build-macos.sh 3.5.7 17 aarch64-apple-darwin

set -euo pipefail

POSTGIS_VERSION="${1:?usage: $0 <postgis-version> <pg-major> <target-triple>}"
PG_MAJOR="${2:?missing pg-major}"
TARGET="${3:?missing target-triple}"

WORKDIR="$(pwd)/work-${POSTGIS_VERSION}-pg${PG_MAJOR}-${TARGET}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "==> Installing build dependencies via Homebrew"
brew install geos proj libxml2 json-c pkg-config automake libtool

echo "==> Resolving theseus-rs postgresql-binaries tag for PG ${PG_MAJOR}"
PG_TAG=$(curl -fsSL "https://api.github.com/repos/theseus-rs/postgresql-binaries/releases?per_page=100" \
  | grep -o "\"tag_name\": \"${PG_MAJOR}\.[0-9]*\.[0-9]*\"" \
  | head -1 | cut -d'"' -f4)
if [ -z "$PG_TAG" ]; then
  echo "no theseus-rs release found for PG major ${PG_MAJOR}" >&2
  exit 1
fi
echo "    using ${PG_TAG}"

echo "==> Downloading Postgres ${PG_TAG} (${TARGET})"
curl -fsSL -o pg.tar.gz \
  "https://github.com/theseus-rs/postgresql-binaries/releases/download/${PG_TAG}/postgresql-${PG_TAG}-${TARGET}.tar.gz"
mkdir -p pg
tar -xzf pg.tar.gz -C pg --strip-components=1
PG_CONFIG="$WORKDIR/pg/bin/pg_config"

echo "==> Cloning PostGIS ${POSTGIS_VERSION}"
git clone --branch "${POSTGIS_VERSION}" --depth 1 https://github.com/postgis/postgis.git src
cd src

echo "==> autogen.sh"
./autogen.sh

BREW_PREFIX="$(brew --prefix)"
echo "==> configure"
# Same scope as Linux: no raster (GDAL's dependency closure is untenable to
# bundle), no SFCGAL, no protobuf (MVT support unevaluated).
./configure \
  --with-pgconfig="$PG_CONFIG" \
  --with-xml2config="$BREW_PREFIX/opt/libxml2/bin/xml2-config" \
  --with-projdir="$BREW_PREFIX/opt/proj" \
  --with-geosconfig="$BREW_PREFIX/opt/geos/bin/geos-config" \
  --without-raster \
  --without-sfcgal \
  --without-protobuf \
  CPPFLAGS="-I$BREW_PREFIX/opt/json-c/include" \
  LDFLAGS="-L$BREW_PREFIX/opt/json-c/lib"

echo "==> make"
make -j"$(sysctl -n hw.ncpu)"

echo "==> make install (staged)"
STAGE="$WORKDIR/stage"
rm -rf "$STAGE"
make install DESTDIR="$STAGE"
STAGE_PG="$STAGE$WORKDIR/pg"

echo "==> Assembling package"
PKG="$WORKDIR/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/lib" "$PKG/share/extension"

for ext in postgis postgis_topology address_standardizer address_standardizer_data_us; do
  cp "$STAGE_PG/lib/${ext}-3.dylib" "$PKG/lib/" 2>/dev/null || true
  cp "$STAGE_PG/share/extension/${ext}"*.sql "$STAGE_PG/share/extension/${ext}.control" \
    "$PKG/share/extension/" 2>/dev/null || true
done

echo "==> Bundling runtime dependencies"
# Same idea as the Linux allowlist: anything not part of the OS's own
# guaranteed-present dylib set gets copied alongside the extension and its
# install name / load commands rewritten to @loader_path.
ALLOW='^/usr/lib/|^/System/Library/'

closure() { otool -L "$1" | tail -n +2 | awk '{print $1}'; }

TO_BUNDLE=$(for dylib in "$PKG"/lib/*.dylib; do closure "$dylib"; done | sort -u | grep -vE "$ALLOW" || true)

echo "$TO_BUNDLE" | while read -r lib; do
  [ -n "$lib" ] && cp -f "$lib" "$PKG/lib/"
done

for dylib in "$PKG"/lib/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$dylib")" "$dylib"
  for dep in $(closure "$dylib" | grep -vE "$ALLOW" || true); do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$dylib"
  done
  codesign --force -s - "$dylib"
done

echo "==> Verifying no unresolved dependencies remain"
for dylib in "$PKG"/lib/*.dylib; do
  unresolved=$(otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep -vE "$ALLOW" | grep -v '^@loader_path' || true)
  if [ -n "$unresolved" ]; then
    echo "UNRESOLVED in $dylib:" >&2
    echo "$unresolved" >&2
    exit 1
  fi
done

echo "==> Packaging archive"
ARCHIVE_NAME="postgis-${POSTGIS_VERSION}-pg${PG_MAJOR}-${TARGET}"
mkdir -p "$WORKDIR/out/${ARCHIVE_NAME}"
cp -r "$PKG"/* "$WORKDIR/out/${ARCHIVE_NAME}/"
tar -czf "$WORKDIR/${ARCHIVE_NAME}.tar.gz" -C "$WORKDIR/out" "${ARCHIVE_NAME}"

echo "==> Done: $WORKDIR/${ARCHIVE_NAME}.tar.gz"
du -h "$WORKDIR/${ARCHIVE_NAME}.tar.gz"
