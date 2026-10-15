<#
    Prepara una maquina Windows para poder ejecutar build-qt-win.ps1.

    La receta nunca ha sido autosuficiente: en la maquina donde se desarrollo
    quedaron a mano cuatro entradas que el script no preparaba y sin las cuales
    no arranca. Esto las resuelve y las DECLARA, para que el mismo camino
    funcione en un runner efimero de CI o en una maquina nueva:

      1. Perl nativo (Strawberry). syncqt.pl lo necesita y el de Git no vale.
      2. OpenSSL 3.5.9 de desarrollo, por arquitectura.
      3. El tarball oficial 5.15.19, solo para superponer include/QtANGLE.
      4. flex/bison, que lo baja la propia receta; aqui no se toca.

    (Los dos ficheros DLL de ANGLE van aparte, en prebuilt/angle/: no se pueden
    construir desde el git de Qt. Ver el README de ese directorio.)

    Todo se descarga y se HASH VERIFICA. Nada se reutiliza porque exista: si el
    hash no cuadra, el fichero se borra y se vuelve a bajar. Es la misma regla de
    procedencia de la que ya habla el README.

    Compatible con Windows PowerShell 5.1 y con pwsh 7: el encadenamiento de
    comandos va DENTRO de los .bat porque "&&" entre sentencias solo existe a
    partir de PowerShell 7.
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'both')][string]$Arch = 'both',
    # Donde queda todo. En un runner efimero esto es $env:RUNNER_TEMP.
    [string]$Root = 'C:\qtbuild'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# En PowerShell 7.3+ un comando nativo que escribe en stderr se convierte en error
# terminante cuando ErrorActionPreference es Stop, incluso devolviendo 0. Aqui el
# codigo de salida se comprueba a mano, asi que ese comportamiento solo produce
# fallos falsos; se desactiva. La variable no existe en 5.1.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Say([string]$m) { Write-Host ('==> ' + $m) }

# --- utilidades -------------------------------------------------------------

function Get-Sha256([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
}

# Descarga y verifica en el mismo sitio. Si el hash no es el esperado, el
# fichero se borra: uno corrupto que se queda ahi es peor que uno que no se ha
# descargado, porque el error aparece mucho mas tarde y en otro sitio.
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
        throw ("hash incorrecto en $What" + [Environment]::NewLine +
               "  esperado $Sha256" + [Environment]::NewLine +
               "  obtenido $got" + [Environment]::NewLine +
               "  url     $Url")
    }
    Move-Item $tmp $Dest -Force
    Say "$What descargado y verificado"
    return $Dest
}

# --- 1. Perl nativo ---------------------------------------------------------

function Install-Perl([string]$ToolsDir) {
    # Tiene que ser el NATIVO. El Perl de Git es una build MSYS y su
    # Cwd::getcwd() devuelve /c/...; syncqt.pl usa eso como srcbase y los
    # forwarding headers salen corruptos, con lo que el build muere mas tarde con
    # C1083 en un modulo que no parece tener relacion con Perl.
    $perlExe = Join-Path $ToolsDir 'sp\perl\bin\perl.exe'
    if (Test-Path $perlExe) { Say 'Perl nativo ya presente'; return }

    # La URL viene del fichero de hashes, NO se construye. Construirla del
    # numero de version daba tags que no existen (SP_5361_1 da 404: el formato
    # real es SP_54051_64bit, con el bit y el sufijo).
    $hashesFile = Join-Path $PSScriptRoot 'bootstrap-hashes.json'
    if (-not (Test-Path $hashesFile)) { throw "falta $hashesFile con los hashes del bootstrap" }
    $sp = (Get-Content $hashesFile -Raw | ConvertFrom-Json).strawberryPerl
    if (-not $sp) { throw 'Strawberry Perl no esta fijado en bootstrap-hashes.json' }

    $zip = Join-Path $ToolsDir ('strawberry-perl-' + $sp.version + '-portable.zip')
    Get-Verified $sp.url $zip $sp.sha256 ('Strawberry Perl ' + $sp.version) | Out-Null

    # Se descomprime YA en <tools>\sp, que es la raiz que la receta espera
    # (<raiz>\perl\bin\perl.exe). El zip no trae un nivel 'sp/', asi que
    # descomprimir en <tools> dejaba perl.exe un nivel mas arriba; moverlo
    # despues no sirve, porque en ese caso la raiz ES <tools> y un directorio no
    # se puede mover dentro de si mismo.
    $spDir = Join-Path $ToolsDir 'sp'
    Say 'descomprimiendo Perl (~1 min)'
    New-Item -ItemType Directory -Force -Path $spDir | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $spDir -Force

    # Si aun asi no esta, se busca y se dice DONDE esta, en vez de un "no
    # encuentro perl.exe" que no ayuda.
    if (-not (Test-Path $perlExe)) {
        $cualquiera = Get-ChildItem $spDir -Recurse -Filter 'perl.exe' -File -ErrorAction SilentlyContinue |
                      Select-Object -First 1
        if (-not $cualquiera) { throw ('el zip no contiene ningun perl.exe bajo ' + $spDir) }
        throw ('perl.exe quedo en ' + $cualquiera.FullName +
               ' pero la receta necesita ' + $perlExe +
               ' (dos niveles por encima del fichero, con un directorio perl en medio)')
    }
    if (-not (Test-Path $perlExe)) { throw ('no quedo perl.exe en ' + $perlExe + ' tras descomprimir') }

    # Comprobacion de fondo, no de forma: es lo que de verdad importa.
    $cwd = & $perlExe -MCwd -e 'print Cwd::getcwd()'
    if ($cwd -notmatch '^[A-Za-z]:') {
        throw ('ese perl devuelve el cwd como ' + $cwd + '. Es un Perl MSYS (el de Git), no el nativo: ' +
               'syncqt.pl lo usaria de srcbase con rutas POSIX y los forwarding headers saldrian corruptos')
    }
    Say ('Perl nativo listo (getcwd = ' + $cwd + ', con formato Windows)')
}

