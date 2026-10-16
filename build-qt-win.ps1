#Requires -Version 5.1
#
# ASCII puro a proposito, y guardado con BOM UTF-8 + CRLF. Windows PowerShell
# 5.1 lee un .ps1 SIN BOM como ANSI (cp1252), y los bytes UTF-8 de un caracter
# no-ASCII se decodifican como caracteres Latin-1: el guion largo (E2 80 94) se
# convierte en una comilla tipografica U+201D, que PowerShell SI acepta como
# delimitador de cadena, y el script deja de parsear. El BOM evita el error de
# codificacion; el ASCII puro evita que un pegado sin BOM vuelva a romperlo.
# regla: en cualquier .ps1 que se ejecute en Windows, solo ASCII.
# ---------------------------------------------------------------------------
# build_qt_win64.ps1 -- builds the VENDORED Qt 5.15 (official LTS sources) for
# the Windows packages that live in third_party/qt-win64/ (x64) and
# third_party/qt-win32/ (x86, Win7).
#
# Why it exists: Qt stopped publishing Windows binaries at 5.15.2 and the
# public 5.15.19 archive is SOURCE ONLY. There is no distro on Windows that
# ships a patched Qt5, so -- exactly like third_party/ffmpeg-win32/ -- it is
# built ONCE and vendored. The CI neither downloads nor compiles Qt: it uses
# the vendored tree directly (see BUILD_QT_WINDOWS.md).
#
# It is the source of truth for the provenance of the vendored Qt: it records
# version + per-module sha256 + flags + toolset in BOM.json inside the tree.
#
# Usage (on Windows, from the repo root):
#   tools\build_qt_win64.ps1                 # x64  -> third_party\qt-win64
#   tools\build_qt_win64.ps1 -Arch x86       # x86  -> third_party\qt-win32 (Win7, v142)
#   tools\build_qt_win64.ps1 -KeepWork       # do not delete the temp work dir
#
# Requirements: Windows, a Visual Studio with the C++ toolset (vswhere),
# Perl (Qt's configure needs it; the Git one is used if there is no other),
# and network access to the Qt sources.
#
# Modules built (the MINIMUM that reproduces the module set of the current
# bundle, verified against qtbase 5.15 source):
#   qtbase          Core Gui Widgets Network Sql + moc/uic/rcc/qmake + ANGLE
#                   (qjpeg/qgif/qico plugins live HERE)
#   qttools         ONLY src/windeployqt (it is a `force_bootstrap` tool:
#                   links Qt5Core only, so it does NOT drag Qt5Svg)
#   qtimageformats  qwebp + friends (libwebp is vendored INSIDE the module)
#   qtmultimedia    x86 ONLY (the app uses QAudioOutput there)
# qtsvg is deliberately NOT built: the app has no Svg dependency, so the
# packages stay free of Qt5Svg.dll (same criterion as today).
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
  [ValidateSet('x64', 'x86')][string]$Arch = 'x64',
  # Official Qt release sources (the 5.15 LTS line). Fetched as the per-module
  # "everywhere" tarballs, NOT through git: see the "--- sources ---" section.
  [string]$QtVersion = '5.15.19',
  [string]$SrcBase = 'https://download.qt.io/archive/qt/5.15',
  # KDE maintenance branch. It is the SAME source the Linux package uses
  # (Arch builds qt5-base 5.15.19+kde+rNN from here at a pinned commit), so with
  # it the Windows bundles get the same curated security/crash backports.
  # Empty = fall back to the official release tarballs above.
  [string]$KdeBranch = 'kde/5.15',
  # The path is NOT invent.kde.org/qt/qtbase: it is group qt, subgroup qt,
  # project qtbase. Both wrong guesses answer the same misleading
  # "project not found or you don't have permission", which reads exactly like
  # a permissions problem. The shape comes from the Arch PKGBUILD, which builds
  # the Linux package from git+https://invent.kde.org/qt/qt/${pkgname/5-/}.
  [string]$KdeBase = 'https://invent.kde.org/qt/qt',
  # The exact commits the Linux package is built from. Pinning the commit and
  # not the branch tip is what makes "Windows and Linux ship the same Qt" true by
  # construction instead of true only on the day you compiled it. Taken from the
  # Arch PKGBUILDs (qt5-base / qt5-tools / qt5-imageformats / qt5-multimedia).
  # Los commits se leen de qt-sources.json (ver mas abajo), no estan aqui.
  [hashtable]$KdeCommit = $null,
  # OpenSSL development files (headers + MSVC import libs), per-arch
  # subdirectory. Qt is configured with -openssl-runtime, which still needs
  # them AT BUILD TIME even though the DLLs are only loaded at run time.
  # This tree is built against OpenSSL 3.5.9; the app repo ships those DLLs next
  # to Qt5Network (third_party/openssl-win32 / -win64) and Qt loads them at run
  # time, so the build-time version only has to be ABI-compatible. The comment
  # used to say 1.1.1 and was simply wrong.
  [string]$OpenSslRoot = 'C:\qtbuild\openssl',
  # Native Windows Perl (Strawberry). Needed by Qt's configure; Git's perl is an
  # MSYS build and returns POSIX paths, which corrupts syncqt's forwarding headers.
  [string]$StrawberryPerl = 'C:\qtbuild\tools\sp',
  # libEGL.dll / libGLESv2.dll. ANGLE NO se construye desde el arbol de git de
  # Qt: ni el git de upstream ni el de KDE traen los .pro de ANGLE (comprobado:
  # la rama 5.15 de qt/qtbase no tiene ni un .pro bajo src/3rdparty/angle/), y
  # su generador win32cpp.exe no esta en ningun tarball publico. En el tarball
  # oficial ANGLE vive en src/angle/ y trae ademas include/QtANGLE, que es justo
  # lo que src/platformsupport/eglconvenience espera
  # ($$QT_MODULE_INCLUDE_BASE/QtANGLE). De ahi se toma el include; las DLL se
  # toman de aqui. ANGLE es codigo de Khronos: ni Qt ni KDE lo parchean.
  [string]$AngleBin = 'C:\qtbuild\angle-prebuilt',
  [string]$QtOfficialTarball = 'C:\qtbuild\toolgrab\qtbase-official.tar.xz',
  # Destination tree (default depends on -Arch).
  [string]$Dest,
  [string]$Work,
  [switch]$KeepWork
)

  # --- commits fijados -----------------------------------------------------
  # Los commits ya NO estan escritos aqui: viven en qt-sources.json, que es la
  # unica fuente de verdad y la que lee tambien el watcher. Tenerlos en dos
  # sitios es justo el modo de fallo del BOM antiguo: dos ficheros que dicen
  # cosas distintas y nadie se entera hasta que algo revienta.
  $sourcesFile = Join-Path $PSScriptRoot 'qt-sources.json'
  if (-not (Test-Path $sourcesFile)) { throw "no encuentro $sourcesFile" }
  $sources = Get-Content $sourcesFile -Raw | ConvertFrom-Json
  if (-not $KdeCommit -or $KdeCommit.Count -eq 0) {
    $KdeCommit = @{}
    foreach ($p in $sources.modules.PSObject.Properties) { $KdeCommit[$p.Name] = $p.Value }
  }
  if (-not $KdeBranch) { $KdeBranch = $sources.branch }
  if (-not $KdeBase)   { $KdeBase   = $sources.base }

  # La etiqueta de version va en qt-sources.json y NO se calcula aqui a proposito:
  # es 'git rev-list --count v5.15.19-lts-lgpl..<commit>', y esta receta descarga
  # archivos por commit en vez de clonar, asi que no hay historial contra el que
  # correrlo. Con 5.15.19+kde+r96 el BOM deja de decir "5.15.19", que es lo que
  # declara MODULE_VERSION en .qmake.conf y por eso leen los DLL: eso no afirma
  # que el arbol sea el corte de 5.15.19, y no lo es.


$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say([string]$m) { Write-Host "==> $m" }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Dest) {
  $Dest = Join-Path $repoRoot $(if ($Arch -eq 'x64') { 'third_party\qt-win64' } else { 'third_party\qt-win32' })
}
# $tmp is needed later (the KDE access probe writes its scratch file there), so
# it must be resolved unconditionally: it used to be assigned inside the
# `if (-not $Work)`, and passing -Work from the build task left it undefined and
# the run died on `Join-Path $tmp ...` several minutes in.
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
if (-not $Work) {
  $Work = Join-Path $tmp "qt-build-$Arch"
}

# --- per-arch configuration -------------------------------------------------
$cfg = if ($Arch -eq 'x64') {
  @{
    Prefix       = Join-Path $Work 'prefix'
    VcArch       = 'x64'
    VcVarsVer    = ''            # latest toolset (x64 targets Win10+, no Win7 pin)
    SdkVersion   = ''            # latest SDK (no Win7 gate on this arch)
    # Qt runtime DLLs + ANGLE that go into the vendor's bin/.
    QtDlls       = @('Qt5Core', 'Qt5Gui', 'Qt5Widgets', 'Qt5Network', 'Qt5Sql')
    ExtraDlls    = @('libEGL', 'libGLESv2', 'D3Dcompiler_47')  # D3Dcompiler optional
    Modules      = @('qtbase', 'qttools', 'qtimageformats')
    Win7Gate     = $false
  }
} else {
  @{
    Prefix       = Join-Path $Work 'prefix'
    VcArch       = 'x86'
    VcVarsVer    = '14.29'       # v142 (VS2019): mandatory for the Win7 CRT
    # Win7-safe Windows SDK, pinned as the vcvarsall positional argument. With
    # both 19041 and 26100 installed, vcvarsall would otherwise take 26100 and
    # the Win7 import gate would fail. 19041 is the oldest SDK of the channel
    # and the one that ships with the VS2019/v142 era.
    SdkVersion   = '10.0.19041.0'
    QtDlls       = @('Qt5Core', 'Qt5Gui', 'Qt5Widgets', 'Qt5Network', 'Qt5Sql', 'Qt5Multimedia')
    ExtraDlls    = @('libEGL', 'libGLESv2', 'D3Dcompiler_47')
    Modules      = @('qtbase', 'qttools', 'qtimageformats', 'qtmultimedia')
    Win7Gate     = $true
  }
}

