# qt5-kde-win-build

Compilaciones reproducibles de **Qt 5.15 para Windows** desde la rama de
mantenimiento de KDE, con procedencia verificada y gate de imports para Win7.

Publica dos árboles listos para usar: **x64** y **x86/Win7**. Los consume
cualquier aplicación que linkee contra Qt; no hay nada en ellos específico de
ningún proyecto.

## Por qué existe

Porque las compilaciones oficiales de Qt para Windows **se quedaron en 5.15.2**:

```
download.qt.io/online/qtsdkrepository/windows_x86/desktop/
  -> 5.15.0, 5.15.1, 5.15.2 ... y nada más
```

Ese repositorio es el que usan `aqtinstall` e `install-qt-action`. Así que
"instala Qt en el CI" significa, en la práctica, "instala 5.15.2", que va 17
versiones de parche por detrás y sin las correcciones de seguridad de
5.15.3 → 5.15.19. Los **fuentes** oficiales sí están completos en
`download.qt.io/archive`.

Las opciones eran: aceptar 5.15.2, o compilar. Aquí se compila, y se hace desde
la rama que usa la distribución Linux, para que Windows y Linux lleven el mismo
Qt.

## Qué produce

Una **release** con:

- `qt-winx64.zip` y `qt-winx86.zip`: prefijos de Qt completos (headers, libs,
  plugins, `mkspecs`, `bin/`).
- El `BOM.json` de cada árbol, que registra qué se puso dentro: commit por
  módulo, SHA-256 del archivo que produce ese commit, toolset, flags de
  `configure` y versión de OpenSSL.

Consumirlos es copiar el árbol junto al proyecto y apuntar la compilación a él:

```sh
cmake -B build -DCMAKE_PREFIX_PATH=/ruta/al/arbol
# o, con qmake, usar su bin/qmake.exe
```

Nada dentro del árbol depende de este repositorio.

## `qt-sources.json` es la única fuente de verdad

Commits **fijados**, no la punta de la rama. Eso es lo que hace que "Windows y
Linux llevan el mismo Qt" sea cierto por construcción y no solo cierto el día que
compilaste alguien. Son los mismos commits con los que Arch construye
`qt5-base`, `qt5-tools`, `qt5-imageformats` y `qt5-multimedia`.

Vive aquí y no junto a los árboles publicados porque el watcher tiene que
leerlo, y `GITHUB_TOKEN` no alcanza otro repositorio. Poner el origen aquí quita
el problema del token y, sobre todo, el deriva entre dos ficheros.

El `BOM.json` de cada árbol es una **copia** de este fichero, escrita por la
receta al construir. Si alguien edita uno a mano, los dos dejan de cuadrar y eso
hay que verlo: por eso `rebuild.yml` **no publica** si el BOM generado no
coincide commit a commit con `qt-sources.json`.

### La etiqueta es `5.15.19+kde+r96`

No es "5.15.19 + parches de KDE", que sería inexacto. La etiqueta correcta sale
de una fórmula, la misma que usa el `PKGBUILD` de Arch:

```bash
echo "$_basever+kde+r"$(git rev-list --count v$_basever-lts-lgpl..$_commit)
```

`+kde+rN` es el esquema de Qt para commits posteriores a un corte, no una
invención de Arch.

Lo que **no** es lo mismo:

- `MODULE_VERSION = 5.15.19` en `qtbase/.qmake.conf` → lo que emite Qt y lo que
  leen los DLL. Dice de dónde viene la rama.
- `5.15.19+kde+r96` → la etiqueta del paquete, que además declara que hay **96
  commits por detrás** del corte, no solo parches de distro.

Contar esto necesita el `git rev-list` de verdad: filtrar commits por la fecha
del tag da 97, uno de más, porque hay un commit alcanzable desde el tag con fecha
anterior. La receta **no puede** calcularlo ella misma (descarga archivos por
commit en vez de clonar, así que no hay historial), y por eso la etiqueta vive en
`qt-sources.json`.

## Reconstruir a mano

```powershell
./ci/bootstrap.ps1 -Arch x64 -Root C:\qtbuild
.\build-qt-win.ps1 -Arch x64 -Work C:\qtbuild\work\x64 -Dest C:\qtbuild\out\qt-winx64 `
  -StrawberryPerl C:\qtbuild\tools\sp -OpenSslRoot C:\qtbuild\openssl `
  -QtOfficialTarball C:\qtbuild\toolgrab\qtbase-official-5.15.19.tar.xz `
  -AngleBin .\prebuilt\angle
