# postgis-binaries (prototype)

Builds self-contained PostGIS binary archives for [pachyderm](https://github.com/geovannyAvelar/pachyderm),
matched against the Postgres binaries [theseus-rs/postgresql-binaries](https://github.com/theseus-rs/postgresql-binaries)
ships. Not a fork of PostGIS — each build clones upstream at a release tag,
builds it against the target theseus-rs Postgres binary, and packages the
result. No PostGIS source is patched.

## Status

| Platform | Script | Validated |
|---|---|---|
| linux/amd64 | `build-linux.sh` | **Yes** — every build is smoke-tested, in CI, on Debian 12 and 13, Ubuntu 24.04 and Fedora 41 |
| linux/arm64 | `build-linux.sh` | **Yes** — same as amd64, on arm64 runners |
| macOS (both arches) | `build-macos.sh` | No — written from the same design, not run on real hardware |
| Windows/amd64 | `build-windows.sh` | No — the least standardized of the three; see caveats in the script itself |

## Scope (v1)

- Extensions: `postgis`, `postgis_topology`, `address_standardizer` (+ its `_data_us` companion).
- **Not included: `postgis_raster`.** It links libgdal, whose runtime dependency
  closure is 110+ shared libraries deep (netcdf, hdf5, poppler, mysqlclient,
  Kerberos, OpenBLAS, NSS, fontconfig, ...). Bundling that safely is a
  different-scale problem from the rest of PostGIS and was deliberately cut
  from v1 rather than half-solved.
- `--without-sfcgal`, `--without-protobuf` — unevaluated, not deliberately excluded forever.

PostgreSQL 13–18 are built (PostGIS 3.5 supports 12–18; theseus-rs has no binaries for 12's last releases).

## How it works

Each Linux build runs in an **AlmaLinux 9 container (glibc 2.34)**, not on
the CI runner itself:

1. Downloads the newest `theseus-rs/postgresql-binaries` release of the
   target PostgreSQL major version + platform (`resolve-pg-tag.sh`), and
   builds PostGIS against its `pg_config`.
2. Builds GEOS and PROJ from source (versions pinned in `build-linux.sh`) —
   the distribution's own are too old for all of PostGIS — PROJ without curl and
   libtiff, which keeps the bundled dependency set small.
3. Runs `make install` into a staging prefix.
4. Walks the extensions' dependency closure **the way the installed
   extension resolves it** — the PostgreSQL install's `lib/` first — and
   bundles only what PostgreSQL doesn't already ship there, rewriting each
   binary's RPATH to `$ORIGIN` with `patchelf`. glibc itself is the system's.
   `proj.db` goes in `share/proj/`, where the bundled PROJ looks for it.
5. Fails the build if any packaged file would overwrite one of PostgreSQL's,
   or if the package needs a newer glibc than PostgreSQL itself.
6. Packages `lib/` (or `bin/` on Windows — see below) + `share/` into a
   single-top-dir archive: `postgis-<version>-pg<major>-<target-triple>.tar.gz`.
7. Smoke-tests it (`smoke-test-linux.sh`): extracts PostgreSQL and the
   archive over it, as pachyderm does, checks every library and symbol
   version resolves (`ldd`), starts a cluster, creates every extension,
   and runs GEOS, PROJ, GML, GeoJSON, topology and address-standardizer
   queries — if the build system can run that PostgreSQL; CI runs it on
   other distributions either way.

### Why the old glibc

Everything built, and every library bundled from the build system, needs
at least that system's glibc. The theseus-rs PostgreSQL binaries need glibc
2.36 (their bundled libstdc++, libcrypt, ... do), so building on an older
system makes PostGIS run wherever the PostgreSQL it overlays runs, and the
build fails if the package would ever need more than PostgreSQL does.
(Debian 11, with glibc 2.31, would be older still, but its LTS support
ended in 2026 and its security packages are gone from the mirrors.)

Because the build system is older than PostgreSQL's own requirement, it
can't run that PostgreSQL, so the smoke test runs in the `test-linux` CI
job instead, on Debian 12 (glibc 2.36, the oldest PostgreSQL itself runs
on) and newer distributions. Archives built on Ubuntu 24.04 (before
2026-11) needed glibc 2.38 and replaced 15 of PostgreSQL's own libraries,
which left PostgreSQL unable to start on Debian 12.

### Building and publishing

`build.yml` runs on a `v*` tag push (builds every platform and publishes)
or manually (pick the PostGIS version and platforms; it only publishes with
`publish` checked). Rebuilding a version that's already published replaces
its archives; pachyderm checks each download against its GitHub digest.

```bash
gh workflow run build.yml -f postgis_version=3.5.7 -f platforms=linux           # build + test only
gh workflow run build.yml -f postgis_version=3.5.7 -f platforms=linux -f publish=true
```

## Known gaps / open questions

- **Archive layout differs on Windows.** Linux/macOS overlay onto the target
  Postgres install's `lib/`; Windows DLL search order looks next to the
  *loading executable* (`postgres.exe`), not next to the extension DLL that
  depends on them, so the Windows archive's dependency DLLs need to land in
  `bin/` instead. Pachyderm's Go-side installer will need to know this when
  it overlays the archive.
- **Windows toolchain is unverified even in principle**, not just untested:
  it assumes MSYS2/MinGW-w64 packages link cleanly against the theseus-rs
  Postgres binary's import library. Upstream PostGIS's own Windows buildbot
  (`ci/winnie/` in the postgis source) instead cross-compiles MinGW against
  *self-built* GEOS/PROJ/etc., which suggests prebuilt MinGW packages may not
  be a drop-in equivalent. Needs real testing on a Windows runner before
  trusting it.
- PROJ is built without curl, so it can't download transformation grids on
  demand; transformations that need a grid fall back to less accurate ones.
- Pachyderm installs these with `pachyderm extension get-postgis`, and
  refuses archives that need a newer glibc than the system has.