$configureFlags = @(
  '-opensource', '-confirm-license',
  '-release', '-shared',
  '-prefix', $cfg.Prefix,
  '-platform', 'win32-msvc',          # the only desktop MSVC mkspec in 5.15
  '-opengl', 'dynamic',               # keeps ANGLE (libEGL/libGLESv2)
  '-no-icu',                          # the app needs no ICU (JSON/regex/i18n are fine); ~15 MB less
  '-openssl-runtime',                 # load OpenSSL at runtime (1.1.x or 3.x names)
  '-mp',                              # nmake with /MP
  '-no-syncqt',                       # we run syncqt.pl ourselves, with a NATIVE perl
  '-nomake', 'examples',
  '-nomake', 'tests'
) -join ' '

# --- toolchain -------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere no esta (Visual Studio sin el workload de C++)" }
$vsPath = & $vswhere -latest -products * `
  -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "no se hallo un VS con el toolset VC" }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $vcvars)) { throw "no esta $vcvars" }
$vcArgs = $cfg.VcArch
if ($cfg.VcVarsVer) { $vcArgs += " -vcvars_ver=$($cfg.VcVarsVer)" }
# The Windows SDK is a POSITIONAL argument of vcvarsall (its own usage line:
# [arch] [platform_type] [winsdk_version] [-vcvars_ver=...]); "-winsdk=..." is
# NOT a vcvarsall option and is rejected. Without this, vcvarsall silently
# picks the NEWEST SDK installed (10.0.26100.0), whose ucrt/um pull Win8+/Win10
# only symbols into the DLLs and the Win7 import gate below fails on them.
if ($cfg.SdkVersion) { $vcArgs += " $($cfg.SdkVersion)" }

# Qt's configure needs Perl to run syncqt.pl, which generates the forwarding
# headers. WHICH perl matters and it is not obvious:
#
#   Git's perl.exe  -> Cwd::getcwd() returns /c/qtbuild/work/x64/qtbase  (MSYS)
#   Strawberry's    -> Cwd::getcwd() returns C:/qtbuild/work/x64/qtbase  (native)
#
# syncqt.pl takes that as <srcbase> and writes the forwarding headers with
# relative paths computed from it, so with Git's perl every header comes out as
#   #include "../../../../../../../c/qtbuild/.../qglobal.h"
# and the qmake bootstrap dies with C1083. Measured, not assumed.
#
# configure.bat picks the FIRST perl.exe in PATH (it does
# `for %%C in (... perl.exe ...) do set %%C=%%~$PATH:C`), so the native one has
# to come FIRST, ahead of Git's usr/bin.
$script:nativePerlBin = Join-Path $StrawberryPerl 'perl\bin'
$script:nativePerl = Join-Path $script:nativePerlBin 'perl.exe'
if (-not (Test-Path $script:nativePerl)) {
  throw "no encuentro un Perl nativo en $script:nativePerl (el de Git devuelve rutas POSIX y rompe syncqt)"
}
# Se invoca SIEMPRE por ruta absoluta. Resolverlo con Get-Command sobre un PATH
# modificado es fragile: en la ejecucion real se cogio el de Git y el include
# salio con /c/... otra vez.
$env:Path = "$script:nativePerlBin;$env:Path"
$gitPerl = Join-Path $env:ProgramFiles 'Git\usr\bin'
if (Test-Path (Join-Path $gitPerl 'perl.exe')) { $env:Path = "$gitPerl;$env:Path" }

# Every MSVC step runs in a fresh `cmd` with vcvars loaded (the environment
# does not persist between invocations). $CommandLine is passed as-is, so the
# caller must quote paths that contain spaces (e.g. `"$qmake" x.pro`).
function Invoke-Msvc([string]$CommandLine) {
  # Why a .bat and not a one-liner: vcvarsall REBUILDS INCLUDE/LIB from scratch,
  # so OpenSSL has to be added AFTER it. And it cannot be done with
  #   cmd /c "call vcvars... && set INCLUDE=<ssl>;%INCLUDE% && ..."
  # because cmd expands %INCLUDE% when it PARSES the line, i.e. BEFORE vcvarsall
  # has run: the result is INCLUDE=<ssl> only, the MSVC standard library
  # disappears and the first compile dies with
  #   qglobal.h(45): fatal error C1083: Cannot open include file: 'type_traits'
  # In a .bat each line is parsed when it EXECUTES, so %INCLUDE% is the value
  # vcvarsall just set. That is the whole reason for the temp file.
  $bat = Join-Path $script:batDir ("msvc-{0}.bat" -f [guid]::NewGuid().ToString('N'))
  $lines = @('@echo off', "call `"$vcvars`" $vcArgs >nul")
  if ($script:sslInc -and $script:sslLib) {
    $lines += "set `"INCLUDE=$($script:sslInc);%INCLUDE%`""
    $lines += "set `"LIB=$($script:sslLib);%LIB%`""
  }
  $lines += $CommandLine
  $lines += 'exit /b %ERRORLEVEL%'
  Set-Content -Encoding ASCII -Path $bat -Value $lines
  Write-Verbose (($lines -join ' | '))
  # Relax $ErrorActionPreference just for the native command. Two PowerShell
  # behaviours collide here and BOTH kill the build on a successful command:
  #   * without 2>&1, anything the tool writes to stderr is wrapped as a
  #     NativeCommandError record, and 'Stop' promotes it to a TERMINATING error
  #     (configure.bat and qmake print progress/warnings on stderr constantly);
  #   * with 2>&1 the stderr lines DO reach the pipeline as error records, and
  #     'Stop' does the same thing to the first of them.
  # The authoritative verdict is $LASTEXITCODE, checked right after.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $noArgs = @()
  $code = Invoke-Native $bat $noArgs
  } finally {
    $ErrorActionPreference = $prev
    Remove-Item $bat -Force -ErrorAction SilentlyContinue
  }
  if ($code -ne 0) { throw "fallo (exit $code): $CommandLine" }
}

# Runs a native command and returns its exit code, without letting its stderr
# abort the script. See Invoke-Msvc for the full explanation; the same rule
# applies to every native call here (tar, cl), not only to the MSVC steps.
function Invoke-Native([string]$Exe, [string[]]$NativeArgs) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Exe @NativeArgs 2>&1 | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
}

