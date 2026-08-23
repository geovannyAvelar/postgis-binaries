# postgis-binaries (prototype)

Builds self-contained PostGIS binary archives for [pachyderm](https://github.com/geovannyAvelar/pachyderm),
matched against the Postgres binaries [theseus-rs/postgresql-binaries](https://github.com/theseus-rs/postgresql-binaries)
ships. Not a fork of PostGIS — each build clones upstream at a release tag,
builds it against the target theseus-rs Postgres binary, and packages the
result. No PostGIS source is patched.

## Status

| Platform | Script | Validated |
|---|---|---|
| linux/amd64 | `build-linux.sh` | **Yes** — built, packaged, and loaded (`CREATE EXTENSION`) end to end against PG 17.11 / PostGIS 3.5.7 |
| linux/arm64 | `build-linux.sh` | No — same script, untested runner |
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

## How it works

Each build:

1. Downloads the matching `theseus-rs/postgresql-binaries` release for the
   target Postgres major version + platform, and builds PostGIS against its
   `pg_config`.
2. Runs `make install` into a staging prefix.
3. Walks the resulting `.so`/`.dylib`/`.dll` dependency closure and bundles
   everything that isn't part of the OS's own guaranteed-present library set,
   rewriting each binary to prefer the bundled copy (`patchelf` RPATH on
   Linux, `install_name_tool` + `@loader_path` on macOS). This step is what
   makes the archive installable with no `apt`/`brew`/admin rights on the
   user's machine — confirmed by extracting the Linux archive fresh and
   running real geometry queries against it.
4. Packages `lib/` (or `bin/` on Windows — see below) + `share/extension/`
   into a single-top-dir archive: `postgis-<version>-pg<major>-<target-triple>.tar.gz`.

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
- Even the "core" (non-raster) module bundles ~47 dependencies on Linux,
  mostly because the distro's `libproj` links `libcurl` for on-demand CRS
  grid downloads. Decided to ship that as-is for now rather than rebuild a
  curl-free PROJ; revisit if archive size (~30MB) becomes a real problem.
- Not yet wired into pachyderm itself — this repo only produces the
  binaries. The `postgres` package's `extensions.go`/`install.go` need a
  new installer path (mirroring `github.go`/`install.go`'s existing
  theseus-rs download flow) before `pachyderm extension install postgis`
  can exist.
