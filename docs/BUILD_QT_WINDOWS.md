# Vendored Qt for the Windows packages (5.15.19)

**Status: applied.** `third_party/qt-win64`, `third_party/qt-win32`,
`third_party/openssl-win64` and `third_party/openssl-win32` are vendored in this
repository, and both Windows workflows consume them instead of downloading Qt
and OpenSSL. Provenance for each is in the `BOM.json` inside its own tree.
The build recipe (`tools/build_qt_win64.ps1`) is deliberately NOT committed: it
only runs on a Windows machine and the trees are already in the repo.

## 1. Why

The Windows packages currently get Qt from `jurplel/install-qt-action`
(`win64_msvc2019_64` / `win32_msvc2019`, both **5.15.2**). Notes:

- The official Windows binaries **stop at 5.15.2**. The public 5.15.19 archive
  is **source only**; there is no distro, no vendor and no installer that ships
  a patched Qt5 for Windows.
- The sources used are the **official Qt 5.15.19 release tarballs** from
  `download.qt.io`, pinned by the **SHA256 Qt publishes next to each one**. The
  first draft of this recipe pulled the `kde/5.15` maintenance branch from
  `invent.kde.org` instead; that turned out to be unusable: the host answers
  `HTTP Basic: Access denied` to an anonymous HTTPS clone, so git asks the
  Windows credential manager for a token, and under a non-interactive account
  that prompt **never resolves** (the clone hangs forever with 0 bytes written,
  which looks exactly like a slow network). The `github.com/qt` mirror does
  not carry that branch at all. The release tarballs need no account, and the
  SHA256 makes the provenance **stronger** than "a branch tip" — the BOM records
  a verifiable digest per module instead of a commit id.
- **OpenSSL 3 depends on this.** Qt 5.15.2 can only load `libssl-1_1`
  (OpenSSL 1.1.1, **EOL since Sep 2023**). OpenSSL 3 names (`libssl-3-x64`)
  require **≥ 5.15.8**, so the Qt rebuild is the prerequisite for moving the
  bundles off the EOL 1.1.1. The two swaps are staged and independent: the Qt
  swap can land alone (5.15.19 still loads 1.1.1), then a second change
  moves to **OpenSSL 3.5 LTS**. Until then the build uses the **1.1.1w
  development files** only as build-time input, and the runtime keeps being the
  `libssl-1_1*.dll` / `libcrypto-1_1*.dll` the packages already ship.

Exactly the `third_party/ffmpeg-win32/` precedent: what has no public binary is
built once and vendored, and the CI neither downloads nor compiles it.

## 2. The build-in-workflow vs. precompiled question

| Scheme | Time per Windows run (x64 *and* x86) | When the Qt build is paid |
|---|---|---|
| Compile Qt in every run | **~50–80 min** each run | **every validation** |
| **Precompiled, vendored in the repo (chosen)** | **~3–5 min** (≈ today's ~4) — Qt comes in the checkout | **once** on a Windows machine with `tools/build_qt_win64.ps1` (the CI never builds Qt) |

Compiling per run would multiply each Windows run by ~15–20× to produce the
same binary (the Qt source does not change between runs). Since the Windows
workflows are manual/opt-in, that means paying ~1 h of CI every time a change is
validated, for nothing. Vendoring pays the build once.

## 3. What the vendor weighs (measured, not estimated)

| Part per architecture | Weight |
|---|---|
| Runtime DLLs (`Qt5Core/Gui/Widgets/Network/Sql` + ANGLE; `+Qt5Multimedia` on x86) | ~40–45 MB |
| Host tools the CI needs (`qmake/moc/uic/rcc/windeployqt`) | ~15 MB |
| **Qt headers** (Core/Gui/Widgets/Network/Sql — measured on this machine: QtCore 6.5 MB + QtGui 4.9 + QtWidgets 2.5 + …) | **~15 MB** (private/ stripped) |
| MSVC import-libs + mkspecs + plugins (qwindows, qjpeg, qsqlite, qwebp, qoffscreen, [x86] audio) | ~8 MB |
| **Total per architecture** | **~75–85 MB unpacked** |

Repo impact (today: `.git` = **14 MB**, `third_party/ffmpeg-win32` = 7.3 MB):

| Format | Repo after | Clone | Extra per CI run |
|---|---|---|---|
| **Unpacked** `third_party/qt-win64/` + `qt-win32/` (ffmpeg pattern) — **chosen** | ~110–125 MB | ~120 MB | 0 (already in checkout) |
| One `.7z` per architecture | ~65–75 MB | ~70 MB | ~30–60 s extraction |

Unpacked matches the FFmpeg precedent exactly (visible `bin/ lib/ include/
plugins/`, no extraction step in CI). Well within GitHub's guidance (< 1 GB per
repo).

## 4. Findings verified against the Qt 5.15 sources