# --- openssl (development files) -------------------------------------------
#
# `configure -openssl-runtime` does not mean "no OpenSSL at build time": it means
# the DLL is loaded dynamically at RUN time, but qtbase still compiles the
# OpenSSL integration, so configure looks for openssl/ssl.h + opensslv.h and
# later links against libssl/libcrypto. Without them configure dies with
#   test config.qtbase_network.libraries.openssl_headers FAILED
# 1.1.1w is used on purpose: that is the version the app already ships today.
$script:sslDir  = Join-Path $OpenSslRoot $Arch
$script:sslInc  = Join-Path $script:sslDir 'app\include'
$script:sslLib  = Join-Path $script:sslDir 'app\lib'
$sslInc  = Join-Path $sslDir 'app\include'
$sslLib  = Join-Path $sslDir 'app\lib'
$sslFile = if ($Arch -eq 'x64') { 'Win64OpenSSL-1_1_1w.exe' } else { 'Win32OpenSSL-1_1_1w.exe' }
if (-not (Test-Path (Join-Path $sslInc 'openssl\ssl.h'))) {
  Say "OpenSSL dev no esta en $sslDir; descargando $sslFile"
  $tools = Join-Path (Split-Path $Work -Parent) 'tools'
  New-Item -ItemType Directory -Force -Path $tools | Out-Null
  $inno = Join-Path $tools 'innoextract.exe'
  if (-not (Test-Path $inno)) {
    $zip = Join-Path $tools 'innoextract.zip'
    & curl.exe -sL -o $zip 'https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-windows.zip'
    if ($LASTEXITCODE -ne 0) { throw "no se pudo descargar innoextract (exit $LASTEXITCODE)" }
    Expand-Archive $zip (Join-Path $tools 'innoextract') -Force
    $f = Get-ChildItem (Join-Path $tools 'innoextract') -Filter 'innoextract.exe' -Recurse |
         Select-Object -First 1
    Copy-Item $f.FullName $inno -Force
  }
  $sslExe = Join-Path $tools $sslFile
  if (-not (Test-Path $sslExe)) {
    & curl.exe -sL -o $sslExe "https://slproweb.com/download/$sslFile"
    if ($LASTEXITCODE -ne 0) { throw "no se pudo descargar $sslFile (exit $LASTEXITCODE)" }
  }
  if (Test-Path $sslDir) { Remove-Item $sslDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $sslDir | Out-Null
  Say "extrayendo OpenSSL dev en $sslDir"
  $ieArgs = @('--output-dir', $sslDir, $sslExe)
  $ieCode = Invoke-Native $inno $ieArgs
  if ($ieCode -ne 0) { throw "innoextract fallo (exit $ieCode)" }
}
if (-not (Test-Path (Join-Path $sslInc 'openssl\ssl.h'))) {
  throw "OpenSSL dev incompleto: no hay openssl\ssl.h en $sslInc"
}
$sslVersion = ((Select-String -Path (Join-Path $sslInc 'openssl\opensslv.h') `
                -Pattern '#\s*define\s+OPENSSL_VERSION_TEXT\s+"([^"]+)"').Matches[0].Groups[1].Value)
Say "OpenSSL dev: $sslVersion (headers $sslInc / libs $sslLib)"

# --- flex/bison (ANGLE) ----------------------------------------------------
#
# The tree keeps ANGLE (-opengl dynamic, which is what ships libEGL/libGLESv2
# today), and ANGLE GENERATES two files at build time: the preprocessor
# Tokenizer.cpp with flex and the grammar with bison. Qt does not ship them
# pre-generated, and with them missing nmake dies with
#   'flex' is not recognized as an internal or external command
#   NMAKE : fatal error U1077: 'flex --noline --nounistd --outfile=release\Tokenizer.cpp'
# winflexbison is a portable zip (no installer): win_flex.exe/win_bison.exe are
# copied to flex.exe/bison.exe because that is the name ANGLE invokes.
$toolsDir = Join-Path (Split-Path $Work -Parent) 'tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
$flexDir = Join-Path $toolsDir 'winflexbison'
if (-not (Test-Path (Join-Path $flexDir 'flex.exe'))) {
  $zip = Join-Path $toolsDir 'winflexbison.zip'
  Say "descargando winflexbison (flex/bison para ANGLE)..."
  & curl.exe -sL -o $zip 'https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip'
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip)) {
    throw "no se pudo descargar winflexbison (exit $LASTEXITCODE)"
  }
  Expand-Archive $zip (Join-Path $toolsDir 'wfb') -Force
  $f = Get-ChildItem (Join-Path $toolsDir 'wfb') -Filter 'win_flex.exe' -Recurse |
       Select-Object -First 1
  if (-not $f) { throw 'winflexbion: no encuentro win_flex.exe en el zip' }
  $flexDir = $f.DirectoryName
  Copy-Item (Join-Path $flexDir 'win_flex.exe')  (Join-Path $flexDir 'flex.exe')  -Force
  Copy-Item (Join-Path $flexDir 'win_bison.exe') (Join-Path $flexDir 'bison.exe') -Force
}
# vcvarsall does not touch PATH beyond prepending its own dirs, so extending
# PATH here is inherited by every cmd/nmake child.
$env:Path = "$flexDir;$env:Path"
foreach ($tool in @('flex.exe','bison.exe')) {
  $c = Get-Command $tool -ErrorAction SilentlyContinue
  if (-not $c) { throw "$tool no queda disponible tras preparar $flexDir" }
}
Say "flex/bison listos en $flexDir"

$script:batDir = Join-Path (Split-Path $Work -Parent) 'bat'
New-Item -ItemType Directory -Force -Path $script:batDir | Out-Null

# --- sources ---------------------------------------------------------------
# KDE's invent.kde.org requires an account for EVERYTHING (git, web, API and the
# archive endpoint all answer "Sign in"), which is why the recipe fell back to the
# official tarballs. With a read_repository token the branch is used again and the
# Windows bundles match Linux.
# Whether the branch is usable is decided by PROBING it, not by looking for a
# token variable. The credential normally lives in the Windows Credential
# Manager (Git Credential Manager, credential.helper=manager), filled in once by
# the user in their own session; there is no token in a file, in the
# environment, or on the command line. A probe is also the only check that
# cannot be fooled by a stale credential: if it stops working the probe says so
# and the build falls back to the official tarballs instead of dying.
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE    = 'never'   # never prompt: a build must not block on a dialog
$KdeUrl = ''
if ($KdeBranch) {
  $probeMod = $cfg.Modules | Select-Object -First 1
  $probeUrl = "$KdeBase/$probeMod.git"
  $probeErr = Join-Path $tmp 'kde-probe.txt'
  # La sonda esta DISEÑADA para tolerar el fallo (si no hay acceso, se cae al
  # tarball oficial), pero con ErrorActionPreference='Stop' el stderr de un
  # comando nativo se convierte en error terminante y aborta el script entero.
  # Es la misma trampa de siempre: hay que bajar la preferencia, no el error.
  # Se reintenta tambien: invent.kde.org devuelve 503 de vez en cuando.
  $probe = $null
  foreach ($try in 1..3) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $probe = & git ls-remote --heads $probeUrl $KdeBranch 2>$probeErr
    $probeRc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($probeRc -eq 0 -and $probe) { break }
    if ($try -lt 3) {
      Say "  la sonda fallo (exit $probeRc), reintento $try/3"
      Start-Sleep -Seconds (5 * $try)
    }
  }
  if ($probeRc -eq 0 -and $probe) {
    $KdeUrl = $KdeBase
    Say "fuentes: $KdeBase rama $KdeBranch, por ARCHIVO DE COMMIT (acceso verificado con git ls-remote)"
  } else {
    $why = ((Get-Content $probeErr -Raw -ErrorAction SilentlyContinue) -split "`n" |
            Where-Object { $_ -match 'remote:|fatal:|error:' } | Select-Object -First 1)
    Say ("fuentes: tarballs oficiales $QtVersion" +
         $(if ($why) { "  (invent.kde.org no accesible: " + $why.Trim() + ")" }
                   else { "  (invent.kde.org no accesible)" }))
  }
} else {
  Say "fuentes: tarballs oficiales $QtVersion"
}
# The work tree is only wiped when there is no installed prefix in it. Reusing
# it makes an iteration cost minutes instead of half an hour, which is the
# difference between fixing a recipe and giving up on it. Delete $Work by hand
# for a from-scratch build.
$qmakePath = Join-Path $cfg.Prefix 'bin\qmake.exe'
if (Test-Path $qmakePath) {
  Say "reutilizo el arbol de trabajo ya construido en $Work (borralo para empezar de cero)"
} else {
  if (Test-Path $Work) { Remove-Item $Work -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $Work | Out-Null
#
# The sources are the OFFICIAL Qt release tarballs, pinned by the SHA256 that Qt
# publishes next to each one. They are NOT fetched with git, and that is a hard
# requirement learned the hard way:
#   * invent.kde.org (the "kde/5.15" maintenance branch this recipe used first)
#     answers "HTTP Basic: Access denied" to an anonymous HTTPS clone. Git then
#     asks the Windows credential manager for a token, and under a
#     non-interactive SYSTEM account that prompt NEVER resolves: the clone hangs
#     forever with 0 bytes written (a "slow network" that is really a deadlock).
#   * the github.com/qt mirror does not carry the kde/5.15 branch at all.
# download.qt.io serves the 5.15 LTS sources over plain HTTPS, no account, and
# the SHA256 is verifiable, so the provenance is stronger than "a branch tip".
$qtSha256 = @{
  'qtbase'         = '51e91c73abacab81e64efd01bf95794e79c0e605ad80947a024769f0dd620a32'
  'qttools'        = '2694af886130d63b8a42bcd138f4035fd8108273ebd16781f87300da352f1aa6'
  'qtimageformats' = 'e7535711cb638a90da172dfb926ff57f37478b6591a4199089876708d89cb45e'
  'qtmultimedia'   = 'dbfa442dff7d8204b23fbfa71389bdcc92fbc9f84036d5220d9c9fdbf9a5fb35'
}
$sources = @{}
$wc = New-Object Net.WebClient

# --- provenance of the work tree ------------------------------------------
# The failure this fixes: a work tree left behind by an EARLIER run (a git
# clone of the 5.15 branch, say) was reused as if it were the pinned tarball,
# and the BOM then recorded the pinned SHA256 without anybody having checked it.
# The result was a BOM that described something other than the binaries: the
# tree carried SQLite 3.49.1 / libpng 1.6.47 while the BOM claimed a 5.15.19
# tarball, which carries 3.46.1 / 1.6.44.
#
# Rule from now on: a tree may be reused ONLY if its content can be PROVED to be
# the tree it claims to be. If it cannot be proved, it is deleted and refetched.
# There is no third path, and in particular there is no path that writes a hash
# into the BOM that was not just verified against the bytes on disk.
$provFile = Join-Path $Work 'provenance.json'

function Get-WorkProvenance {
  if (-not (Test-Path $provFile)) { return @{} }
  try { return (Get-Content $provFile -Raw | ConvertFrom-Json) } catch { return @{} }
}

function Set-WorkProvenance {
  $o = [ordered]@{}
  foreach ($k in $script:prov.Keys) {
    $e = $script:prov[$k]
    $o[$k] = [ordered]@{ kind = $e.kind; url = $e.url; branch = $e.branch
                        commit = $e.commit; sha256 = $e.sha256; built = [bool]$e.built }
  }
  $o | ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII -Path $provFile
}

function Get-Sha256([string]$path) {
  return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
}

$storedProv = Get-WorkProvenance
$script:prov = @{}

# Identity of what we are about to build, to decide whether the prefix in front
# of us was built from THESE sources or from something older.
$built = [ordered]@{}

if ($KdeUrl) {
  # The KDE branch, taken as the COMMIT ARCHIVE rather than as a git clone.
  #
  # Why the archive and not a clone (measured, not assumed): with a .git present
  # the Qt 5 configure takes a different path to work out srcbase, and on this
  # machine it came out as /c/qtbuild/... instead of C:/qtbuild/..., which made
  # syncqt emit forward includes like
  #     #include "../../../../../../../c/qtbuild/.../qglobal.h"
  # and the qmake bootstrap died with C1083 before compiling a single thing.
  # It is NOT git returning a POSIX path -- `git rev-parse --show-toplevel` in
  # that very tree answers C:/qtbuild/work/x64/qtbase correctly. The archive has
  # no .git, so configure behaves like it did in the build that worked.
  #
  # Provenance: the COMMIT is the identity (fetchable and verifiable at any
  # time, and it is the same commit the Linux package is built from). The
  # tarball's own SHA256 is recorded too and re-checked on every reuse, but a
  # GitLab-generated archive is not guaranteed byte-stable across GitLab
  # versions, so the commit is what the BOM means by "this is where it came from".
  foreach ($m in $cfg.Modules) {
    $dir  = Join-Path $Work $m
    $want = if ($KdeCommit.ContainsKey($m)) { $KdeCommit[$m] } else { '' }
    if (-not $want) {
      throw "no hay commit fijado para $m : anadelo a -KdeCommit o la build no seria reproducible"
    }
    $url   = "$KdeBase/$m/-/archive/$want/$m-$want.tar.gz"
    $local = Join-Path $Work "$m-$want.tar.gz"

    $prior = if ($storedProv.PSObject.Properties.Name -contains $m) { $storedProv.$m } else { $null }
    if ((Test-Path $local) -and (Test-Path $dir) -and $prior -and
        $prior.kind -eq 'git-archive' -and $prior.commit -eq $want) {
      $got = Get-Sha256 $local
      if ($got -eq $prior.sha256) {
        Say "  ${m}: ya extraido del commit $($want.Substring(0,12)), tarball reverificado"
        $sources[$m] = @{ url = $url; branch = $KdeBranch; commit = $want }
        $script:prov[$m] = @{ kind = 'git-archive'; url = $url; branch = $KdeBranch
                              commit = $want; sha256 = $got; built = $prior.built }
        if ($prior.built) { $built[$m] = $true }
        continue
      }
      Say "  ${m}: el tarball ya no coincide con el SHA registrado, se descarta"
    } elseif (Test-Path $dir) {
      Say "  ${m}: hay un arbol sin tarball verificado, se descarta"
    }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $local -Force -ErrorAction SilentlyContinue

    Say "descargando $m @ $($want.Substring(0,12)) ($KdeBase/$m)"
    $wc.DownloadFile($url, $local)
    $got = Get-Sha256 $local
    Say "  ${m}: $([Math]::Round((Get-Item $local).Length/1MB)) MB  sha256 $($got.Substring(0,12))"
    Say "extrayendo $m"
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    $tarArgs = @('-xf', $local, '-C', $Work)
    $tarCode = Invoke-Native $tarExe $tarArgs
    if ($tarCode -ne 0) { throw "tar fallo al extraer $m (exit $tarCode)" }
    $top = Get-ChildItem $Work -Directory | Where-Object { $_.Name -like "$m-*" } |
           Select-Object -First 1
    if (-not $top) { throw "el archivo de $m no extrajo ningun directorio" }
    if ($top.Name -ne $m) { Rename-Item -LiteralPath $top.FullName -NewName $m }
    # Join-Path in Windows PowerShell 5.1 takes only TWO positional arguments
    # (-Path and -ChildPath). The third one, -AdditionalChildPath, was added in
    # PowerShell 6, so `Join-Path $Work $m '.git'` dies with
    # "A positional parameter cannot be found that accepts argument '.git'".
    if ($m -eq 'qtbase') {
      # Sin include/QtANGLE, src/platformsupport/eglconvenience/qt_egl_p.h hace
      #   #include <EGL/egl.h>
      # y nmake muere con C1083. Es el UNICO fichero que se toma del tarball
      # oficial, y esta justificado en el parametro $AngleBin.
      $ovl = Join-Path $Work 'qtangle-overlay'
      if (Test-Path $ovl) { Remove-Item $ovl -Recurse -Force }
      New-Item -ItemType Directory -Force -Path $ovl | Out-Null
      $tarExe2 = Join-Path $env:SystemRoot 'System32\tar.exe'
      $entries = @(& $tarExe2 -tf $QtOfficialTarball 2>$null | Where-Object { $_ -match 'include/QtANGLE/' })
      if (-not $entries) { throw "no encuentro include/QtANGLE en $QtOfficialTarball" }
      $listFile = Join-Path $ovl 'list.txt'
      $entries | Set-Content -Encoding ASCII -Path $listFile
      $c3 = Invoke-Native $tarExe2 @('-xf', $QtOfficialTarball, '-C', $ovl, '-T', $listFile)
      if ($c3 -ne 0) { throw "tar fallo al extraer include/QtANGLE (exit $c3)" }
      $from = Get-ChildItem $ovl -Recurse -Directory -Filter 'QtANGLE' -ErrorAction SilentlyContinue |
              Select-Object -First 1
      if (-not $from) { throw "no se extrajo include/QtANGLE" }
      Copy-Item $from.FullName (Join-Path $dir 'include\QtANGLE') -Recurse -Force
      Remove-Item $ovl -Recurse -Force
      if (-not (Test-Path (Join-Path $dir 'include\QtANGLE\EGL\egl.h'))) {
        throw "el overlay de include/QtANGLE no trae EGL/egl.h"
      }
      Say "  overlay include\QtANGLE desde el tarball oficial (lo exige eglconvenience)"
    }
    $gitDir = Join-Path (Join-Path $Work $m) '.git'
    if (Test-Path $gitDir) {
      throw "$m trae un .git tras extraerlo: eso rompe el configure (ver el comentario de arriba)"
    }
    $sources[$m] = @{ url = $url; branch = $KdeBranch; commit = $want }
    $script:prov[$m] = @{ kind = 'git-archive'; url = $url; branch = $KdeBranch
                          commit = $want; sha256 = $got; built = $false }
    Say "  $m listo"
  }
} else {
  foreach ($m in $cfg.Modules) {
    $file  = "$m-everywhere-opensource-src-$QtVersion.tar.xz"
    $url   = "$SrcBase/$QtVersion/submodules/$file"
    $local = Join-Path $Work $file
    # The tarball is KEPT after extracting (it is what the tree can be proved
    # against), so a reuse re-hashes the bytes instead of trusting the directory.
    $want = $qtSha256[$m]
    $prior = if ($storedProv.PSObject.Properties.Name -contains $m) { $storedProv.$m } else { $null }
    if ((Test-Path $local) -and (Test-Path (Join-Path $Work $m)) -and $prior -and
        $prior.kind -eq 'tarball' -and $prior.sha256 -eq $want) {
      $got = Get-Sha256 $local
      if ($got -eq $want) {
        Say "  ${m}: ya extraido, tarball reverificado (sha256 ok)"
        $sources[$m] = @{ url = $url; sha256 = $got }
        $script:prov[$m] = @{ kind = 'tarball'; url = $url; branch = $null
                              commit = $null; sha256 = $got; built = $prior.built }
        if ($prior.built) { $built[$m] = $true }
        continue
      }
      Say "  ${m}: el tarball no coincide con el SHA fijado, se descarta"
    } elseif (Test-Path (Join-Path $Work $m)) {
      Say "  ${m}: hay un arbol sin tarball verificado, se descarta"
    }
    Remove-Item (Join-Path $Work $m) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $local -Force -ErrorAction SilentlyContinue
    Say "descargando $file"
    $wc.DownloadFile($url, $local)
    $got = Get-Sha256 $local
    if ($got -ne $want) { throw "SHA256 de ${file}: esperado $want, obtenido $got" }
    Say "  ${m}: sha256 verificado"
    Say "  extrayendo $file"
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $tarExe)) { throw "no se halla bsdtar en $tarExe" }
    $tarArgs = @('-xf', $local, '-C', $Work)
    $tarCode = Invoke-Native $tarExe $tarArgs
    if ($tarCode -ne 0) { throw "tar fallo al extraer $file (exit $tarCode)" }
    $top = Get-ChildItem $Work -Directory | Where-Object { $_.Name -like "$m-*" } |
           Select-Object -First 1
    if (-not $top) { throw "el tarball de $m no extrajo ningun directorio" }
    if ($top.Name -ne $m) { Rename-Item -LiteralPath $top.FullName -NewName $m }
    # the tarball stays on purpose: it is the evidence of what was extracted
    $sources[$m] = @{ url = $url; sha256 = $got }
    $script:prov[$m] = @{ kind = 'tarball'; url = $url; branch = $null
                          commit = $null; sha256 = $got; built = $false }
    Say "  $m listo"
  }
}

