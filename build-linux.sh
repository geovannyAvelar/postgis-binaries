#!/usr/bin/env bash
# Prototype: build a self-contained PostGIS binary archive for a given
# PostgreSQL major version, matching the layout pachyderm's `postgres`
# package expects (a single top-level dir, overlaid onto an existing
# theseus-rs postgresql-binaries install).
#
# Build it on an OLD distribution -- CI uses AlmaLinux 9 (glibc 2.34) --
# not on the runner itself. Everything built here, and every library
# bundled from this system, needs at least this system's glibc. Building on
# theseus-rs's own baseline (its binaries need glibc 2.34) or older means
# the archive runs anywhere the PostgreSQL it overlays runs; building on a newer system
# (e.g. ubuntu-24.04, glibc 2.39) produced archives that needed glibc 2.38
# and left PostgreSQL itself unable to start on Debian 12 / Ubuntu 22.04 /
# RHEL 9, because they also replaced PostgreSQL's own libraries.
#
# Libraries PostgreSQL already ships in its lib/ (libxml2, libstdc++, zlib,
# krb5, ...) are never bundled: the extension uses PostgreSQL's copies,
# which, being newer than this build system's, are ABI-compatible. Nothing
# in the archive overwrites a file of the PostgreSQL install. The script
# checks both, plus the glibc limit, then smoke-tests the result (see
# smoke-test-linux.sh), and fails on any violation.
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WORKDIR="$(pwd)/work-${POSTGIS_VERSION}-pg${PG_MAJOR}-${TARGET}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "==> Resolving theseus-rs postgresql-binaries tag for PG ${PG_MAJOR}"
PG_TAG=$("$SCRIPT_DIR/resolve-pg-tag.sh" "$PG_MAJOR")
echo "    using ${PG_TAG}"

echo "==> Downloading Postgres ${PG_TAG} (${TARGET})"
curl -fsSL -o pg.tar.gz \
  "https://github.com/theseus-rs/postgresql-binaries/releases/download/${PG_TAG}/postgresql-${PG_TAG}-${TARGET}.tar.gz"
mkdir -p pg
tar -xzf pg.tar.gz -C pg --strip-components=1
PG_CONFIG="$WORKDIR/pg/bin/pg_config"

# GEOS and PROJ are built from source instead of taken from the build
# system: its packages (EPEL 9: GEOS 3.10, PROJ 8.2) are too old for all
# of PostGIS's functionality, and building PROJ without curl and libtiff
# drops most of what it would otherwise pull into the archive. Its
# sqlite3 is PostgreSQL's own copy at runtime.
GEOS_VERSION="${GEOS_VERSION:-3.13.1}"
PROJ_VERSION="${PROJ_VERSION:-9.7.1}"
DEPS="$WORKDIR/deps"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"
export LD_LIBRARY_PATH="$DEPS/lib"

echo "==> Building GEOS ${GEOS_VERSION}"
git clone --branch "${GEOS_VERSION}" --depth 1 https://github.com/libgeos/geos.git geos-src
cmake -S geos-src -B geos-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_TESTING=OFF -DBUILD_DOCUMENTATION=OFF >/dev/null
cmake --build geos-build -j"$(nproc)" >/dev/null
cmake --install geos-build >/dev/null

echo "==> Building PROJ ${PROJ_VERSION}"
git clone --branch "${PROJ_VERSION}" --depth 1 https://github.com/OSGeo/PROJ.git proj-src
cmake -S proj-src -B proj-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
  -DENABLE_CURL=OFF -DENABLE_TIFF=OFF -DBUILD_APPS=OFF \
  -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=ON >/dev/null
cmake --build proj-build -j"$(nproc)" >/dev/null
cmake --install proj-build >/dev/null

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
  --with-geosconfig="$DEPS/bin/geos-config" \
  --with-projdir="$DEPS" \
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
# glibc itself (and the loader) is the system's: never bundled. Everything
# else the extensions need gets a copy placed next to them, with RPATH
# rewritten to $ORIGIN -- which, once overlaid, is the PostgreSQL install's
# lib/ -- unless PostgreSQL already ships that library there.
GLIBC='^(linux-vdso\.so|ld-linux-.*\.so|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so|libanl\.so)'

