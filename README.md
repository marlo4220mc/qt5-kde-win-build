# qt5-kde-win-build

Reproducible builds of **Qt 5.15 for Windows** from the KDE maintenance branch,
with verified provenance and a Win7 import gate.

Publishes two ready-to-use trees: **x64** and **x86/Win7**. Any application that
links against Qt can consume them; nothing in them is specific to any project.

> **In other languages:** [Español](README.es.md)

## Two ways in, same result

Someone who just needs Qt on Windows can **download** a tree from the
[releases](https://github.com/marlo4220mc/qt5-kde-win-build/releases) and compile
nothing. Someone who wants to verify the provenance, or needs different modules,
**builds** it with the recipe here and gets an identical tree: the same sources
pinned by commit, the same SHA-256, the same `BOM.json`.

Binaries are not versioned in this repository. What is versioned is **the recipe
and the provenance**, which is what makes a tree verifiable instead of a large
file of trust.

## Why it exists

Qt's official Windows binaries **stopped at 5.15.2**:

```
download.qt.io/online/qtsdkrepository/windows_x86/desktop/
  -> 5.15.0, 5.15.1, 5.15.2 ... and nothing more
```

That repository is what `aqtinstall` and `install-qt-action` read. So "install Qt
in CI" means, in practice, "install 5.15.2", which is 17 patch releases behind
and without the security fixes of 5.15.3 → 5.15.19. The official **sources** are
complete in `download.qt.io/archive`.

The options were: accept 5.15.2, or build. Here it is built, and from the branch
the Linux distribution uses, so Windows and Linux carry the same Qt.

## What it publishes

A **release** with:

- `qt-winx64.7z` and `qt-winx86.7z`: complete Qt prefixes (headers, libs,
  plugins, `mkspecs`, `bin/`).
- Each archive carries its own `BOM.json`, recording what went into it: commit
  per module, the SHA-256 of the archive that commit produces, toolset,
  `configure` flags and OpenSSL version.

To use one:

```sh
cmake -B build -DCMAKE_PREFIX_PATH=/path/to/the/tree
# or, with qmake, use its bin/qmake.exe
```

Nothing inside the tree depends on this repository.

## `qt-sources.json` is the single source of truth

**Pinned** commits, not the tip of the branch. That is what makes "Windows and
Linux carry the same Qt" a checkable statement rather than a hope: the same file
names the commits on both sides, and a diff of the two files is a diff of what
each platform actually builds.

### The label is `5.15.19+kde+r96`

That is **Qt's own** patch-level notation, not a custom scheme: 96 commits sit
on `kde/5.15` after the `v5.15.19-lts-lgpl` tag. So the binaries report
`5.15.19` internally and the BOM reports `+kde+r96`; both describe the same
commit. Those 96 commits are the reason this repository exists: they are fixes
the distribution maintains that never reach an official 5.15 release.

The label cannot be computed by the recipe itself (it downloads archives by
commit instead of cloning, so there is no history), which is why it lives in
`qt-sources.json`.

## Rebuilding by hand

Two steps, in this order. The first provisions the tool tree and verifies every
download by SHA-256; the second compiles.

```powershell
# 1. provisioning: native Perl, OpenSSL, ANGLE - all hash-verified
./ci/bootstrap.ps1 -Arch x64

# 2. build (the recipe's defaults already point at step 1's tree)
.\build-qt-win.ps1 -Arch x64 -Dest C:\qtbuild\out\qt-winx64
```

`-Arch x86` produces the Win7 tree. There the **v142** toolset and the
**10.0.19041** SDK are mandatory: Win7 will not load a binary built with the
modern toolset, which imports `GetSystemTimePreciseAsFileTime` (Win8+).

`-Dest` is explicit on purpose: the default destination is computed against
`<this repo>/third_party/...`, which does not exist here. Run from an SMB share,
`Resolve-Path` produces `\\host\...\..\third_party` — the parent of the share,
not the repo — and `WriteAllText` rejects the `..` in a UNC path with an error
that never mentions the real path.

The parameters that exist, for when the defaults do not do: `-Arch`
(`x64`/`x86`), `-Dest`, `-Work`, `-KeepWork`, `-OpenSslRoot`, `-StrawberryPerl`,
`-AngleBin`, `-QtOfficialTarball`, `-SourcesFile`.

**The recipe fails loudly if the result is incomplete**: it verifies that
`libssl.lib` and `libcrypto.lib` are where `configure` will look for them before
starting. That canary exists because once the bootstrap left the libraries in
`openssl\lib` while the recipe read them from `openssl\nss`: CMake configured
with an empty `LIB`, `Qt5Network` was built **without TLS**, and it only showed
up in the package.

## What you need to know to not lose three builds

These cost a full build (~40 min) each. They are commented in the recipe next to
where they apply.

**1. `syncqt` only runs if there is a `.git`.** `configure.bat` launches it only
if it finds that directory. Without it the forwarding headers are never generated
and the build dies with `C1083` on the first module that includes one — which was
`QtXml`, then `QtWidgets` via `QtPlatformHeaders`, then `QtDBus`, one at a time.
That is why `-no-syncqt` is passed and run by hand, and why the module list is
**derived from the `TARGET` fields of the `.pro` files**: written by hand, one was
missed every time.

**2. `syncqt.pl` lives only in qtbase.** For each module repo you must call
qtbase's, passing that repo as `srcbase`. Without it, `qtmultimedia` ends up
without `include/QtMultimedia` and dies in `qvideoframe.h`.

**3. ANGLE cannot be built from Qt's git.** Neither upstream nor KDE ships a
single `.pro` under `src/3rdparty/angle`, and its generator `win32cpp.exe` is in
no public tarball. See `prebuilt/angle/README.md`, which explains why and what is
done instead.

**4. `nmake install` from a sibling repo installs 3 headers where there are 224.**
`qtmultimedia.pro` declares no `INSTALLS` and its Makefile has no `syncqt` rule.
Without the explicit `Install-ModuleHeaders` step, the x86 package shipped
**without `<QAudioOutput>`**.

**5. In `include/<M>/`, the file named after the header is the _shadow_, not the
header.** The shadow says `#include "../../src/multimedia/audio/qaudio.h"`; the
real header is in `src/`. Copying the shadow to the prefix makes the application
fail with `C1083` at `qaudio.h(1,10)`.

And the detail that cost two attempts: shadows are matched **by their content**,
not by name. Qt writes them in CamelCase (`qaudiodeviceinfo.h` →
`QAudioDeviceInfo`); deriving the file's name produces `Qaudiodeviceinfo`, which
does not exist.

**6. PowerShell variables shadow each other.** `$sources`, `$sslInc` and
`$sslLib` were first declared as locals of the recipe and then as parameters of
the function that used them. The second one wins, and the recipe read an empty
string where it believed it was reading a path: `configure` got an empty `LIB`
and `Qt5Network` came out without TLS, with no error at all. The rule that
prevents it: **content goes in `$script:` or `$env:`, and a parameter that
rewrites the name of an existing variable is a trap, not a shorthand.**

**7. Create the directory before copying into it.** `Copy-Item` to
`tree\bin\libEGL.dll` does not create the destination. With an existing
`-Dest` it worked and with a clean one it failed, which is the hardest kind of
failure: the build you test passes and CI's does not.

## The rule that summarizes all of it

**Only what can be demonstrated is reused.** A source tree is reused only if it
can be proven to be that commit (clean git tree at the recorded commit, or a
retained tarball that has been re-hashed). The prefix is reused only if the
recorded provenance says it was built from those sources. Anything else is
discarded and downloaded again.

This is not purism. The original reason: the recipe reused the tree whenever the
directory existed and **wrote the expected sha256 into the BOM** without checking
anything. The BOM declared the official Qt tarball while the binaries came from
the KDE branch, and the difference was measurable (SQLite 3.49.1 against 3.46.1)
but nobody looked, because the BOM claimed otherwise.

## Automation

| workflow | what it does |
|---|---|
| `watch-kde.yml` | Compares the branch with what is pinned, every Monday. If there is a new commit, it opens an issue **and triggers the rebuild**. |
| `rebuild.yml` | Builds x64 and x86, verifies the BOM and publishes a release. Manually or triggered by the watcher. |

The automated cycle ends at the release, no further. It does **not** reach the
project that consumes the tree: nobody pushes binaries into another repository
without someone deciding it, because automating that would need a token for
another repository and would be exactly the invisible coupling that made the old
BOM lie.

When `invent.kde.org` returns 503 (it happens, during maintenance), the watcher
reports and touches nothing. It cannot create a reference to "fix" a problem that
does not exist.

### What it costs in Actions quota

A rebuild is **several hours of Windows runner**, and Windows bills **×2**
against Linux. That forces a parallel build, and here is a fact that is not
obvious:

**NMAKE is single-threaded and has no flag to change that.** Measured, not
assumed: `nmake` 14.44 declares `/A /B /C /D /E /G /I /K /N /P /Q /R /S /T /U
/Y /W` and **none of them is `/M`**. `/MP` belongs to `cl.exe` and NMAKE rejects
it with `U1065: invalid option 'M'`. And `CL=/MP` would not help either: its
parallelism is *within* one cl invocation, and qmake generates one rule per
`.cpp` that calls cl once with a single source. With plain nmake, a `qtbase` went
from **three hours without finishing** on a 4-core runner.

The build therefore uses **jom**, a drop-in make replacement that is
multi-threaded. `timeout-minutes` in `rebuild.yml` is generous on purpose: a jom
that deadlocks would otherwise eat the whole job.

Measured on the reference machine (4 cores): bootstrap ~29 min cold (it builds
OpenSSL), the Qt build ~28 min. That is ~55 min of wall time per architecture,
which is ~110 billable minutes — the Windows ×2 applied. Cold, i.e. with an empty
cache and no artifacts retained.

## License

Qt is **LGPL-3.0**; these trees use it with **dynamic linking**, which is what
keeps the consumer's own license free of Qt's. Redistributing an LGPL Qt requires
dynamic linking and a source offer: the branch is public, and `BOM.json` records
the exact commit per module, which is the corresponding-source identification.

OpenSSL is **Apache-2.0**. `libmpv` is ISC and FFmpeg is LGPL-2.1+; all
compatible with this scheme.