# cl version of the toolset actually used (goes into the BOM).
$clOut = & cmd /c "call `"$vcvars`" $vcArgs >nul && cl 2>&1" 2>$null
$clMatch = $clOut | Select-String -Pattern 'Compiler Version (\S+)' | Select-Object -First 1
$clVersion = if ($clMatch) { $clMatch.Matches[0].Groups[1].Value } else { 'unknown' }
Say "toolset: cl $clVersion ($vcArgs)"

# --- forwarding headers por modulo ------------------------------------------
# El syncqt que lanza configure.bat es "-minimal -module QtCore": solo QtCore,
# que es lo que necesita el bootstrap de qmake. Los dems modulos los genera el
# propio build con la regla syncqt de cada Makefile... y aqui no lo hace (en el
# log no aparece ni una vez "syncqt"), asi que include/QtXml se queda vacio y
# src/xml/dom/qdom.cpp, que hace #include <qdom.h> CON ANGLETS (y por tanto no
# busca en su propio directorio, solo en los -I), revienta con C1083.
#
# La lista de modulos se DERIVA de los .pro (campo TARGET) en vez de escribirse a
# mano: a mano se escapaba uno de cada vez (QtXml, luego QtPlatformHeaders via
# QtWidgets, luego QtDBus). Y hay que hacerlo en CADA repo de modulo, no solo en
# qtbase: qtmultimedia es otro repo y sin sus headers
#   video/qvideoframe.h(46): fatal error C1083: 'QtMultimedia/qabstractvideobuffer.h'
function Invoke-ModuleSyncqt([string]$RepoDir, [string]$Criticos) {
  if (-not (Test-Path $RepoDir)) { return }
  $mods = @()
  Get-ChildItem (Join-Path $RepoDir 'src') -Recurse -Depth 2 -Filter '*.pro' -ErrorAction SilentlyContinue |
    ForEach-Object {
      $t = Select-String -Path $_.FullName -Pattern '^\s*TARGET\s*=\s*(Qt[A-Za-z0-9_]+)' -ErrorAction SilentlyContinue |
           Select-Object -First 1
      if ($t -and $t.Matches.Count -gt 0) { $mods += $t.Matches[0].Groups[1].Value }
    }
  $mods = @($mods | Sort-Object -Unique)
  if ($mods.Count -eq 0) { return }
  # QtPlatformHeaders no sale de ningun TARGET pero kernel/qwidget.cpp lo necesita
  $mods += 'QtPlatformHeaders'
  $mods = @($mods | Sort-Object -Unique)
  # syncqt.pl vive SOLO en qtbase. Cada repo de modulo (qtmultimedia,
  # qtimageformats) no lo trae, asi que hay que llamar al de qtbase pasando
  # como srcbase el repo que se esta_headersizando:
  #   perl <qtbase>\bin\syncqt.pl -version 5.15.19 -module QtMultimedia \
  #         -outdir <qtmultimedia> <qtmultimedia>
  # Con $RepoDir\bin\syncqt.pl (que no existe ahi) el canario moria con
  # "syncqt no genero include/ para qtmultimedia".
  $syncqt = Join-Path $Work 'qtbase\bin\syncqt.pl'
  if (-not (Test-Path $syncqt)) { throw "no encuentro $syncqt" }
  $ok = @()
  Push-Location $RepoDir
  foreach ($m in $mods) {
    $a = @('-w', $syncqt, '-version', '5.15.19', '-module', $m,
           '-outdir', (Get-Location).Path, (Get-Location).Path)
    $c = Invoke-Native $script:nativePerl $a
    if ($c -eq 0 -and (Test-Path (Join-Path $RepoDir ('include\' + $m)))) { $ok += $m }
  }
  Pop-Location
  $n = 0
  foreach ($m in $ok) {
    $h = Join-Path $RepoDir ('include\' + $m)
    $n += (Get-ChildItem $h -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
  }
  Say ("  syncqt: {0} modulos, {1} forwarding headers" -f $ok.Count, $n)
  # canario: los modulos que el repo necesita de verdad
  # Sin distincion de mayusculas: el caller pasa el NOMBRE DEL REPO
  # ('qtmultimedia') y syncqt genera el del MODULO ('QtMultimedia'). Con -c
  # el canario rechazaba un repo que si habia generado sus headers.
  $faltan = @()
  foreach ($m in ($Criticos -split ',')) {
    if (-not ($ok -contains $m)) {
      $hit = $false
      foreach ($o in $ok) { if ($o -ieq $m) { $hit = $true } }
      if (-not $hit) { $faltan += $m }
    }
  }
  if ($faltan.Count -gt 0) {
    throw ("syncqt no genero include/ para " + ($faltan -join ', ') + " en $RepoDir : nmake morira con C1083")
  }
}

# --- headers publicos de los repos de modulo aparte --------------------------
# En qtbase, configure genera las reglas de instalacion de headers a partir de
# los modulos que ve como hermanos, asi que `nmake install` publica include/.
# En un repo hermano eso NO pasa: qtmultimedia.pro declara no INSTALLS y su
# Makefile no tiene regla syncqt, asi que `nmake install` instala 3 ficheros en
# prefix/include/QtMultimedia mientras el arbol tiene 224. El paquete salia SIN
# los headers y sin ellos la app no puede compilar (#include <QAudioOutput>, que
# es el motor de audio del build x86).
#
# Y no vale copiarlo todo: syncqt escribe tambien las SOMBRAS de los headers
# privados, y estas son
#     #include "../../src/multimedia/audio/qaudio.h"
# es decir, rutas que solo existen dentro del arbol de compilacion. Aplanadas en
# el prefix, el CI revienta al compilar la app:
#     include\QtMultimedia\qaudio.h(1,10): fatal error C1083:
#     Cannot open include file: '../../src/multimedia/audio/qaudio.h'
#
# La lista que decide es PUBLIC_HEADERS del .pro del modulo. Se leen de ahi, no
# se deducen: un header publico es autocontenido y uno privado no, pero filtrar
# por contenido dejaria pasar los privados que no usan rutas relativas.
function Get-PublicHeaders([string]$RepoDir, [string]$ModuleName) {
  $names = @()
  # Se recorren TODOS los .pro y .pri del repo y no solo uno con el nombre del
  # modulo: el de QtMultimedia se llama multimedia.pro (no QtMultimedia.pro), y
  # ademas multimedia.pro solo declara 10 PUBLIC_HEADERS porque el resto vive en
  # los .pri de cada submódulo (audio.pri trae qaudiooutput.h, y asi con cada
  # uno). Leyendo solo el .pro del modulo se instalaban 10 headers de 224 y el
  # paquete se quedaba sin <QAudioOutput>.
  # Luego se filtran los que de verdad estan en el nido, que es lo que
  # distingue los declarados de los que syncqt no genero. Los PRIVADOS no
  # aparecen: van listados en PRIVATE_HEADERS, y sus sombras apuntan a
  # ../../src/... (ruta que solo existe dentro del arbol de compilacion).
  # syncqt deja los headers publicos PLANOS en include/<Modulo>/ (ahi estan
  # qaudiooutput.h y su sombra QAudioOutput), que es justo el layout que lleva el
  # prefix. El directorio include/<Modulo>/<Modulo>/ es otra cosa (headers.pri y
  # las sombras del target): leer de ahi no encontraba ninguno y se instalaban 0.
  $src = Join-Path (Join-Path $RepoDir 'include') $ModuleName
  Get-ChildItem (Join-Path $RepoDir 'src') -Recurse -Include '*.pro', '*.pri' -ErrorAction SilentlyContinue |
    ForEach-Object {
      $text = (Get-Content $_.FullName -Raw) -replace "\\\s*`r?`n", ' '
      # Dos formas, y hacen falta las dos. El .pro del modulo usa la asignacion
      # clasica:
      #     PUBLIC_HEADERS += \
      #         qtmultimediaglobal.h \
      # y cada submódulo usa la función de Qt 5.15 en su .pri (audio.pri,
      # camera.pri, controls.pri...):
      #     publicHeaders(
      #         qaudioinput.h
      #         qaudiooutput.h
      #     )
      # Leyendo solo la primera se instalaban 10 headers de mas de 100 y el
      # paquete se quedaba sin <QAudioOutput>.
      # Matches, NO Match: un .pro puede declarar VARIAS sentencias
      # PUBLIC_HEADERS (en multimediawidgets.pro qgraphicsvideoitem.h va en
      # una aparte) y con la primera sola se perdian headers sin avisar.
      $hits = @()
      $hits += [regex]::Matches($text, 'PUBLIC_HEADERS\s*\+?=([^=]*)')
      $hits += [regex]::Matches($text, 'publicHeaders\s*\(([^)]*)\)')
      foreach ($mm in $hits) {
        if (-not $mm.Success) { continue }
        foreach ($tok in ($mm.Groups[1].Value -split '\s+')) {
          $t = $tok.Trim().Trim('"').Trim(',') -replace '/', '\'
          # Con subdirectorio: los .pri de cada submódulo listan audio/qaudio.h,
          # camera/qcamera.h... Rechazar los nombres con barra era lo que dejaba
          # la lista en 10 headers (solo los del .pro, que van sin ruta).
          if ($t -notmatch '\.h$') { continue }
          if ($t -match '^[A-Za-z]:' -or $t.StartsWith('..')) { continue }
          # El .pri declara audio/qaudiooutput.h pero syncqt escribe el fichero
          # PLANO en include/<Modulo>/qaudiooutput.h. Se aceptan las dos rutas:
          # con la subruta no se encontraba ninguna y la lista se quedaba en los
          # 10 headers del .pro (que si van sin prefijo).
          $leaf = Split-Path $t -Leaf
          if ((Test-Path (Join-Path $src $t)) -or (Test-Path (Join-Path $src $leaf))) {
            $names += $leaf
          }
        }
      }
    }
  return @($names | Sort-Object -Unique)
}

# $Requeridos son los modulos que este repo construye de verdad. El include/
# tambien contiene los de otros (QtMultimediaGstTools es una herramienta de
# Linux que no se compila en Windows) y sobre esos no puede exigirse nada.
function Install-ModuleHeaders([string]$RepoDir, [string[]]$Requeridos) {
  if (-not (Test-Path $RepoDir)) { return }
  $dstRoot = Join-Path $cfg.Prefix 'include'
  if (-not (Test-Path $dstRoot)) { New-Item -ItemType Directory -Force -Path $dstRoot | Out-Null }
  Get-ChildItem (Join-Path $RepoDir 'include') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Qt*' } | ForEach-Object {
      $m = $_.Name
      # @( ) es obligatorio: una funcion que devuelve un array de UN solo
      # elemento se desenvuelve a escalar en PowerShell, y con Set-StrictMode
      # $pub.Count revienta con "the property 'Count' cannot be found".
      $pub = @(Get-PublicHeaders $RepoDir $m)
      $srcDir = $_.FullName
      $dst = Join-Path $dstRoot $m
      $ver = Join-Path $dst '5.15.19'
      # Se borra el destino: si una ejecucion anterior dejo un anidamiento o una
      # sombra privada, Copy-Item falla con "the target file is a directory".
      if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
      New-Item -ItemType Directory -Force -Path (Join-Path $ver $m) | Out-Null

      $n = 0; $falt = @(); $shadows = 0; $extra = 0
      # Los headers GENERADOS no los declara ningun .pri pero el moc los
      # necesita: <modulo>defs.h (las macros QT_*_DECL) y <modulo>version.h.
      # Sin ellos QtMultimediaWidgets se quedaba en 4 headers.
      # Las sombras NO se pueden deducir del nombre del header: Qt las escribe en
      # CamelCase (qaudiodeviceinfo.h -> QAudioDeviceInfo), no Qaudiodeviceinfo.
      # Se emparejan por su contenido, que es un #include "<header>.h".
      $sombras = @{}
      Get-ChildItem $srcDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '' } | ForEach-Object {
          $t = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
          if ($null -ne $t -and $t -match '#include\s+"([^"]+\.h)"') {
            if ($t -notmatch '\.\.[\\/]\.\.[\\/]src[\\/]') { $sombras[$Matches[1]] = $_.Name }
          }
        }

      # qtmultimedia-config.h y <Modulo>Depends los pone `nmake install`, pero
      # como el destino se borra antes de copiar hay que reponerlos: los
      # headers de Qt lo incluyen para las macros QT_*_EXPORT y sin el el
      # paquete no compila. Vienen en el mismo include/ del modulo.
      Get-ChildItem $srcDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(-config\.h|Depends)$' } | ForEach-Object {
          # Misma trampa que los headers: en include/ este nombre es la SOMBRA
          #   #include "../../src/multimedia/qtmultimedia-config.h"
          # y el de verdad esta en src/. Copiar la sombra haciacia fallar al
          # compilar la app con C1083 en qtmultimedia-config.h(1,10).
          $t1 = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
          $use = $_.FullName
          if ($null -eq $t1 -or $t1 -match '\.\.[\\/]\.\.[\\/]src[\\/]') {
            $real = Get-ChildItem (Join-Path $RepoDir 'src') -Recurse -Filter $_.Name -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -eq '.h' -or $_.Name -like '*Depends' } | Select-Object -First 1
            if ($real) { $use = $real.FullName }
          }
          Copy-Item $use $dst -Force
          Copy-Item $use (Join-Path $ver $m) -Force
          $extra++
        }

      $gen = @(Get-ChildItem $srcDir -Filter '*.h' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '(defs|version)\.h$' })
      foreach ($g in $gen) { if ($pub -notcontains $g.Name) { $pub += $g.Name } }

      foreach ($h in $pub) {
        $rel = $h -replace '/', '\'
        $leaf = Split-Path $rel -Leaf
        # El header DE VERDAD esta en src/<modulo>/<ruta del .pri>. En
        # include/<Modulo>/ lo que hay con ese nombre es la SOMBRA, que dice
        #     #include "../../src/multimedia/audio/qaudio.h"
        # y al aplanarla en el prefix el CI revienta al compilar la app:
        #     include\QtMultimedia\qaudio.h(1,10): fatal error C1083
        # Por eso el real se busca por nombre en src/, no en include/.
        # 1) include/<Modulo>/<leaf>: sirve si NO apunta fuera del prefix. Ahi
        #    estan los GENERADOS (<modulo>defs.h, <modulo>version.h), que no
        #    viven en src/ y se perdian si se buscaba solo ahi.
        $f = $null
        $inSrc = Join-Path $srcDir $leaf
        if (Test-Path $inSrc) {
          $t0 = Get-Content $inSrc -Raw -ErrorAction SilentlyContinue
          if ($null -ne $t0 -and $t0 -notmatch '\.\.[\\/]\.\.[\\/]src[\\/]') { $f = Get-Item $inSrc }
        }
        # 2) si no, el real. Se busca en TODO el repo menos el arbol include/
        #    (donde solo hay sombras): buscar solo en src/ se perdia
        #    qgraphicsvideoitem.h, que vive en src/multimediawidgets/ y el .pro
        #    declara publico, dejando QtMultimediaWidgets en 5 de 6 headers.
        if (-not $f) {
          $f = Get-ChildItem $RepoDir -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.h' -and $_.FullName -notlike ($srcDir + '*') } |
               Select-Object -First 1
        }
        if (-not $f) { $falt += $h; continue }
        Copy-Item $f.FullName (Join-Path $dst $leaf) -Force
        Copy-Item $f.FullName (Join-Path (Join-Path $ver $m) $leaf) -Force
        # La sombra sin extension (#include <QAudioOutput> se resuelve asi), pero
        # solo si es resoluble DENTRO del prefix.
        $shName = $sombras[$leaf]
        $shPath = Join-Path $srcDir $shName
        if (Test-Path $shPath) {
          $shTxt = Get-Content $shPath -Raw -ErrorAction SilentlyContinue
          if ($null -ne $shTxt -and $shTxt -notmatch '\.\.[\\/]\.\.[\\/]src[\\/]') {
            Copy-Item $shPath (Join-Path $dst $shName) -Force
            Copy-Item $shPath (Join-Path $ver $m) -Force
            $shadows++
          }
        }
        $n++
      }
      if ($falt.Count -gt 0) {
        Say ("  AVISO {0}: {1} declarados no estan en el arbol (p.ej. {2})" -f $m, $falt.Count, ($falt[0..1] -join ', '))
      }
      # canario: una instalacion parcial no puede pasar en silencio. Pasa lo que
      # pasara (solo 10 de 224, o 0) y el paquete se va al CI a fallar con un
      # C1083 a 30 minutos de compilar. Un modulo publico de Qt tiene decenas de
      # headers; si salen menos de 20, la lista se esta leyendo mal.
        # El minimo es proporcional: QtMultimediaWidgets tiene 6 headers y
        # QtMultimedia mas de 80. Un umbral fijo de 20 era incorrecto.
        # Minimo EXPLICITO por modulo. Un umbral generico no vale: QtMultimedia
        # tiene mas de 80 headers y QtMultimediaWidgets solo 6, y ademas hay
        # headers declarados que no tienen fichero real en esta configuracion
        # (qgraphicsvideoitem.h solo existe si QT_CONFIG(graphicsview)), de modo
        # que el numero de instalables no es derivable. Estos son los valores
        # MEDIDOS de este commit; si un Qt nuevo los cambia, el canario avisa
        # en vez de dejar que el CI reviente 30 minutos despues con un C1083.
        $esperado = @{ 'QtMultimedia' = 70; 'QtMultimediaWidgets' = 5; 'QtImageFormats' = 3 }
        $minimo = 0
        if ($esperado.ContainsKey($m)) { $minimo = $esperado[$m] } else { $minimo = 1 }
        if ($Requeridos -contains $m -and $n -lt $minimo) {
        throw ("instale solo $n headers publicos de " + $m + " en el prefix: esperaba minimo $minimo" +
               " (declarados: $($pub.Count), presentes en el arbol: " +
               ((Get-ChildItem $srcDir -Filter "*.h" -File -ErrorAction SilentlyContinue | Measure-Object).Count) + ")." +
               " Sin ellos el paquete no compila: revisa Get-PublicHeaders")
      }
      Say ("  headers de {0}: {1} publicos + {2} sombras + {3} de configuracion en include\{0} y en 5.15.19\{0}" -f $m, $n, $shadows, $extra)
    }
}

# qaudiooutput.h -> QAudioOutput (la sombra que genera syncqt).
# Solo la PRIMERA letra va en mayuscula: pasarlas todas daba QAUDIOOUTPUT y las
# sombras no se copiaban, con lo que #include <QAudioOutput> no resolvia.
function Get-ShadowName([string]$Header) {
  $base = [IO.Path]::GetFileNameWithoutExtension($Header)
  if ($base.Length -eq 0) { return $base }
  return ([string]::Join('', @([char]::ToUpper($base[0]), $base.Substring(1))))
}

# --- 1) qtbase (in-source, as Qt expects on Windows) ------------------------
# A prefix sitting in the work tree proves nothing on its own: it may come from
# an older run whose sources were different (that is exactly how the previous
# BOM ended up describing the wrong tree). It is reusable only when the recorded
# provenance says THIS prefix was built from THESE verified sources; otherwise it
# is deleted so nothing of the old build can leak into the new one.
if ((Test-Path $qmakePath) -and -not $built.Contains('qtbase')) {
  Say "el prefix de $Work no consta como construido con las fuentes de esta pasada: se borra"
  Remove-Item $cfg.Prefix -Recurse -Force -ErrorAction SilentlyContinue
}
if ((Test-Path $qmakePath) -and $built.Contains('qtbase')) {
  Say "qtbase ya instalado en el prefix, se reutiliza (procedencia verificada)"
} else {
  Say "configurando qtbase"
  Push-Location (Join-Path $Work 'qtbase')
  # syncqt.pl has to run here, not inside configure.bat: that one only runs it
  # when there is a .git (see `if "%SYNCQT%" == "" ( if exist .git ... )`), and
  # the sources are a commit ARCHIVE, so it would skip the forwarding headers
  # and the qmake bootstrap would die with
  #   qglobal.h(64): fatal error C1083: 'QtCore/qconfig-bootstrapped.h'
  # silently, with no "Running syncqt" line anywhere in the log.
  $syncqtArgs = @('-w', 'bin\syncqt.pl', '-minimal', '-version', '5.15.19',
                  '-module', 'QtCore', '-outdir', (Get-Location).Path, (Get-Location).Path)
  Say "  perl: $script:nativePerl (nativo)"
  Say ("  getcwd de ese perl = " + (& $script:nativePerl -MCwd -e "print Cwd::getcwd()"))
  $syncqtCode = Invoke-Native $script:nativePerl $syncqtArgs
  if ($syncqtCode -ne 0) { throw "syncqt.pl fallo (exit $syncqtCode)" }
  $fwd = Join-Path $Work 'qtbase\include\QtCore\qconfig-bootstrapped.h'
  if (-not (Test-Path $fwd)) {
    throw "syncqt.pl corrio pero no genero $fwd (si vuelve a salir, el srcbase sera POSIX: revisa que el perl del PATH sea el nativo)"
  }
  $fwdQglobal = Join-Path $Work 'qtbase\include\QtCore\qglobal.h'
  if (Test-Path $fwdQglobal) {
    $inc = (Get-Content $fwdQglobal -TotalCount 1)
    if ($inc -match '/c/') { throw "el include generado sale con ruta POSIX: $($inc)" }
  }
  Say "  forwarding headers generados (srcbase correcto)"
  # Y ahora el syncqt POR MODULO. El que lanza configure.bat es
  # "-minimal -module QtCore": solo los de QtCore, que son los que necesita el
  # bootstrap de qmake. Los de los demas modulos tiene que generarlos el propio
  # build a traves de la regla syncqt de cada Makefile... y aqui no lo hace
  # (en el log no aparece ni una vez "syncqt"), asi que include/QtXml se queda
  # vacio y src/xml/dom/qdom.cpp, que hace #include <qdom.h> CON ANGLETS (y por
  # tanto no busca en su propio directorio, solo en los -I), revienta con
  #   qdom.cpp(41): fatal error C1083: Cannot open include file: 'qdom.h'
  # Se generan aqui, antes de nmake, y se comprueba con un canario.
    # La lista de modulos se DERIVA de los .pro (campo TARGET) en vez de estar
  # escrita a mano. Escribirla a mano fallaba de uno en uno: QtXml se salio
  # (qdom.cpp no encontraba <qdom.h>), luego QtWidgets se salio via
  # QtPlatformHeaders, luego QtDBus. syncqt.pl se niega a inventar un modulo que
  # no existe ("No such module: QtTestlib"), asi que la lista tiene que ser
  # exactamente la de los .pro.
  Invoke-ModuleSyncqt (Join-Path $Work 'qtbase') 'QtCore,QtGui,QtNetwork,QtSql,QtXml,QtWidgets,QtPrintSupport,QtDBus,QtOpenGL,QtPlatformHeaders'
  Invoke-Msvc "configure.bat $configureFlags"
  Say "compilando qtbase (esto es lo que tarda)"
  # /MP compila en paralelo los cl de un MISMO Makefile. Sin el, esto va con
  # un solo core aunque la maquina tenga 8: medido, un build de qtbase en un
  # runner de 4 nucleos tardaba mas de 3 horas sin terminarlo. /MP no paraleliza
  # ENTRE objetivos, asi que los modulos siguen yendo en serie, pero dentro de
  # qtbase hay cientos de .obj y ahi es donde esta el tiempo. Es seguro: lo
  # que /MP no tolera es combinarse con /Gm, que aqui no se usa.
  Invoke-Msvc 'nmake /MP'
  Invoke-Msvc 'nmake /MP install'
  Pop-Location
  $script:prov['qtbase'].built = $true; $built['qtbase'] = $true
  Set-WorkProvenance
}

$qmake = $qmakePath
if (-not (Test-Path $qmake)) { throw "no se instalo qmake en $qmake" }

# --- 2) extra modules built against the installed prefix --------------------
# (module root `qmake` generates the -config.pri the sub-targets need)
if (($cfg.Modules -contains 'qttools') -and -not $built.Contains('qttools')) {
  Say "configurando qttools y compilando SOLO windeployqt"
  Push-Location (Join-Path $Work 'qttools')
  # Root qmake: what it produces is qttools-config.pri, nothing else useful.
  Invoke-Msvc "`"$qmake`" qttools.pro"
  Pop-Location
  # The root Makefile exposes only COARSE targets (sub-src, sub-examples,
  # sub-tests), so building just windeployqt from there is impossible, and
  # src\windeployqt has NO Makefile of its own: nmake there dies with
  #   NMAKE : fatal error U1064: MAKEFILE not found and no target specified
  # windeployqt.pro starts with include($$OUT_PWD/../../qttools-config.pri),
  # so configuring the sub-project in its own directory picks up exactly the
  # file the root qmake just wrote. That is the supported way to build a single
  # qttools sub-project.
  Push-Location (Join-Path $Work 'qttools\src\windeployqt')
  Invoke-Msvc "`"$qmake`" windeployqt.pro"
  Invoke-Msvc 'nmake /MP'
  Invoke-Msvc 'nmake /MP install'
  Pop-Location
  $script:prov['qttools'].built = $true; $built['qttools'] = $true
  Set-WorkProvenance
} elseif ($cfg.Modules -contains 'qttools') {
  Say "qttools ya instalado en el prefix, se reutiliza (procedencia verificada)"
}

foreach ($m in @('qtimageformats', 'qtmultimedia')) {
  if ($cfg.Modules -notcontains $m) { continue }
  # syncqt SIEMPRE, tambien cuando se reutiliza el prefix: Install-ModuleHeaders
  # lee los headers de aqui, y una reutilizacion se encontraria el nido vacio
  # (la ejecucion anterior lo aplana y lo borra) y no instalaria nada.
  Invoke-ModuleSyncqt (Join-Path $Work $m) $m
  if ($built.Contains($m)) {
    Say "$m ya instalado en el prefix, se reutiliza (procedencia verificada)"
    Install-ModuleHeaders (Join-Path $Work $m) @('QtImageFormats','QtMultimedia','QtMultimediaWidgets')
    continue
  }
  Say "compilando $m"
  Push-Location (Join-Path $Work $m)
  Invoke-Msvc "`"$qmake`" $m.pro"
  Invoke-Msvc 'nmake /MP'
  Invoke-Msvc 'nmake /MP install'
  Pop-Location
  Install-ModuleHeaders (Join-Path $Work $m) @('QtImageFormats','QtMultimedia','QtMultimediaWidgets')
  $script:prov[$m].built = $true; $built[$m] = $true
  Set-WorkProvenance
}