# Resolve the way the installed extension will: PostgreSQL's lib/ first (a
# library found there is used as is, and so are its own dependencies),
# then the GEOS/PROJ just built, then the system.
closure() {
  LD_LIBRARY_PATH="$WORKDIR/pg/lib:$DEPS/lib" ldd "$1" | awk '/=>/ {print $3}' | grep -v '^$' || true
}

TO_BUNDLE=$(for so in "$PKG"/lib/*.so; do closure "$so"; done | sort -u | while read -r p; do
  base=$(basename "$p")
  if echo "$base" | grep -qE "$GLIBC"; then
    continue
  fi
  case "$p" in
    "$WORKDIR/pg/lib/"*)
      echo "    using PostgreSQL's own $base" >&2
      continue ;;
  esac
  echo "    bundling $p" >&2
  echo "$p"
done)

echo "$TO_BUNDLE" | while read -r lib; do
  [ -n "$lib" ] && cp -Lf "$lib" "$PKG/lib/"
done

for so in "$PKG"/lib/*; do
  [ -f "$so" ] && [ ! -L "$so" ] && patchelf --set-rpath '$ORIGIN' "$so"
done

echo "==> Bundling PROJ's database"
# ST_Transform and friends need proj.db, which the bundled libproj looks
# for in ../share/proj relative to itself -- i.e. the PostgreSQL install's
# share/proj once overlaid. Users' systems mostly don't have it installed.
PROJ_DB="$DEPS/share/proj/proj.db"
if [ ! -f "$PROJ_DB" ]; then
  echo "proj.db not found in the PROJ build ($PROJ_DB)" >&2
  exit 1
fi
mkdir -p "$PKG/share/proj"
cp "$PROJ_DB" "$PKG/share/proj/"
[ -f "$(dirname "$PROJ_DB")/proj.ini" ] && cp "$(dirname "$PROJ_DB")/proj.ini" "$PKG/share/proj/"

echo "==> Checking nothing in the package overwrites PostgreSQL's own files"
clashes=$(cd "$PKG" && find . -type f -o -type l | sed 's|^\./||' | while read -r f; do
  [ -e "$WORKDIR/pg/$f" ] && echo "$f"
done || true)
if [ -n "$clashes" ]; then
  echo "These files would replace PostgreSQL's own:" >&2
  echo "$clashes" >&2
  exit 1
fi

echo "==> Checking the glibc the package needs against PostgreSQL's"
max_glibc() {
  for f in "$@"; do
    objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' || true
  done | sed 's/GLIBC_//' | sort -V | tail -1
}
PKG_GLIBC=$(max_glibc "$PKG"/lib/*)
PG_GLIBC=$(max_glibc "$WORKDIR"/pg/bin/postgres "$WORKDIR"/pg/lib/*.so*)
echo "    package needs glibc ${PKG_GLIBC}; PostgreSQL ${PG_TAG} needs ${PG_GLIBC}"
if [ "$(printf '%s\n%s\n' "$PKG_GLIBC" "$PG_GLIBC" | sort -V | tail -1)" != "$PG_GLIBC" ]; then
  echo "The package needs a newer glibc (${PKG_GLIBC}) than PostgreSQL itself (${PG_GLIBC}); build on an older system." >&2
  exit 1
fi

echo "==> Packaging archive"
ARCHIVE_NAME="postgis-${POSTGIS_VERSION}-pg${PG_MAJOR}-${TARGET}"
mkdir -p "$WORKDIR/out/${ARCHIVE_NAME}"
cp -r "$PKG"/* "$WORKDIR/out/${ARCHIVE_NAME}/"
tar -czf "$WORKDIR/${ARCHIVE_NAME}.tar.gz" -C "$WORKDIR/out" "${ARCHIVE_NAME}"

echo "==> Smoke test"
unset LD_LIBRARY_PATH
"$SCRIPT_DIR/smoke-test-linux.sh" "$WORKDIR/${ARCHIVE_NAME}.tar.gz" "$WORKDIR/pg.tar.gz"

echo "==> Done: $WORKDIR/${ARCHIVE_NAME}.tar.gz"
du -h "$WORKDIR/${ARCHIVE_NAME}.tar.gz"
