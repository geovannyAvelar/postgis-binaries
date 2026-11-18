#!/usr/bin/env bash
# Install a PostGIS archive the way pachyderm does -- extracted over a
# theseus-rs PostgreSQL install -- and check it works on this system:
#
#   - every library the archive brings resolves in the overlaid install,
#     with the symbol versions it needs, and so do postgres and psql;
#   - a fresh cluster starts, and every packaged extension can be created
#     and used.
#
# Run it as root or as a regular user; as root, PostgreSQL itself runs as a
# throwaway "pgsmoke" user (initdb refuses to run as root).
#
# Exits 77 if PostgreSQL itself can't run on this system (some theseus-rs
# releases need system libraries it may lack), so there's nothing to test.
#
# Usage: ./smoke-test-linux.sh <postgis-archive.tar.gz> <postgresql-archive.tar.gz>

set -euo pipefail

# Only what the install itself resolves counts.
unset LD_LIBRARY_PATH

POSTGIS_ARCHIVE="$(realpath "${1:?usage: $0 <postgis-archive.tar.gz> <postgresql-archive.tar.gz>}")"
PG_ARCHIVE="$(realpath "${2:?missing postgresql archive}")"

DIR="$(mktemp -d /tmp/postgis-smoke-XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
INSTALL="$DIR/pg"
mkdir -p "$INSTALL"
tar -xzf "$PG_ARCHIVE" -C "$INSTALL" --strip-components=1

# Some theseus-rs releases (e.g. PostgreSQL 13) aren't self-contained: they
# link system libraries (a specific ICU, OpenSSL, krb5, readline) that not
# every distribution has. Where PostgreSQL itself can't run, there's
# nothing to test PostGIS in: exit 77 ("skipped").
missing=$(for f in "$INSTALL"/bin/postgres "$INSTALL"/bin/psql; do ldd "$f" 2>&1 | grep "not found" || true; done)
if [ -n "$missing" ]; then
  echo "==> Skipped: PostgreSQL itself doesn't run on this system:"
  echo "$missing" | sed 's/^[[:space:]]*/    /'
  exit 77
fi

tar -xzf "$POSTGIS_ARCHIVE" -C "$INSTALL" --strip-components=1

echo "==> Checking every library resolves ($(getconf GNU_LIBC_VERSION 2>/dev/null || echo 'unknown libc'))"
# What PostGIS brings, plus the server and client it runs in. PostgreSQL's
# own optional modules aren't checked: some theseus-rs releases (e.g. 13)
# link system libraries (libssl, libuuid, ...) a minimal system may lack,
# whatever PostGIS does.
PACKAGED=$(tar -tzf "$POSTGIS_ARCHIVE" | sed 's|^[^/]*/||' | grep -E '^lib/.+\.so' || true)
failed=0
for f in "$INSTALL"/bin/postgres "$INSTALL"/bin/psql $(printf "$INSTALL/%s\n" $PACKAGED); do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  # "not found" covers both a missing library and a missing symbol version
  # (e.g. "version `GLIBC_2.38' not found"). Undefined symbols are not
  # checked: server modules get theirs (palloc, errmsg, ...) from the
  # postgres executable when loaded -- CREATE EXTENSION below checks that.
  problems=$(ldd "$f" 2>&1 | grep -E "not found" || true)
  if [ -n "$problems" ]; then
    echo "  $f:" >&2
    echo "$problems" | sed 's/^/    /' >&2
    failed=1
  fi
done
[ "$failed" = 0 ] || { echo "Unresolved libraries or symbols (see above)." >&2; exit 1; }

echo "==> Starting PostgreSQL and creating the extensions"
run() { "$@"; }
if [ "$(id -u)" = 0 ]; then
  id pgsmoke >/dev/null 2>&1 || useradd -M -d "$DIR" pgsmoke
  chown -R pgsmoke "$DIR"
  run() { su pgsmoke -s /bin/bash -c "$(printf '%q ' "$@")"; }
fi

DATA="$DIR/data"
PORT=54329
run "$INSTALL/bin/initdb" -D "$DATA" -U postgres >/dev/null
run "$INSTALL/bin/pg_ctl" -D "$DATA" -l "$DIR/server.log" -w \
  -o "-p $PORT -k $DIR -h ''" start >/dev/null || { cat "$DIR/server.log" >&2; exit 1; }
stop() { run "$INSTALL/bin/pg_ctl" -D "$DATA" -m fast -w stop >/dev/null 2>&1 || true; rm -rf "$DIR"; }
trap stop EXIT

psql() { run "$INSTALL/bin/psql" -h "$DIR" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -tA "$@"; }

check() {
  local got
  got=$(psql -c "$1")
  if [ "$got" != "$2" ]; then
    echo "  $1" >&2
    echo "  got: $got" >&2
    echo "  want: $2" >&2
    exit 1
  fi
  echo "  ok: $1"
}

for ext in postgis postgis_topology address_standardizer address_standardizer_data_us; do
  if [ -f "$INSTALL/share/extension/$ext.control" ]; then
    psql -c "CREATE EXTENSION $ext" >/dev/null
    echo "  created $ext"
  fi
done

check "SELECT ST_Distance(ST_Point(0, 0), ST_Point(3, 4))" "5"
# GEOS: a buffer's area is close to pi r^2.
check "SELECT round(ST_Area(ST_Buffer(ST_Point(0, 0), 10))::numeric, -1)" "310"
# PROJ: reprojecting a point from WGS 84 to Web Mercator.
check "SELECT round(ST_X(ST_Transform(ST_SetSRID(ST_Point(180, 0), 4326), 3857))::numeric)" "20037508"
# libxml2 (GML parsing) and json-c (GeoJSON).
check "SELECT ST_AsText(ST_GeomFromGML('<gml:Point><gml:coordinates>1,2</gml:coordinates></gml:Point>'))" "POINT(1 2)"
check "SELECT ST_AsText(ST_GeomFromGeoJSON('{\"type\":\"Point\",\"coordinates\":[3,4]}'))" "POINT(3 4)"
if [ -f "$INSTALL/share/extension/postgis_topology.control" ]; then
  check "SELECT topology.CreateTopology('smoke') > 0" "t"
fi
if [ -f "$INSTALL/share/extension/address_standardizer.control" ]; then
  check "SELECT house_num FROM standardize_address('us_lex', 'us_gaz', 'us_rules', '1 Main St, Boston, MA 02101')" "1"
fi

echo "==> Smoke test passed: $(psql -c 'SELECT postgis_full_version()' | cut -c1-120)"