# ANGLE se copia UNA vez, fuera del bucle de DLLs del prefix. Puesto dentro se
# repetia por cada DLL (8 veces) que es ruido, no un fallo.
foreach ($an in @('libEGL.dll','libGLESv2.dll')) {
  $a = Join-Path $AngleBin $an
  if (Test-Path $a) {
    Copy-Item $a (Join-Path $Dest 'bin') -Force
    Say "  $an (ANGLE precompilado: no es construible desde el git de Qt)"
  } else {
    Say "  AVISO: no encuentro $an en $AngleBin; el paquete se quedaria sin ANGLE y en Windows no habria GL"
  }
}

# --- 3) assemble the vendored tree (same layout as a Qt prefix) -------------
Say "ensamblando $Dest"
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
foreach ($d in @('bin', 'lib', 'include', 'plugins', 'mkspecs')) {
  New-Item -ItemType Directory -Path (Join-Path $Dest $d) | Out-Null
}

# bin/: only the runtime DLLs that belong (= same set as today, no Svg, no
# opengl32sw) plus the self-contained host tools (moc/uic/rcc/qmake/windeployqt
# are `force_bootstrap`: they do not need Qt DLLs next to them).
$binWhitelist = $cfg.QtDlls + $cfg.ExtraDlls
$copied = 0
foreach ($n in $binWhitelist) {
  $src = Join-Path $cfg.Prefix "bin\$n.dll"
  if (Test-Path $src) { Copy-Item $src (Join-Path $Dest 'bin') ; $copied++ }
  elseif ($cfg.ExtraDlls -contains $n) { Say "  (opcional, no generado: $n.dll)" }
  else { throw "falta la DLL esperada: $n.dll" }
}
foreach ($t in @('qmake', 'moc', 'uic', 'rcc', 'windeployqt')) {
  $src = Join-Path $cfg.Prefix "bin\$t.exe"
  if (-not (Test-Path $src)) { throw "falta la herramienta esperada: $t.exe" }
  Copy-Item $src (Join-Path $Dest 'bin')
}
# Anything we do NOT want (defensive): never ship these even if built.
# opengl32sw.dll is NOT shipped, on purpose, and the reason is not "it is junk".
#
# It is Qt's software OpenGL (Mesa llvmpipe) fallback, and the official Windows
# package does carry it. It cannot be built here, though: the opensource 5.15.19
# sources do not contain it at all (no opengl32sw / mesa / llvmpipe / swrast
# anywhere in the qtbase tarball, 28758 entries checked). Only Qt's own binary
# build produces it.
#
# It is not needed, because `-opengl dynamic` gives Qt a fallback chain and the
# second link already covers the machines that worry:
#   1. the SYSTEM opengl32.dll (hardware OpenGL) - every PC with a GPU;
#   2. ANGLE over D3D11, which on a machine with no 3D runs on the Microsoft
#      Basic Render Driver (WARP).
# Measured on a Windows 11 VM with no usable OpenGL at all (RDP "Remote Display
# Adapter" + VirtIO DOD, zero OpenGL ICDs registered): the app there uses
# link 2 and the player works - "GL ctx es=1 renderer=ANGLE (Microsoft Basic
# Render Driver Direct3D11)", "Detected GLES 2.0", paintGL ok.
#
# So this tree ships no software renderer and relies on the system one, which
# also keeps the installer ~19 MB smaller. The only case it would not cover is
# a machine with neither hardware OpenGL nor D3D11, which was not observed.
# If that ever matters, add it as its OWN vendored component with its SHA256
# (the official archive is "opengl32sw" of the Qt 5.15.2 package) instead of
# injecting a foreign binary into this prefix - a prefix must contain only what
# this build produced, or find_package breaks on it (same lesson as the
# qtaudio_wasapi.dll plugin).
foreach ($junk in @('Qt5Svg.dll', 'Qt5MultimediaWidgets.dll',
                    'Qt5Test.dll', 'Qt5Xml.dll')) {
  $p = Join-Path $Dest "bin\$junk"
  if (Test-Path $p) { Remove-Item $p -Force; Say "  excluido: $junk" }
}

