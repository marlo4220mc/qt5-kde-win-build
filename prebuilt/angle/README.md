# ANGLE (prebuilt)

`libEGL.dll` and `libGLESv2.dll` from ANGLE, the Khronos EGL/GLES-to-D3D11
translation layer that Qt uses on Windows.

## Why these are prebuilt instead of compiled

**ANGLE cannot be built from Qt's git.** This is not a missing dependency, it is
structural, and it was verified against both repositories:

- Neither the upstream `qt/qtbase` 5.15 branch nor the KDE `kde/5.15` branch
  contains a single `.pro` file under `src/3rdparty/angle/`.
- ANGLE's generator `win32cpp.exe` is in no public tarball. Qt's own official
  5.15.19 `qtbase-everywhere-opensource-src` tarball does not contain it either
  (verified: the only `.exe` in it is `bin/licheck.exe`).

In the *release tarball* ANGLE lives under `src/angle/` together with a generated
`include/QtANGLE`. The release process adds both. Git does not have them, so a
build from a git checkout cannot produce these DLLs by any route.

## What that forces on the build

`src/platformsupport/eglconvenience/qt_egl_p.h` does `#include <EGL/egl.h>` and
its `.pro` only adds `$$QT_MODULE_INCLUDE_BASE/QtANGLE` under `qtConfig(angle)`.
Without `include/QtANGLE` the build dies with:

```
qt_egl_p.h(74): fatal error C1083: Cannot open include file: 'EGL/egl.h'
```

So the recipe overlays `include/QtANGLE` **from the official 5.15.19 tarball**,
which does carry it, and takes the two DLLs from here. Both are the same
ANGLE release Qt 5.15 uses.

If you are on a Windows build without ANGLE, Qt has no OpenGL 2.0+ to fall back
on: the system `opengl32.dll` is the Microsoft GDI 1.1 implementation. That is
why `-opengl dynamic` exists and why these two files are not optional.

## Provenance and licence

ANGLE is Khronos-derived code from Google, **BSD-3-Clause**; see `LICENSE`. Qt
carries it without modifications and neither Qt nor KDE patches it, so a
prebuilt pair is equivalent to one built here.

| file | sha256 |
|---|---|
| `libEGL.dll` | `e0dbd583537658891ce62098ecae7ceee81c61f5ce795168fb5e60d0a0759829` |
| `libGLESv2.dll` | `b197f8cdf85fe02c22154ff5ee0cc1d9b5f65f57b5834f726a9e2704d78d6962` |

The recipe verifies both hashes before copying, so a corrupted or swapped pair
fails the build instead of shipping.
