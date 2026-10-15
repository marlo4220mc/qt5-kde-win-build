<#
    Prepara una maquina Windows para poder ejecutar build-qt-win.ps1.

    La receta NUNCA ha sido autosuficiente: en la VM donde se desarrollo
    quedaron a mano cuatro entradas que el script no preparaba y que sin ellas
    no arranca. Esto las resuelve, y las declara, para que el mismo camino
    funcione en un runner efimero de CI o en una maquina nueva:

      1. Perl nativo (Strawberry)   -> syncqt.pl lo necesita y el de Git no vale
      2. OpenSSL 3.5.9 de desarrollo, por arquitectura
      3. El tarball oficial 5.15.19 -> solo para superponer include/QtANGLE
      4. flex/bison                 -> lo baja la propia receta, aqui no se toca

    Todo se descarga y se HASH VERIFICA. Nada se reutiliza porque exista: si el
    hash no cuadra, el fichero se borra y se vuelve a bajar. Es la misma regla
    de procedencia de la que ya habla el README.
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'both')][string]$Arch = 'both',
    # Donde queda todo. En un runner efimero esto es el $env:RUNNER_TEMP.
    [string]$Root = 'C:\qtbuild',
    [string]$PerlVersion = '5.36.1.1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say([string]$m) { Write-Host ("==> " + $m) }

# --- utilidades -------------------------------------------------------------

function Get-Sha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

function Get-Base64([string]$Path) {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

# Descarga y verifica en el mismo sitio: si el hash no es el esperado, el
# fichero se borra. Un fichero a medias o corrupto que se queda ahi es peor
# que uno que no se ha descargado, porque el error aparece 40 minutos despues.
function Get-Verified([string]$Url, [string]$Dest, [string]$Sha256, [string]$What) {
    if ((Test-Path $Dest) -and ((Get-Sha256 $Dest) -eq $Sha256.ToLower())) {
        Say "$What ya esta y el hash cuadra"
        return $Dest
    }
    if (Test-Path $Dest) {
        Say "$What con hash incorrecto, se descarta y se vuelve a bajar"
        Remove-Item $Dest -Force
    }
    $dir = Split-Path $Dest -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Dest.part"
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Say "descargando $What ..."
    & curl.exe -sSL --fail --retry 3 --retry-delay 5 -o $tmp $Url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { throw "fallo descargando $What : $Url" }
    $got = Get-Sha256 $tmp
    if ($got -ne $Sha256.ToLower()) {
        Remove-Item $tmp -Force
        throw "hash incorrecto en $What`n  esperado $Sha256`n  obtenido $got`n  url     $Url"
    }
    Move-Item $tmp $Dest -Force
    Say "$What descargado y verificado"
    return $Dest
}

# --- 1. Perl nativo ---------------------------------------------------------

function Install-Perl([string]$ToolsDir) {
    # Strawberry portable (zip, sin instalador). Tiene que ser el NATIVO: el
    # Perl de Git es MSYS y Cwd::getcwd() devuelve /c/..., y syncqt.pl usa eso
    # como srcbase, con lo que los forwarding headers salen corruptos y el build
    # muere mas tarde con C1083 en un modulo que no parece tener nada que ver.
    # No es un detalle: es la diferencia entre que compile y que no.
    $perlExe = Join-Path $ToolsDir 'sp\perl\bin\perl.exe'
    if (Test-Path $perlExe) { Say 'Perl nativo ya presente'; return }

    # La URL viene del fichero de hashes, NO se construye. Construirla del
    # numero de version daba tags que no existen (SP_5361_1 da 404: el formato
    # real es SP_54051_64bit, con el bit y el sufijo).
    $hashesFile = Join-Path $PSScriptRoot 'bootstrap-hashes.json'
    if (-not (Test-Path $hashesFile)) { throw "falta $hashesFile con los hashes del bootstrap" }
    $sp = (Get-Content $hashesFile -Raw | ConvertFrom-Json).strawberryPerl
    if (-not $sp) { throw 'Strawberry Perl no esta fijado en bootstrap-hashes.json' }

    $zip = Join-Path $ToolsDir ("strawberry-perl-$($sp.version)-portable.zip")
    Get-Verified $sp.url $zip $sp.sha256 "Strawberry Perl $($sp.version)" | Out-Null
    Say 'descomprimiendo Perl (~1 min)'
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $ToolsDir -Force

    # El zip no trae un nivel 'sp/': lo que hay dentro depende de como lo
    # empaquete Strawberry, y adivinarlo da un error que no dice donde esta. Se
    # busca perl.exe y se deduce la raiz a partir de el, que es lo unico que la
    # receta necesita: <raiz>/perl/bin/perl.exe. Si no coincide, se mueve.
    if (-not (Test-Path $perlExe)) {
        $encontrado = Get-ChildItem $ToolsDir -Recurse -Filter 'perl.exe' -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Directory.Name -eq 'bin' -and $_.Directory.Parent.Name -eq 'perl' } |
                      Select-Object -First 1
        if (-not $encontrado) {
            $cualquiera = Get-ChildItem $ToolsDir -Recurse -Filter 'perl.exe' -File -ErrorAction SilentlyContinue |
                          Select-Object -First 1
            if (-not $cualquiera) { throw "el zip no contiene ningun perl.exe bajo $ToolsDir" }
            throw ("perl.exe esta en " + $cualquiera.FullName +
                   " pero la receta necesita <raiz>\perl\bin\perl.exe (dos niveles por encima del fichero)")
        }
        $raizReal = $encontrado.Directory.Parent.Parent.FullName
        $raizEsperada = Join-Path $ToolsDir 'sp'
        Say "el zip descomprimio en otra forma; moviendo $raizReal -> $raizEsperada"
        New-Item -ItemType Directory -Force -Path (Split-Path $raizEsperada -Parent) | Out-Null
        Move-Item $raizReal $raizEsperada -Force
    }
    if (-not (Test-Path $perlExe)) { throw "no quedo perl.exe en $perlExe tras descomprimir" }
    # Comprobacion de fondo, no de forma: es lo que de verdad importa.
    $cwd = & $perlExe -MCwd -e 'print Cwd::getcwd()'
    if ($cwd -notmatch '^[A-Za-z]:') {
        throw ("ese perl devuelve el cwd como '$cwd'. Es un Perl MSYS (el de Git), no el nativo: " +
               "syncqt.pl lo usaria de srcbase con rutas POSIX y los forwarding headers saldrian corruptos")
    }
    Say "Perl nativo listo (getcwd = $cwd, con formato Windows)
}