# lib/: import-libs + CMake package config + .prl
Copy-Item (Join-Path $cfg.Prefix 'lib\*') (Join-Path $Dest 'lib') -Recurse -Force

# include/: public headers only (private/ is only needed to BUILD the tools,
# already done above) -> saves several MB in the repo.
Copy-Item (Join-Path $cfg.Prefix 'include\*') (Join-Path $Dest 'include') -Recurse -Force
Get-ChildItem (Join-Path $Dest 'include') -Recurse -Directory -Filter 'private' |
  Remove-Item -Recurse -Force

# plugins/ and mkspecs/ as installed (platforms + imageformats + sqldrivers +
# styles + [x86] audio; qoffscreen is included for the CI smoke).
Copy-Item (Join-Path $cfg.Prefix 'plugins\*') (Join-Path $Dest 'plugins') -Recurse -Force
Copy-Item (Join-Path $cfg.Prefix 'mkspecs\*') (Join-Path $Dest 'mkspecs') -Recurse -Force

# qtaudio_wasapi.dll imports RoGetActivationFactory (W8+): the x86/Win7 CI
# purges it from the bundle before the imports gate, and Qt's Win7 audio goes
# qtaudio_wasapi.dll is DELIBERATELY KEPT in the vendor tree. It imports
# RoGetActivationFactory (W8+), so it must never reach the Win7 PACKAGE -- but
# dropping it here breaks the tree: lib/cmake/Qt5Multimedia/Qt5MultimediaConfig.cmake
# lists it as a dependency of the imported target Qt5::Multimedia, and CMake
# then refuses to configure with
#   The imported target "Qt5::Multimedia" references the file
#   ".../plugins/audio/qtaudio_wasapi.dll" but this file does not exist.
# A vendored tree has to be self-consistent with its own CMake package configs.
# The exclusion belongs to the PACKAGING step, and windows.yml already does it
# (Remove-Item dist\audio\qtaudio_wasapi.dll, before the W8+ imports gate), for
# the same reason it purges the app-local UCRT.

