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

# --- 1b. jom, el nmake que si paraleliza -----------------------------------

# NMAKE es de un solo hilo y no tiene bandera paraarlo: nmake 14.44 no declara
# /M entre sus opciones, y /MP es de cl.exe (que ademas solo paraleliza DENTRO de
# una invocacion, y qmake invoca cl una vez por .cpp). Medido en un runner de 4
# nucleos: qtbase paso de tres horas sin terminar.
#
# jom es un reemplazo de nmake que entiende -j, y es lo que configure.bat ya
# busca por la variable MAKE, asi que no hay que tocar el sistema de construccion.
function Install-Jom([string]$ToolsDir) {
    $exe = Join-Path $ToolsDir 'jom.exe'
    if (Test-Path $exe) { Say 'jom ya presente'; return }
    $h = (Get-Content (Join-Path $PSScriptRoot 'bootstrap-hashes.json') -Raw | ConvertFrom-Json).jom
    if (-not $h) { throw 'jom no esta fijado en bootstrap-hashes.json' }
    $tmp = Join-Path $ToolsDir 'jom-download.exe'
    Get-Verified $h.url $tmp $h.sha256 ('jom ' + $h.version) | Out-Null
    Move-Item $tmp $exe -Force
    # Comprobacion de que CONSTRUYE, no de que responde: se le pasa un Makefile
    # minimo y se mira que produzca el fichero. Un .exe que no arranca por una
    # dependencia que falta se descubre a mitad del build, que es donde duele.
    #
    # /VERSION y no -v porque jom no tiene -v: sus opciones llevan barra (/J, /S,
    # /VERSION). Con -v responde "unknown command line option" y sale con 128,
    # que es exactamente el falso fallo que hacia fallar el bootstrap entero.
    $v = & $exe /VERSION 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('jom no arranca (/VERSION): ' + ($v | Out-String)) }

    $prueba = Join-Path $ToolsDir 'jom-selftest'
    Remove-Item $prueba -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $prueba | Out-Null
    # CR/LF de verdad y un tabulador real (0x09), que es lo que make exige.
    Set-Content -Encoding ASCII -NoNewline -Path (Join-Path $prueba 'Makefile') `
        -Value ("all:`r`n" + [char]9 + "echo ok > out.txt`r`n")
    # El codigo de salida se mira a mano y la preferencia se baja alrededor: con
    # ErrorActionPreference=Stop, el stderr de un comando nativo se convierte en
    # error TERMINANTE. pwsh 7.3+ lo hace con PSNativeCommandUseErrorActionPreference
    # (que ya se desactiva arriba), pero Windows PowerShell 5.1 lo hace igual con
    # solo 2>&1, y ahi jom escribe parte de su salida. Sin esto, el canario falla
    # en 5.1 aunque jom este perfectamente bien.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $prueba
    & $exe /J 2 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    Pop-Location
    $ErrorActionPreference = $prevEap
    if (-not (Test-Path (Join-Path $prueba 'out.txt'))) {
        throw ('jom responde pero NO construye (rc=' + $rc + '). Sin esto, el build entero')
    }
    Remove-Item $prueba -Recurse -Force -ErrorAction SilentlyContinue
    Say ('jom ' + $h.version + ' listo, y construye de verdad')
}

# --- 2. OpenSSL de desarrollo ----------------------------------------------

# Qt se configura con -openssl-runtime: en ejecucion carga las DLL que trae la
# aplicacion, pero en compilacion sigue haciendo falta openssl/include y los .lib
# de importacion. Se compila desde el fuente oficial con el mismo toolset en vez
# de bajarse un binario de terceros: es lo unico que no depende de que alguien
# mantenga un build precompilado, y son unos minutos por arquitectura.
function Install-OpenSsl([string]$Root, [string]$Ver, [string]$ArchName, [string]$VcScript, [string]$PerlBin) {
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
    # El tarball NO trae subdirectorio por arquitectura: la raiz es
    # openssl-3.5.9/ y el subdirectorio x64 o x86 lo crea nmake al compilar.
    # Anadir $ArchName aqui daba una ruta que no existe.
    $work = $raiz[0].FullName

    # El target de Configure depende de la arquitectura: VC-WIN32A es el de 32
    # bits y para x64 hace falta VC-WIN64A.
    $target = if ($ArchName -eq 'x64') { 'VC-WIN64A' } else { 'VC-WIN32A' }

    # shared, NO no-shared. Qt se configura con -openssl-runtime: enlaza contra
    # los .lib de importacion y carga la DLL en ejecucion. Un build estatico
    # produce los mismos nombres pero con simbolos que no casan con la DLL, y el
    # fallo aparece al enlazar o al arrancar, no aqui.
    $bat = Join-Path $Root ('openssl-' + $ArchName + '.bat')
    # Strawberry TIENE que ir primero en el PATH. Sin esto, en un runner con Git
    # instalado, "perl" es el Perl MSYS de Git: Configure corre con el, genera un
    # Makefile que no sirve para nmake, y la compilacion se pasa 27 minutos
    # produciendo cero .lib en vez de fallar al instante. En una maquina sin Git
    # el mismo fallo es un 9009 inmediato. Comprobado en las dos, por eso se
    # comprueba en vez de suponer que el PATH ya esta bien.
    $bat = Join-Path $Root ('openssl-' + $ArchName + '.bat')
    $lineas = @(
        '@echo off'
        ('set "PATH=' + $PerlBin + ';%PATH%"')
        'where perl >nul 2>&1'
        'if errorlevel 1 (echo NO HAY PERL EN EL PATH 1>&2 & exit /b 1)'
        ('call "' + $VcScript + '" >nul 2>&1')
        ('cd /d "' + $work + '"')
        ('perl Configure ' + $target + ' shared no-tests no-asm')
        'if errorlevel 1 exit /b 1'
        'nmake /S > build.log 2>&1'
        'if errorlevel 1 exit /b 1'
        ('mkdir "' + $app + '" 2>nul')
        ('xcopy /e /i /q include "' + $inc + '" >nul')
        ('if not exist "' + $app + '\nss" mkdir "' + $app + '\nss"')
        # Con los targets VC-WIN* las .lib NO van a lib64\ ni a lib\: el
        # Makefile las deja en la RAIZ del arbol.
        #     LIBS= apps\libapps.lib libcrypto.lib libssl.lib ...
        #     INSTALL_LIBS="libcrypto.lib" "libssl.lib"
        # Por eso el xcopy se quedaba con cero ficheros tras 27 minutos de
        # compilacion sin que nada fallara. Se copia de la raiz y, ademas, de
        # lib64\ y lib\ por si otro target lo hiciera distinto. Las DLL van en util\.
        ('xcopy /e /i /q *.lib "' + $app + '\nss\" >nul')
        ('if exist lib64 xcopy /e /i /q /s lib64\*.lib "' + $app + '\nss\" >nul')
        ('if exist lib   xcopy /e /i /q /s lib\*.lib   "' + $app + '\nss\" >nul')
        ('if exist util  xcopy /e /i /q /s util\*.dll   "' + $app + '\nss\" >nul')
        ('if exist bin   xcopy /e /i /q /s bin\*.dll   "' + $app + '\nss\" >nul')
        'exit /b 0'
    )
    $lineas | Set-Content -Encoding ASCII -Path $bat


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
    # Por NOMBRE, no por cantidad: dos .lib cualesquiera no demuestran que
    # estén los de OpenSSL, que son los que Qt necesita para enlazar.
    $nssDir = Join-Path $app 'nss'
    $faltanLib = @()
    foreach ($l in @('libssl.lib', 'libcrypto.lib')) {
        if (-not (Test-Path (Join-Path $nssDir $l))) { $faltanLib += $l }
    }
    if ($faltanLib.Count -gt 0) {
        $hay = @(Get-ChildItem $nssDir -Filter '*.lib' -File -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Name })
        throw ('OpenSSL (' + $ArchName + ') no dejo ' + ($faltanLib -join ' ni ') + ' en ' + $nssDir +
               '. Target de Configure: ' + $target + '. Lo que si hay: ' +
               $(if ($hay.Count -gt 0) { ($hay | Select-Object -First 8) -join ', ' } else { '(ninguna)' }))
    }
    $nlibs = (Get-ChildItem $nssDir -Filter '*.lib' -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Say ('OpenSSL ' + $Ver + ' (' + $ArchName + ') listo en ' + $app + ' (' + $nlibs + ' .lib)')
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
Install-Jom $tools
Install-QtOfficialTarball $Root $hashes.qtOfficialVersion $hashes.qtOfficialTarballSha256

# OpenSSL necesita el toolset, que en un runner hay que inicializar antes.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'no encuentro vswhere; hace falta Visual Studio con las herramientas de C++' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'no encuentro la instalacion de Visual Studio con las herramientas de C++' }

$perlBin = Join-Path $tools 'sp\perl\bin'
if (-not (Test-Path (Join-Path $perlBin 'perl.exe'))) {
    throw ('no encuentro perl.exe en ' + $perlBin + '; Install-Perl deberia haberlo dejado ahi')
}

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
    Install-OpenSsl $Root $hashes.openssl.version $a $vcScript $perlBin
}

Say 'bootstrap completado'