Three of the recipe's assumptions were checked against the real trees (sparse
clones of the official mirror, branch `5.15`) and corrected:

1. **`windeployqt` is NOT in qtbase.** In 5.15 it lives in **`qttools`**
   (`src/windeployqt`), and its `.pro` is `QT = core-private` + `force_bootstrap`
   — it links **Qt5Core only**. Therefore it does **not** drag `Qt5Svg` into the
   bundle, and it builds in ~2–3 min instead of compiling all of qttools.
2. **The MSVC mkspec is the generic `win32-msvc`** (there is no
   `win32-msvc2019` mkspec in 5.15, only the winrt variants). What pins the
   toolset is the `vcvarsall` environment (`-vcvars_ver=14.29` → v142 for the
   x86/Win7 build).
3. **`qtimageformats` vendors libwebp inside the module**
   (`src/3rdparty/libwebp/`), so `qwebp` builds self-contained on Windows — no
   external dependency. `qjpeg/qgif/qico` live in **qtbase**.
4. **Every configure flag was checked against the real 5.15
   `configure.json` files**: `-openssl-runtime` (`src/network`),
   `-no-icu` (`src/corelib`, boolean), `-opengl dynamic` (`src/gui`,
   `optionalString`), `-mp` and `-nomake examples|tests` (qtbase). None is
   invented.

Also relevant: the app is **designed to work without the webp plugin**
(`src/ui/thumbnail_cache.cpp` rewrites `vi_webp/…webp` → `vi/…jpg`), so `qwebp`
is kept purely for byte-parity with today's bundle and can be a future trim.

## 5. Module set (reproduces today's bundle, minus what AGENTS.md forbids)

| Module | Built | Why |
|---|---|---|
| `qtbase` | yes | Core Gui Widgets Network Sql, `moc/uic/rcc/qmake`, ANGLE, `qjpeg/qgif/qico` |
| `qttools` | **only `src/windeployqt`** | the deployment tool the packaging step uses |
| `qtimageformats` | yes | `qwebp` + friends (parity with today) |
| `qtmultimedia` | **x86 only** | the app uses `QAudioOutput` there |
| `qtsvg` | **no** | the app has no Svg dependency → packages stay free of `Qt5Svg.dll` |

`opengl32sw.dll` is excluded if the build produces it (ANGLE stays).

## 6. How to build the vendor (once)

**On a Windows machine** (a dev box or a Windows VM — the CI never builds Qt),
from the repo root. Unlike `tools/build_ffmpeg_i686.sh` (FFmpeg is C and
cross-compiles from Linux with llvm-mingw), an **MSVC** Qt **cannot** be produced
on Linux: it has to be built with the same toolset the app links against (MSVC
v142 on x86/Win7, the x64 toolset on x64). Estimate on a 12-core desktop:
~10–25 min per architecture (vs ~50–80 min on a 2-vCPU CI runner).

```powershell
tools\build_qt_win64.ps1              # x64  -> third_party\qt-win64
tools\build_qt_win64.ps1 -Arch x86    # x86  -> third_party\qt-win32 (Win7, v142)
```

What the script does:

0. Fetches the build inputs it needs and that Windows does not ship by default:
   the **OpenSSL 1.1.1w development files** (headers + MSVC import libs — see the
   note below) and **winflexbison** (`flex`/`bison`, which ANGLE needs to
   generate its preprocessor). Both are cached under the work tree, so a second
   run is offline. It also expects VS Build Tools with the **v142** toolset and
   the **19041** SDK (see the trap notes at the end of this section).
1. Downloads `qtbase`, `qttools`, `qtimageformats` (+ `qtmultimedia` on x86) as
   the per-module `-everywhere-opensource-src-5.15.19.tar.xz` tarballs,
   **verifies each against a pinned SHA256** and unpacks it; **records each
   module's URL + SHA256** in the BOM.
2. Locates VS via `vswhere`; x86 forces
   `vcvarsall x86 10.0.19041.0 -vcvars_ver=14.29` (v142, the Win7-compatible
   CRT). Ensures Perl (needed by Qt configure) via Git's `usr\bin`.
3. Configures and builds qtbase:
   ```
   -opensource -confirm-license -release -shared -prefix <prefix>
   -platform win32-msvc -opengl dynamic -no-icu -openssl-runtime
   -mp -nomake examples -nomake tests
   ```
   (`-opengl dynamic` keeps ANGLE; `-openssl-runtime` loads OpenSSL at runtime →
   1.1.x or 3.x names, but it **still needs the headers and import libs at build
   time**, without them configure dies at
   `test config.qtbase_network.libraries.openssl_headers FAILED`; `-no-icu` — the
   app needs no ICU (JSON, regex, SQLite, i18n and glyphs are covered by the
   offline CI smoke) and it also **drops the three ICU DLLs from the bundle**
   (`icu{in,uc,dt}.dll`, which the official Qt does link on Windows,
   `src/corelib/configure.json`), i.e. a real installer size reduction; the
   exact delta is confirmed with the first measured build).
