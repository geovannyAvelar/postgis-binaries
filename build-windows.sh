#!/usr/bin/env bash
# Windows counterpart, meant to run inside an MSYS2 MINGW64 shell (e.g. via
# msys2/setup-msys2 on a windows-latest GH Actions runner). Same configure/
# make flow as Linux/macOS -- PostGIS has no CMake/MSVC build; upstream's
# own Windows buildbot ("winnie", see ci/winnie/build_postgis.sh in the
# postgis source) cross-compiles with MinGW from source-built deps. This
# script takes the simpler route of MSYS2's prebuilt mingw-w64 packages
# instead of building GEOS/PROJ/libxml2/json-c from scratch ourselves.
#
# NOT VALIDATED AT ALL -- no Windows/MSYS2 environment was available to
# test this. Treat it as a starting point that will need real debugging on
# an actual Windows runner, not a working artifact yet. In particular:
#
#   - Windows DLL search order looks next to the *loading executable*
#     (postgres.exe), not next to the extension DLL that depends on them --
#     unlike RPATH/@loader_path on Linux/macOS. So bundled dependency DLLs
#     are copied into pg/bin (alongside postgres.exe), not pg/lib, and
#     there is no rpath-equivalent rewrite step here.
#   - Whether the theseus-rs Windows build is MSVC or MinGW-ABI matters: a
#     PostGIS DLL built with MinGW must link against an MSVC-built Postgres
#     import library without an ABI mismatch, which is not guaranteed to
#     "just work" the way it does on Linux/macOS. This needs to be checked
#     against the actual theseus-rs release before trusting this script.
#
# Usage: ./build-windows.sh <postgis-version> <pg-major> <target-triple>
# Example: ./build-windows.sh 3.5.7 17 x86_64-pc-windows-msvc

set -euo pipefail

POSTGIS_VERSION="${1:?usage: $0 <postgis-version> <pg-major> <target-triple>}"
PG_MAJOR="${2:?missing pg-major}"
TARGET="${3:?missing target-triple}"

echo "==> Installing build dependencies via pacman (MSYS2 MINGW64)"
pacman -S --needed --noconfirm \
  mingw-w64-x86_64-geos \
  mingw-w64-x86_64-proj \
  mingw-w64-x86_64-libxml2 \
  mingw-w64-x86_64-json-c \
  mingw-w64-x86_64-toolchain \
  automake autoconf libtool perl git

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
PG_CONFIG="$WORKDIR/pg/bin/pg_config.exe"

echo "==> Cloning PostGIS ${POSTGIS_VERSION}"
git clone --branch "${POSTGIS_VERSION}" --depth 1 https://github.com/postgis/postgis.git src
cd src

echo "==> autogen.sh"
./autogen.sh

echo "==> configure"
./configure \
  --with-pgconfig="$PG_CONFIG" \
  --with-xml2config=/mingw64/bin/xml2-config \
  --with-geosconfig=/mingw64/bin/geos-config \
  --without-raster \
  --without-sfcgal \
  --without-protobuf \
  --with-gettext=no

echo "==> make"
make -j"$(nproc)"

echo "==> make install (staged)"
STAGE="$WORKDIR/stage"
rm -rf "$STAGE"
make install DESTDIR="$STAGE"
STAGE_PG="$STAGE$WORKDIR/pg"

echo "==> Assembling package"
PKG="$WORKDIR/pkg"
rm -rf "$PKG"
mkdir -p "$PKG/bin" "$PKG/share/extension"

for ext in postgis postgis_topology address_standardizer address_standardizer_data_us; do
  cp "$STAGE_PG/lib/${ext}-3.dll" "$PKG/bin/" 2>/dev/null || true
  cp "$STAGE_PG/share/extension/${ext}"*.sql "$STAGE_PG/share/extension/${ext}.control" \
    "$PKG/share/extension/" 2>/dev/null || true
done

echo "==> Bundling runtime dependencies"
# No rpath equivalent on Windows: dependency DLLs must sit next to
# postgres.exe (pg/bin), so pachyderm's installer needs to overlay this
# archive's bin/ onto the target version's bin/, not lib/.
closure() {
  # Requires an `ldd`-alike; MSYS2's ldd works fine on MinGW-built PEs.
  ldd "$1" 2>/dev/null | awk '{print $3}' | grep -i '/mingw64/bin/' || true
}

TO_BUNDLE=$(for dll in "$PKG"/bin/*.dll; do closure "$dll"; done | sort -u)
echo "$TO_BUNDLE" | while read -r lib; do
  [ -n "$lib" ] && cp -f "$lib" "$PKG/bin/"
done

echo "==> Packaging archive"
ARCHIVE_NAME="postgis-${POSTGIS_VERSION}-pg${PG_MAJOR}-${TARGET}"
mkdir -p "$WORKDIR/out/${ARCHIVE_NAME}"
cp -r "$PKG"/* "$WORKDIR/out/${ARCHIVE_NAME}/"
(cd "$WORKDIR/out" && zip -r "$WORKDIR/${ARCHIVE_NAME}.zip" "${ARCHIVE_NAME}")

echo "==> Done: $WORKDIR/${ARCHIVE_NAME}.zip"
