#!/usr/bin/env bash
# Prototype: build a self-contained PostGIS binary archive for a given
# PostgreSQL major version, matching the layout pachyderm's `postgres`
# package expects (a single top-level dir, overlaid onto an existing
# theseus-rs postgresql-binaries install).
#
# Validated locally against PostGIS 3.5.7 / PostgreSQL 17.11 / x86_64-unknown-linux-gnu.
# NOT yet validated: linux/arm64, macOS, Windows, --with-raster (GDAL).
#
# Usage: ./build-linux.sh <postgis-version> <pg-major> <target-triple>
# Example: ./build-linux.sh 3.5.7 17 x86_64-unknown-linux-gnu

set -euo pipefail

POSTGIS_VERSION="${1:?usage: $0 <postgis-version> <pg-major> <target-triple>}"
PG_MAJOR="${2:?missing pg-major}"
TARGET="${3:?missing target-triple}"

# Put system dirs first on PATH so they win over conda/homebrew-on-linux/etc
# tools that might otherwise shadow them -- this bit us locally: a conda
# xml2-config resolved ahead of the system one, silently pulling in a
# libxml2 built against non-system libiconv, which broke the final link
# with "undefined reference to libiconv_open". Non-system dirs are kept
# (not stripped) so tools that are only installed there, like patchelf in
# this sandbox, still resolve -- on a real CI runner everything needed is
# in a system dir already.
export PATH="/usr/bin:/usr/local/bin:/bin:$PATH"

WORKDIR="$(pwd)/work-${POSTGIS_VERSION}-pg${PG_MAJOR}-${TARGET}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

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

echo "==> configure"
# --without-raster: postgis_raster links libgdal, whose own dependency
# closure (netcdf, hdf5, poppler, mysqlclient, krb5, openblas, nss, ...)
# runs to 100+ shared libraries -- see the "Known gaps" note in the repo
# README. Not attempting to bundle that safely yet.
# --without-protobuf: not evaluated yet either; drop if MVT support is needed.
./configure \
  --with-pgconfig="$PG_CONFIG" \
  --with-xml2config=/usr/bin/xml2-config \
  --without-raster \
  --without-sfcgal \
  --without-protobuf

echo "==> make"
make -j"$(nproc)"

echo "==> make install (staged)"
STAGE="$WORKDIR/stage"
rm -rf "$STAGE"
make install DESTDIR="$STAGE"

# make install's DESTDIR layering mirrors pg_config's absolute paths, so the
# real payload lands at $STAGE/<absolute path to $WORKDIR/pg>.
STAGE_PG="$STAGE$WORKDIR/pg"

echo "==> Assembling package"
PKG="$WORKDIR/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/lib" "$PKG/share/extension"

for ext in postgis postgis_topology address_standardizer address_standardizer_data_us; do
  cp "$STAGE_PG/lib/${ext}-3.so" "$PKG/lib/" 2>/dev/null || true
  cp "$STAGE_PG/share/extension/${ext}"*.sql "$STAGE_PG/share/extension/${ext}.control" \
    "$PKG/share/extension/" 2>/dev/null || true
done

echo "==> Bundling runtime dependencies"
# Anything not in this allowlist gets a copy placed next to the extension
# .so's, with RPATH rewritten to $ORIGIN so the bundled copy is preferred
# over (possibly absent, possibly incompatible) system libraries.
ALLOW='^(linux-vdso\.so|ld-linux-x86-64\.so|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so)'

closure() { ldd "$1" | awk '{print $3}' | grep -v '^$'; }

TO_BUNDLE=$(for so in "$PKG"/lib/*.so; do closure "$so"; done | sort -u | while read -r p; do
  base=$(basename "$p")
  echo "$base" | grep -qE "$ALLOW" || echo "$p"
done)

echo "$TO_BUNDLE" | while read -r lib; do
  [ -n "$lib" ] && cp -Lf "$lib" "$PKG/lib/"
done

for so in "$PKG"/lib/*; do
  [ -f "$so" ] && [ ! -L "$so" ] && patchelf --set-rpath '$ORIGIN' "$so"
done

echo "==> Verifying no unresolved / stray system deps remain"
for so in "$PKG"/lib/*.so; do
  unresolved=$(ldd "$so" | grep "not found" || true)
  if [ -n "$unresolved" ]; then
    echo "UNRESOLVED in $so:" >&2
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