# --- 2. OpenSSL de desarrollo ----------------------------------------------

# Qt se configura con -openssl-runtime, asi que en tiempo de EJECUCION carga las
# DLL, pero en tiempo de COMPILACION sigue haciendo falta openssl/include y el
# .lib de importacion. Se compila desde el fuente oficial con el mismo toolset,
# en vez de bajarse un binario de terceros: es lo unico que no depende de que
# alguien mantenga un build precompilado, y son ~8 minutos por arquitectura.
function Install-OpenSsl([string]$Root, [string]$Ver, [string]$ArchName, [string]$VcVars) {
    $app = Join-Path $Root "openssl\$ArchName\app"
    $inc = Join-Path $app 'include'
    $lib = Join-Path $app 'lib'
    if ((Test-Path $inc) -and (Test-Path $lib)) {
        $n = (Get-ChildItem $lib -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($n -gt 0) { Say "OpenSSL $Ver ($ArchName) ya presente ($n ficheros en lib)"; return }
    }

    $src = Join-Path $Root "openssl-src\$ArchName"
    $tar = Join-Path $Root "openssl-$Ver.tar.gz"
    $hashes = Get-Content (Join-Path $PSScriptRoot 'bootstrap-hashes.json') -Raw | ConvertFrom-Json
    if (-not $hashes.openssl) { throw 'OpenSSL no esta fijado en bootstrap-hashes.json' }
    Get-Verified $hashes.openssl.url $tar $hashes.openssl.sha256 "OpenSSL $Ver (fuente)" | Out-Null

    if (Test-Path $src) { Remove-Item $src -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Say "descomprimiendo OpenSSL $Ver"
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    & $tarExe -xf $tar -C $src
    if ($LASTEXITCODE -ne 0) { throw "tar fallo al descomprimir OpenSSL" }
    # El tarball trae un unico directorio raiz con la version.
    $root = Get-ChildItem $src -Directory | Select-Object -First 1
    $work = Join-Path $root.FullName $ArchName

    Say "compilando OpenSSL $Ver ($ArchName), unos minutos"
    $bat = Join-Path $Root "openssl-$ArchName.bat"
    $rel = (Resolve-Path $work).Path
    @(
        '@echo off',
        "call `"$VcVars`" >nul 2>&1",
        "cd /d `"$rel`"",
        'perl Configure VC-WIN32A no-shared no-tests no-asm -DOPENSSL_TLS_BUILD_OPENSSL_EXE=0',
        'nmake /S > build.log 2>&1',
        'if errorlevel 1 exit /b 1',
        "mkdir `"$app`" 2>nul",
        "xcopy /e /i /q include `"$inc`" >nul",
        "if not exist `"$app\nss`" mkdir `"$app\nss`"",
        "xcopy /e /i /q /s lib\*.lib `"$app\nss`" >nul",
        "xcopy /e /i /q /s lib\*.dll `"$app\nss`" >nul",
        'exit /b 0'
    ) | Set-Content -Encoding ASCII -Path $bat
    $p = Start-Process cmd.exe -ArgumentList '/c', $bat -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        $log = Join-Path $work 'build.log'
        if (Test-Path $log) {
            Write-Host '--- ultimas lineas del build de OpenSSL ---'
            Get-Content $log -Tail 20 | ForEach-Object { Write-Host ('  ' + $_) }
        }
        throw "OpenSSL ($ArchName) fallo con exit $($p.ExitCode)"
    }
    Say "OpenSSL $Ver ($ArchName) listo en $app"
}

# --- 3. tarball oficial (solo para include/QtANGLE) ------------------------

function Install-QtOfficialTarball([string]$Root, [string]$Ver, [string]$Sha256) {
    $dest = Join-Path $Root "toolgrab\qtbase-official-$Ver.tar.xz"
    $url = "https://download.qt.io/archive/qt/$($Ver.Split('.')[0]).$($Ver.Split('.')[1])/$Ver/submodules/qtbase-everywhere-opensource-src-$Ver.tar.xz"
    Get-Verified $url $dest $Sha256 "qtbase oficial $Ver (solo para include/QtANGLE)" | Out-Null
}

# --- main -------------------------------------------------------------------

$tools = Join-Path $Root 'tools'
$hashes = Get-Content (Join-Path $PSScriptRoot 'bootstrap-hashes.json') -Raw | ConvertFrom-Json
$archs = if ($Arch -eq 'both') { @('x64', 'x86') } else { @($Arch) }

Say "bootstrap en $Root (arquitecturas: $($archs -join ', '))"

Install-Perl $tools
Install-QtOfficialTarball $Root $hashes.qtOfficialVersion $hashes.qtOfficialTarballSha256

# OpenSSL necesita el toolset, que en un runner hay que inicializar antes.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw "no encuentro vswhere; se necesita Visual Studio en el runner" }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'no encuentro la instalacion de Visual Studio con las herramientas de C++' }

foreach ($a in $archs) {
    # El x86 es Win7 y necesita el toolset v142 (VS2019) y el SDK 10.0.19041.
    # En un runner con VS2022 hay que pedir explicitamente esa version o el link
    # usara el toolset moderno y ya no funcionara en Win7.
    $vcvars = if ($a -eq 'x86') {
        "$vs\VC\Auxiliary\Build\vcvarsall.bat"   # los args los pone el llamador
    } else {
        "$vs\VC\Auxiliary\Build\vcvars64.bat"
    }
    $vcArgs = if ($a -eq 'x86') { 'x86 -vcvars_ver=14.29 10.0.19041.0' } else { '' }
    if ($vcArgs) {
        $vcvars = Join-Path $Root "vcvars-$a.bat"
        @('@echo off', "call `"$vs\VC\Auxiliary\Build\vcvarsall.bat`" $vcArgs >nul 2>&1") |
            Set-Content -Encoding ASCII -Path $vcvars
        $vcvars = "cmd /c `"$vcvars`" && "
    }
    Install-OpenSsl $Root $hashes.openssl.version $a $vcvars
}

Say "bootstrap completado"