4. Builds only `qttools/src/windeployqt`, then `qtimageformats`
   (+ `qtmultimedia` on x86) against the installed prefix. The qttools root
   `qmake` is run first because it writes `qttools-config.pri`, and the
   sub-project is then configured in its own directory
   (`windeployqt.pro` does `include($$OUT_PWD/../../qttools-config.pri)`).
   The root Makefile only exposes coarse targets (`sub-src`, `sub-examples`,
   `sub-tests`) and `src/windeployqt` has no Makefile of its own, so building
   just windeployqt from the root is not possible.
5. Assembles `third_party/qt-win64|qt-win32` with the **Qt-prefix layout**
   (`bin/ lib/ include/ plugins/ mkspecs/`): a whitelist of runtime DLLs +
   the self-contained host tools; `include/private/` stripped; `*.pdb/*.exp/
   *.ilk` removed; `LICENSE.LGPLv3` + `LICENSE.GPL3-EXCEPT` copied.
6. Writes `BOM.json` (version + per-module SHA256 + flags + toolset + OpenSSL
   version + date).
7. On **x86 only**, runs the **Win7 imports gate** with `dumpbin` over
   `bin/*.dll` using the same poison list as the CI (a Qt DLL importing a W8+
   symbol fails here instead of on the Win7 VM).

The work tree is reused when a prefix is already installed in it, so iterating
on the recipe costs minutes instead of half an hour. Delete the work directory
(or pass `-KeepWork` and keep it by hand) for a from-scratch build.

### Traps on Windows (all of them cost a round trip)

| Trap | Symptom | Rule |
|---|---|---|
| `Microsoft.VisualStudio.Component.VC.v142.x86.x64` **does not exist** | the installer accepts it and silently installs nothing; only 14.44 lands | the v142 toolset is versioned: `Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64` |
| `vcvarsall` takes the **newest** SDK by default | 10.0.26100 headers/libs drag W8+/W10 symbols in and the Win7 gate fails | the SDK is a **positional** argument (`vcvarsall x86 10.0.19041.0 -vcvars_ver=14.29`); `-winsdk=` is not a vcvarsall option |
| `vcvarsall` **rebuilds** `INCLUDE`/`LIB` | any path added before the call is wiped | inject after the call, from a multi-line `.bat`: in a one-line `cmd /c`, `%INCLUDE%` expands at parse time, i.e. **before** vcvarsall runs, and the build dies with `Cannot open include file: 'type_traits'` |
| Git for Windows ships a `tar.exe` that **shadows** bsdtar | the Perl fix prepends `Git\usr\bin` to `PATH`; GNU tar 1.35 exits 128 and extracts nothing | call `%SystemRoot%\System32\tar.exe` by absolute path |
| `$ErrorActionPreference='Stop'` + a native command writing to **stderr** | `configure.bat`/`qmake` progress on stderr kills the build even on success | relax the preference around the native call and judge by `$LASTEXITCODE`; `2>&1` alone does not fix it, it just moves the failure |
| a `.ps1` saved as **UTF-8 without BOM** | Windows PowerShell 5.1 reads it as cp1252; a non-ASCII byte sequence decodes to a typographic quote `”` and the parser dies on "string is missing the terminator" | ASCII-only + BOM + CRLF for anything that runs on Windows |
| `"$var: ..."` inside a double-quoted string | `$var:` parses as a *scoped* variable (like `$env:`) and the script fails to parse | `"${var}: ..."` |

## 7. CI integration (APPLIED to windows.yml and windows_x64.yml)

Both `windows.yml` (x86) and `windows_x64.yml` (x64) now do this:

```yaml
# REPLACES:  - uses: jurplel/install-qt-action@v4  (version: '5.15.2' …)
- name: Use the vendored Qt
  shell: pwsh
  run: |
    $qt = "${{ github.workspace }}\third_party\qt-win64"   # qt-win32 on x86
    if (-not (Test-Path "$qt\bin\Qt5Core.dll")) { throw "vendored Qt missing: $qt" }
    "QT_VENDOR=$qt" >> $env:GITHUB_ENV
```