```

El bootstrap deja el resto listo (Perl nativo, OpenSSL, tarball oficial) y
verifica cada descarga por SHA-256. Para x86, el toolset v142 y el SDK
10.0.19041 son obligatorios: Win7 no carga un binario hecho con el toolset
moderno, que importa `GetSystemTimePreciseAsFileTime` (Win8+).

`-Dest` explícito a propósito: el destino por defecto se calcula sobre
`<este repo>/third_party/...`, que no existe aquí. Si se ejecuta desde un recurso
compartido por SMB, `Resolve-Path` produce `\\host\...\..\third_party` —el padre
del recurso, no el repo— y `WriteAllText` rechaza el `..` de una ruta UNC con un
error que no dice nada del path real.

## Lo que hay que saber para no perder tres builds

Estas cinco cosas costaron un build entero (~40 min) cada una. Están comentadas
en la receta junto al sitio donde aplican.

**1. `syncqt` solo corre si hay `.git`.** `configure.bat` lo lanza únicamente si
encuentra ese directorio. Sin él no se generan los forwarding headers y el build
muere con `C1083` en el primer módulo que los incluye —que fue `QtXml`, luego
`QtWidgets` vía `QtPlatformHeaders`, luego `QtDBus`, uno por uno—. Por eso se pasa
`-no-syncqt` y se corre a mano, y por eso la lista de módulos se **deriva de los
campos `TARGET` de los `.pro`**: escrita a mano se escapaba uno de cada vez.

**2. `syncqt.pl` vive solo en qtbase.** Para cada repo de módulo hay que llamar al
de qtbase pasándole ese repo como `srcbase`. Sin esto, `qtmultimedia` se queda
sin `include/QtMultimedia` y revienta en `qvideoframe.h`.

**3. ANGLE no es construible desde el git de Qt.** Ni upstream ni KDE traen un
solo `.pro` bajo `src/3rdparty/angle`, y su generador `win32cpp.exe` no está en
ningún tarball público. Ver `prebuilt/angle/README.md`, que explica por qué y qué
se hace en su lugar.

**4. `nmake install` de un repo hermano instala 3 headers donde hay 224.**
`qtmultimedia.pro` no declara `INSTALLS` y su Makefile no tiene regla `syncqt`.
Sin el paso explícito de `Install-ModuleHeaders`, el paquete x86 salía **sin
`<QAudioOutput>`**.

**5. En `include/<M>/`, el fichero con el nombre del header es la _sombra_, no el
header.** La sombra dice `#include "../../src/multimedia/audio/qaudio.h"`; el
header de verdad está en `src/`. Copiar la sombra al prefix hace que la aplicación
falle con `C1083` en `qaudio.h(1,10)`.

Y el detalle que costó dos intentos: las sombras se emparejan **por su
contenido**, no por nombre. Qt las escribe en CamelCase (`qaudiodeviceinfo.h` →
`QAudioDeviceInfo`); derivar el nombre del fichero produce `Qaudiodeviceinfo`,
que no existe.

## La regla que resume todo

**Solo se reutiliza lo que se puede demostrar.** Un árbol de fuentes se reutiliza
únicamente si puede probarse que es ese commit (árbol git limpio en el commit
registrado, o tarball conservado y re-hasheado). El prefix se reutiliza solo si la
procedencia registrada dice que se construyó con esas fuentes. Cualquier otra
cosa se descarta y se vuelve a descargar.

No es purismo. La razón original de hacerlo así: la receta reutilizaba el árbol
siempre que el directorio existía y **grababa el sha256 esperado en el BOM** sin
comprobar nada. El BOM declaraba el tarball oficial de Qt mientras los binarios
venían de la rama KDE, y la diferencia se podía medir (SQLite 3.49.1 contra
3.46.1) pero nadie la miró, porque el BOM afirmaba lo contrario.

## Automatización

| workflow | qué hace |
|---|---|
| `watch-kde.yml` | Compara la rama con lo fijado, cada lunes. Si hay commit nuevo, abre issue **y lanza la reconstrucción**. |
| `rebuild.yml` | Compila x64 y x86, verifica el BOM y publica una release. A mano o disparado por el watcher. |

El ciclo es automático **hasta el punto de consumo**: nadie empuja nada a tu
proyecto sin que alguien lo decida, porque automatizar eso exigiría un token de
otro repositorio y sería justo el acoplamiento invisible que hizo que el BOM
antiguo mintiera.

Cuando `invent.kde.org` devuelve 503 (pasa, por mantenimiento), el watcher avisa
y no toca nada. No puede crear una referencia para "arreglar" un problema que no
existe.

Lo que **no** está automatizado, a propósito: el consumo. Y el watcher no
duplica el issue si ya hay uno abierto con el mismo título, porque si no se
acumularía uno por semana.

## Licencia

Qt es **LGPL-3.0** con enlace dinámico: los árboles son de LGPL, cada módulo lo
declara en su `LICENSE.*`. ANGLE (los dos DLL de `prebuilt/angle/`) es
**BSD-3-Clause** de Google, con su licencia junto a ellos. Compilar esta receta
no cambia ninguna de las dos.

Qt es una marca de The Qt Company Ltd. Esta documentación no está afiliada a Qt
ni a KDE.