# --- 2. OpenSSL de desarrollo ----------------------------------------------

# Qt se configura con -openssl-runtime: en ejecucion carga las DLL que trae la
# aplicacion, pero en compilacion sigue haciendo falta openssl/include y los .lib
# de importacion. Se compila desde el fuente oficial con el mismo toolset en vez
# de bajarse un binario de terceros: es lo unico que no depende de que alguien
# mantenga un build precompilado, y son unos minutos por arquitectura.
function Install-OpenSsl([string]$Root, [string]$Ver, [string]$ArchName, [string]$VcScript) {
    $app = Join-Path (Join-Path $Root ('openssl\' + $ArchName)) 'app'
    $inc = Join-Path $app 'include'
    $lib = Join-Path $app 'lib'
    if ((Test-Path $inc) -and (Test-Path $lib)) {
        $n = (Get-ChildItem $lib -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($n -gt 0) { Say ('OpenSSL ' + $Ver + ' (' + $ArchName + ') ya presente (' + $n + ' ficheros en lib)'); return }
    }

    $hashes = Get-Content (Join-Path $PSScriptRoot 'bootstrap-hashes.json') -Raw | ConvertFrom-Json
    if (-not $hashes.openssl) { throw 'OpenSSL no esta fijado en bootstrap-hashes.json' }
    $tar = Join-Path $Root ('openssl-' + $Ver + '.tar.gz')
    Get-Verified $hashes.openssl.url $tar $hashes.openssl.sha256 ('OpenSSL ' + $Ver + ' (fuente)') | Out-Null

    $src = Join-Path $Root ('openssl-src\' + $ArchName)
    if (Test-Path $src) { Remove-Item $src -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Say 'descomprimiendo OpenSSL'
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    # La salida de tar se captura: si falla, el motivo esta ahi y no hace falta
    # reproducirlo en una maquina de depuracion.
    $salida = & $tarExe -xf $tar -C $src 2>&1
    $rc = $LASTEXITCODE
    $salida | Select-Object -First 5 | ForEach-Object { if ("$_" -ne '') { Write-Host ('    tar: ' + $_) } }
    if ($rc -ne 0) {
        throw ('tar fallo al descomprimir OpenSSL (exit ' + $rc + ')' + [Environment]::NewLine + ($salida | Out-String))
    }

    # El tarball trae un unico directorio raiz con la version dentro.
    $raiz = @(Get-ChildItem $src -Directory -ErrorAction SilentlyContinue)
    if ($raiz.Count -eq 0) {
        $todo = @(Get-ChildItem $src -ErrorAction SilentlyContinue | Select-Object -First 8)
        throw ('tar devolvio ' + $rc + ' pero no dejo ningun directorio en ' + $src +
               '. Contenido: ' +
               $(if ($todo.Count -gt 0) { ($todo | ForEach-Object { $_.Name }) -join ', ' } else { '(vacio)' }))
    }
    $work = Join-Path $raiz[0].FullName $ArchName

    $bat = Join-Path $Root ('openssl-' + $ArchName + '.bat')
    $rel = (Resolve-Path $work).Path
    @(
        '@echo off',
        ('call "' + $VcScript + '" >nul 2>&1'),
        ('cd /d "' + $rel + '"'),
        'perl Configure VC-WIN32A no-shared no-tests no-asm',
        'nmake /S > build.log 2>&1',
        'if errorlevel 1 exit /b 1',
        ('mkdir "' + $app + '" 2>nul'),
        ('xcopy /e /i /q include "' + $inc + '" >nul'),
        ('if not exist "' + $app + '\nss" mkdir "' + $app + '\nss"'),
        ('xcopy /e /i /q /s lib\*.lib "' + $app + '\nss" >nul'),
        ('xcopy /e /i /q /s lib\*.dll "' + $app + '\nss" >nul'),
        'exit /b 0'
    ) | Set-Content -Encoding ASCII -Path $bat

    Say ('compilando OpenSSL ' + $Ver + ' (' + $ArchName + '), unos minutos')
    $p = Start-Process cmd.exe -ArgumentList '/c', $bat -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        $log = Join-Path $work 'build.log'
        if (Test-Path $log) {
            Write-Host '--- ultimas lineas del build de OpenSSL ---'
            Get-Content $log -Tail 20 | ForEach-Object { Write-Host ('  ' + $_) }
        }
        throw ('OpenSSL (' + $ArchName + ') fallo con exit ' + $p.ExitCode)
    }
    # Sin esto, el paso siguiente falla con un "no encuentro openssl/include" que
    # no dice que lo que fallo fue el copy y no la compilacion.
    if (-not (Test-Path $inc)) { throw ('OpenSSL (' + $ArchName + ') compilo pero no hay headers en ' + $inc) }
    Say ('OpenSSL ' + $Ver + ' (' + $ArchName + ') listo en ' + $app)
}

# --- 3. tarball oficial (solo para include/QtANGLE) ------------------------

function Install-QtOfficialTarball([string]$Root, [string]$Ver, [string]$Sha256) {
    $dest = Join-Path $Root ('toolgrab\qtbase-official-' + $Ver + '.tar.xz')
    $partes = $Ver.Split('.')
    $url = 'https://download.qt.io/archive/qt/' + $partes[0] + '.' + $partes[1] + '/' + $Ver +
           '/submodules/qtbase-everywhere-opensource-src-' + $Ver + '.tar.xz'
    Get-Verified $url $dest $Sha256 ('qtbase oficial ' + $Ver + ' (solo para include/QtANGLE)') | Out-Null
}

# --- main -------------------------------------------------------------------

$tools = Join-Path $Root 'tools'
$hashes = Get-Content (Join-Path $PSScriptRoot 'bootstrap-hashes.json') -Raw | ConvertFrom-Json
$archs = if ($Arch -eq 'both') { @('x64', 'x86') } else { @($Arch) }

Say ('bootstrap en ' + $Root + ' (arquitecturas: ' + ($archs -join ', ') + ')')

Install-Perl $tools
Install-QtOfficialTarball $Root $hashes.qtOfficialVersion $hashes.qtOfficialTarballSha256

# OpenSSL necesita el toolset, que en un runner hay que inicializar antes.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'no encuentro vswhere; hace falta Visual Studio con las herramientas de C++' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'no encuentro la instalacion de Visual Studio con las herramientas de C++' }

foreach ($a in $archs) {
    # El x86 es Win7 y necesita el toolset v142 (VS2019) y el SDK 10.0.19041.
    # En un runner con VS2022 hay que pedir explicitamente esa version: con la
    # que hay por defecto el binario ya no funciona en Win7.
    if ($a -eq 'x86') {
        $vcScript = Join-Path $Root 'vcvars-x86.bat'
        @('@echo off',
          ('call "' + $vs + '\VC\Auxiliary\Build\vcvarsall.bat" x86 -vcvars_ver=14.29 10.0.19041.0')) |
            Set-Content -Encoding ASCII -Path $vcScript
    } else {
        $vcScript = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    }
    Install-OpenSsl $Root $hashes.openssl.version $a $vcScript
}

Say 'bootstrap completado'