Configure: `-DCMAKE_PREFIX_PATH="$env:QT_VENDOR"`.
Packaging: `& "$env:QT_VENDOR\bin\windeployqt.exe" …` (the tools ship in the
vendor's `bin/`). Smoke: copy `qoffscreen.dll` from
`$env:QT_VENDOR\plugins\platforms\` (the vendor includes it, so the smoke no
longer needs the installed Qt).
`$need` gate: add `Qt5Core.dll Qt5Gui.dll Qt5Widgets.dll Qt5Network.dll
Qt5Sql.dll qwindows.dll libEGL.dll libGLESv2.dll` (x86 also `Qt5Multimedia.dll`).
The existing **W8+ imports gate** already scans every `dist/*.dll`, so it covers
the new Qt DLLs automatically.

**Optional first-run levers** (decide with a measurement, do not assume): the
x64 bundle could drop `opengl32sw.dll` (~20 MB) and `-no-icu` is applied on both.
Neither touches the installer's module set beyond what windeployqt deploys.

### Staged plan (both stages are now DONE, and stage 2 went further than planned)

1. **Qt swap**: `third_party/qt-win64` / `qt-win32` built from the official
   5.15.19 tarballs, SHA256-pinned, and consumed by both workflows through
   `Qt5_DIR` (no `install-qt-action`, no aqtinstall mirror lottery).
2. **OpenSSL swap**: not "download the Light 3.5.x installer" as originally
   planned, but **vendor it** (`third_party/openssl-win64` / `openssl-win32`),
   for the same reason as Qt: a build-time download means a third-party binary
   enters the package on every run, and there is no path to a security patch
   without a release. It is built from the official source tarball (SHA256
   recorded in each `BOM.json`) with the **same toolset as the Qt it serves**
   (v142 + SDK 19041 on x86), and it passed the Win7 import gate.

**Why the OpenSSL swap required rebuilding Qt, and not just swapping DLLs.**
`configure -openssl-runtime` bakes the OpenSSL *DLL name* into `Qt5Network` at
compile time, so a Qt built against 1.1 looks for `libssl-1_1*.dll` and never
finds the 3.x ones. Verified end to end instead of assumed: a test app built
from the vendored tree reported `supportsSsl = yes` with **build == runtime ==
OpenSSL 3.5.9**, which is precisely the failure mode the app's
`tlsHandshakeSelfTest` was written to catch (Qt 5.15.2 + OpenSSL 1.1.1 aborted
with `lock != NULL` on 32-bit x86).

OpenSSL 1.1.1 was EOL since September 2023, so this also retires the
last 1.1-only dependency of the packages.

## 8. BOM

`tools/BOM.template.json` defines the manifest of every component (Qt, mpv,
vendored FFmpeg, OpenSSL, Vulkan, VC redist, Inno). The vendored Qt records its
own provenance in `third_party/qt-win64/BOM.json` (emitted by the build script).
The packaging workflow should **generate `dist/BOM.json`** and, crucially, the
gate should **compare versions against the pin**, not just check that files
exist (today's `$need` only checks presence — a stale piece would ship silently).

## 9. Verification

| What | How |
|---|---|
| Qt tree is complete/usable | the build script fails loudly if an expected DLL/tool is missing; the CI `$need` gate re-checks the deployed set |
| No regression vs 5.15.2 | the offline CI smoke (`--selftest-db/theme/glyphs/dates/i18n/grid/ssl/av1hls`) runs on the rebuilt Qt |
| `-no-icu` | JSON parsing (`--selftest-i18n`), regex (`--selftest-suggest-*`), SQLite (`--selftest-db`) and glyph coverage (`--selftest-glyphs`) |
| Win7 compatibility (x86) | the `dumpbin` gate inside the script **and** the CI W8+ imports gate, then the real Win7 VM |
| No size blow-up | compare the setup size against today's x64 73.5 MiB / x86 28.6 MiB (expected: ±<1%, same DLL set) |
| Real playback | the x64/x86 test machines (sound, ANGLE, live, mini player) |

## 10. Licensing

The app is **GPL-3.0**. Qt is **LGPL-3.0**: dynamic linking (which is what the
vendor implies, and what `windeployqt` already produces) does not impose a
license on the app's own code, so the app could still be relicensed later.
Vendoring an LGPL Qt requires (a) dynamic linking — yes — and (b) a source
offer: the KDE branch is public, and `BOM.json` + this document record the exact
branch, commit and configure flags, which is the "corresponding source"
identification. `libmpv` (ISC) and FFmpeg (LGPL-2.1+) are compatible as well.

## 11. Open decisions

- **x86/Win7 Qt**: build the patched Qt and verify it on the Win7 VM (this
  document assumes yes), or document 5.15.2 as an accepted risk for x86 and only
  rebuild x64 — pending.
- **`qwebp`**: keep (parity, chosen) or drop (the app is designed without it);
  dropping saves ~1 MB and one module build.
- **`-no-icu`** (applied by default): it removes the three ICU DLLs from the
  installer, a genuine size win, and the offline smoke guards JSON/regex/SQLite/
  i18n/glyphs. It is a single flag, so if any locale/IDN regression shows up on
  the test machines, revert it and rebuild.
- **`opengl32sw`**: excluded from the vendor; confirm no size/behavior impact
  after the first measured build.