# Trim build leftovers that would bloat the repo.
Get-ChildItem $Dest -Recurse -Include '*.pdb', '*.exp', '*.ilk' -File |
  Remove-Item -Force -ErrorAction SilentlyContinue

# --- 4) LGPL note + BOM ----------------------------------------------------
foreach ($lic in @('LICENSE.LGPLv3', 'LICENSE.GPL3-EXCEPT')) {
  $src = Join-Path $Work "qtbase\$lic"
  if (Test-Path $src) { Copy-Item $src (Join-Path $Dest $lic) }
}

$bom = [ordered]@{
  generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  arch      = $Arch
  qt        = [ordered]@{
      # Un build de git NO es "5.15.19". La etiqueta vive en qt-sources.json
      # porque es 'git rev-list --count v5.15.19-lts-lgpl..<commit>' y esta receta
      # descarga archivos por commit en vez de clonar, asi que no hay historial
      # contra el que correrlo. Aqui sale 96, y el PKGBUILD de Arch lo calcula
      # exactamente igual con esa misma formula.
      #
      # 5.15.19 a secas es MODULE_VERSION, lo que declara qtbase/.qmake.conf y por
      # eso leen los DLL. Afirmar que el arbol ES el corte de 5.15.19 es falso: hay
      # 96 commits detras. Escribirlo asi fue como el BOM anterior quedo mal dos
      # veces.
      version   = $(if ($KdeUrl) { $sources.versionLabel } else { $QtVersion })
      origin    = $(if ($KdeUrl) { "KDE maintenance branch $KdeBranch, at the commits below (the same ones the Arch Linux package pins). The label is Qt's own +kde+rN scheme: there are $(([int]($sources.versionLabel -replace '.+\+r',''))) commits on this branch after the v5.15.19-lts-lgpl tag, not only distro patches" } else { 'official Qt release tarballs (download.qt.io), no git' })
    modules   = [ordered]@{}
    configure = $configureFlags
    toolset   = "cl $clVersion ($vcArgs)"
    openssl   = [ordered]@{ version = $sslVersion; kind = 'dev files only, DLLs loaded at run time' }
    license   = $(if ($KdeUrl) { 'LGPL-3.0 (dynamic linking; per-module commit below)' } else { 'LGPL-3.0 (dynamic linking; per-module sha256 below)' })
  }
  licenses  = [ordered]@{ qt = 'LGPL-3.0'; app = 'GPL-3.0' }
}
foreach ($m in $cfg.Modules) {
  if ($sources[$m].commit) {
    $bom.qt.modules[$m] = [ordered]@{ url = $sources[$m].url; branch = $sources[$m].branch
                                     commit = $sources[$m].commit; archiveSha256 = $script:prov[$m].sha256 }
  } else {
    $bom.qt.modules[$m] = [ordered]@{ url = $sources[$m].url; sha256 = $sources[$m].sha256 }
  }
}
# UTF-8 WITHOUT BOM. `Set-Content -Encoding UTF8` in Windows PowerShell 5.1
# writes a BOM, and a BOM-prefixed JSON file breaks strict parsers (python's
# json module, jq, most CI tooling) with "Unexpected UTF-8 BOM". The file is
# read back by the packaging workflow, so it has to be plain UTF-8.
$bomJson = $bom | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $Dest 'BOM.json'), $bomJson,
                        (New-Object Text.UTF8Encoding $false))

# --- 5) x86: Win7 imports gate (the same poison list the CI uses) -----------
if ($cfg.Win7Gate) {
  Say "gate de imports Win7 (dumpbin) sobre $Dest\bin"
  $dumpbinRoot = Join-Path $vsPath 'VC\Tools\MSVC'
  $dumpbinRoot = (Get-ChildItem $dumpbinRoot -Directory | Sort-Object Name -Descending |
    Select-Object -First 1).FullName
  $dumpbin = Join-Path $dumpbinRoot 'bin\Hostx64\x64\dumpbin.exe'
  if (-not (Test-Path $dumpbin)) {
    $dumpbin = Join-Path $dumpbinRoot 'bin\Hostx86\x86\dumpbin.exe'
  }
  if (-not (Test-Path $dumpbin)) { throw "no se hallo dumpbin.exe" }
  $poison = @('GetSystemTimePreciseAsFileTime', 'AdjustWindowRectExForDpi',
    'GetSystemMetricsForDpi', 'GetDpiForMonitor', 'PathCchCanonicalizeEx',
    'SetThreadDpiAwarenessContext', 'SetProcessDpiAwarenessContext',
    'WaitOnAddress', 'WakeByAddressAll', 'WakeByAddressSingle',
    'RoGetActivationFactory', 'RoOriginateLanguageException',
    'AddDllDirectory', 'SetDefaultDllDirectories')
  $bad = 0
  foreach ($f in (Get-ChildItem "$Dest\bin" -Filter *.dll)) {
    $imp = & $dumpbin /imports $f.FullName
    foreach ($sym in $poison) {
      if ($imp | Select-String -SimpleMatch $sym) {
        Write-Host "  !$($f.Name) importa $sym (W8+): rompe Win7!"; $bad++
      }
    }
  }
  if ($bad -gt 0) { throw "$bad DLL(s) con imports W8+ (ver arriba)" }
  Say "  OK: ninguna DLL del vendor importa simbolos W8+"
}

# --- summary ---------------------------------------------------------------
$size = (Get-ChildItem $Dest -Recurse -File | Measure-Object Length -Sum).Sum
Say "listo: $Dest"
Say ("  DLLs de runtime: {0}; ficheros: {1}; tamano: {2:N1} MB" -f $copied,
  (Get-ChildItem $Dest -Recurse -File).Count, ($size / 1MB))
Say "  BOM: $Dest\BOM.json  (version + sha256 por modulo + flags + toolset)"
Say ""
Say "Siguiente: revisar el arbol y commitearlo (third_party/...) para que los"
Say "workflows de Windows lo usen en lugar de install-qt-action (ver BUILD_QT_WINDOWS.md)."

if (-not $KeepWork) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
