# nevertube_qt_build

Receta y vigilancia de los árboles de Qt 5.15 que la app vendoriza.

**Este repo NO contiene los binarios.** Los árboles están en
[`marlo4220mc/nevertube_qt2`](https://github.com/marlo4220mc/nevertube_qt2), en
`third_party/qt-win32` (x86/Win7) y `third_party/qt-win64`. Aquí vive **cómo se
construyen** y **cuándo hay que volver a hacerlo**.

La separación es deliberada: la receta es un job lento y raro que necesita
Windows con MSVC v142, Perl nativo, flex/bison y las DLL de ANGLE. Eso no
pertenece al repo de una aplicación cuyo CI tiene que ser rápido y no puede
dependir de la red.

## Qué consume y qué no la app

| | |
|---|---|
| La app usa | los árboles vendorizados, en el repo, sin red |
| Este repo produce | esos árboles, y avisa cuando hay que rehacerlos |
| Acoplamiento | uno, y explícito: alguien sube el árbol y actualiza el `BOM.json` |

El `BOM.json` de dentro de cada árbol es una **copia** de `qt-sources.json`, escrita
por la receta al construir. No es la fuente: si alguien los edita a mano, los dos
ficheros dejan de cuadrar y eso hay que verlo.

## `qt-sources.json` es la única fuente de verdad

Commits **fijados**, no la punta de la rama. Es lo que hace que "Windows y Linux
llevan el mismo Qt" sea cierto por construcción y no solo cierto el día que
compilaste alguien. Son los mismos commits con los que Arch construye
`qt5-base`, `qt5-tools`, `qt5-imageformats` y `qt5-multimedia`.

Vive aquí y no en el repo de la app porque el watcher tiene que leerlo, y
`GITHUB_TOKEN` no alcanza otro repositorio. Poner el origen aquí quita el problema
del token y el deriva de dos ficheros.

### La etiqueta es `5.15.19+kde+r96`

No es "5.15.19 + parches de KDE", que era inexacto. La etiqueta correcta sale de
una fórmula, la misma que usa el PKGBUILD de Arch:

```bash
echo "$_basever+kde+r"$(git rev-list --count v$_basever-lts-lgpl..$_commit)
```

Con `_basever=5.15.19` y `_commit=fbed962c…` eso da **96**, o sea
**`5.15.19+kde+r96`**. `+kde+rN` es el esquema de Qt para commits posteriores al
corte, no una invención de Arch.

Lo que **no** es lo mismo:

- `MODULE_VERSION = 5.15.19` en `qtbase/.qmake.conf` → lo que emite Qt y lo que
  leen los DLL. Correcto, pero solo dice de dónde viene la rama.
- `5.15.19+kde+r96` → la etiqueta del paquete, que además declara que hay **96
  commits de la rama por detrás** del corte, no solo parches de distro.

Confundir las dos fue como el BOM anterior quedó mal dos veces: una vez
declarando el tarball oficial, y una vez ("5.15.19 + KDE patches") pareciendo
mucho más preciso de lo que era.

El número se puede comprobar, y conviene comprobarlo: este árbol lleva **SQLite
3.49.1** y **libpng 1.6.47**, el tarball oficial 5.15.19 lleva SQLite 3.46.1 y
libpng 1.6.44. Al reconstruir, si esos números cambian, es para mirar, no para
volver a subir sin decir por qué.

Y una comprobación que salió de escribir esto: el `_commit` que fija Arch es
**exactamente** nuestro commit, y nuestro pin es la **cabeza** de `kde/5.15`
(nada por delante). El "mismo Qt que en Linux" es cierto y está medido, no
supuesto.

> La receta **no puede** calcular el `r96` ella misma: descarga archivos por
> commit en vez de clonar, así que no hay historial contra el que correr
> `rev-list`. Por eso la etiqueta vive en `qt-sources.json`.

## Reconstruir

```powershell
# x64 primero (es la que tarda menos y avisa antes si algo se rompió)
pwsh build-qt-win.ps1 -Arch x64 -Work C:\qtbuild\work\x64 -Dest C:\qtbuild\out\qt-winx64
pwsh build-qt-win.ps1 -Arch x86 -Work C:\qtbuild\work\x86 -Dest C:\qtbuild\out\qt-winx86
```

`-Work` y `-Dest` son explícitos a propósito. El destino por defecto se calcula
como `<este repo>/third_party/...`, que **no existe aquí**: si alguien lo deja
puesto y ejecuta desde un recurso compartido por SMB, `Resolve-Path` produce
`\\host\...\..\third_party` (el padre del recurso, no el repo) y
`[IO.File]::WriteAllText` rechaza el `..` de una ruta UNC con un error que no
dice nada del path real. Es lo que pasó.

Requisitos en la máquina, ninguno se instala solo:

| | |
|---|---|
| MSVC | v142 (VS2019) para x86; el x86 es Win7 y no compila con toolset moderno |
| Perl | **Strawberry**, no el de Git. El de Git es MSYS y `Cwd::getcwd()` devuelve `/c/...`; `syncqt.pl` lo usa de `srcbase` y sale corrupto |
| flex/bison | winflexbison (los baja la receta) |
| OpenSSL | ficheros de desarrollo 3.5.9 por arquitectura |
| ANGLE | `libEGL.dll` y `libGLESv2.dll` precompilados (ver abajo) |

## Lo que hay que saber para no perder tres builds

Estas cinco cosas costaron un build entero cada una. Están todas comentadas en
la receta junto al sitio donde aplican, pero el resumen es:

**1. `syncqt` solo corre si hay `.git`.** `configure.bat` lo lanza únicamente si
encuentra ese directorio. Sin él no se generan los forwarding headers y el build
muere con `C1083` en el primer módulo que los incluye —que fue `QtXml`, luego
`QtWidgets` vía `QtPlatformHeaders`, luego `QtDBus`, uno por uno—. Por eso se pasa
`-no-syncqt` y se corre a mano, y por eso la lista de módulos se **deriva de los
campos `TARGET` de los `.pro`**: escrita a mano se escapaba uno de cada vez.

**2. `syncqt.pl` vive solo en qtbase.** Para cada repo de módulo hay que llamar al
de qtbase pasándole ese repo como `srcbase`. Sin esto, `qtmultimedia` se queda sin
`include/QtMultimedia` y revienta en `qvideoframe.h`.

**3. ANGLE no es construible desde el git de Qt.** Ni el git de upstream ni el de
KDE traen **un solo `.pro`** bajo `src/3rdparty/angle`, y su generador `win32cpp.exe`
no está en ningún tarball público. En el tarball oficial ANGLE vive en `src/angle/`
y trae además `include/QtANGLE`, que es lo que `src/platformsupport/eglconvenience`
espera (`$$QT_MODULE_INCLUDE_BASE/QtANGLE`). La receta superpone ese `include`
sobre el árbol de KDE y copia las DLL desde `-AngleBin`. ANGLE es código de
Khronos: ni Qt ni KDE lo parchean.

**4. `nmake install` de un repo hermano instala 3 headers donde hay 224.**
`qtmultimedia.pro` no declara `INSTALLS` y su Makefile no tiene regla `syncqt`, así
que sin el paso explícito de `Install-ModuleHeaders` el paquete x86 salía **sin
`<QAudioOutput>`**, que es su motor de audio.

**5. En `include/<M>/`, el fichero con el nombre del header es la _sombra_, no el
header.** La sombra dice `#include "../../src/multimedia/audio/qaudio.h"`; el
header de verdad está en `src/`. Copiar la sombra al prefix hace que la app falle
al compilar con `C1083` en `qaudio.h(1,10)`. La receta copia el real de `src/` y
solo las sombras que no apuntan fuera del prefix.

Y el detalle que costó dos intentos de CI: las sombras se emparejan **por su
contenido**, no por nombre. Qt las escribe en CamelCase (`qaudiodeviceinfo.h` →
`QAudioDeviceInfo`), y derivar el nombre del fichero produce `Qaudiodeviceinfo`,
que no existe.

## La regla que resume todo

**Solo se reutiliza lo que se puede demostrar.** Un árbol de fuentes se reutiliza
únicamente si puede probarse que es ese commit (árbol git limpio en el commit
registrado, o tarball conservado y re-hasheado). El prefix se reutiliza solo si la
procedencia registrada dice que se construyó con esas fuentes. Cualquier otra cosa
se descarta y se vuelve a descargar.

Esto no es purismo. La receta anterior reutilizaba el árbol siempre que el
directorio existía y **grababa el sha256 esperado en el BOM** sin comprobar nada;
el BOM declaraba el tarball oficial de Qt mientras los binarios eran de la rama
KDE. La diferencia se podía medir (SQLite 3.49.1 contra 3.46.1) y nadie la miró
porque el BOM afirmaba lo contrario.

## Automatización

`watch-kde.yml` corre cada lunes y compara la rama `kde/5.15` contra
`qt-sources.json`. Si hay commit nuevo abre un issue con los SHA y los pasos.

**No reconstruye.** Dos razones, y las dos importan:

- Reconstruir son ~40 min por arquitectura con un toolchain que un runner no tiene.
- Si `invent.kde.org` devuelve 503 (pasa, por mantenimiento), el watcher avisa y no
  toca nada. No puede crear una referencia para "arreglar" un problema que no
  existe, que es exactamente el modo de fallo del BOM antiguo.

Un issue por semana sin cerrar sería ruido, así que no se abre uno si ya hay otro
abierto con el mismo título.

## Lo que no está automatizado

La reconstrucción. No hay workflow de build aquí a propósito: no se ha podido
ejecutar uno contra un runner real, y publicar un workflow que dice funcionar sin
haberlo visto funcionar sería la misma mentira que acabamos de arreglar en el BOM.
Cuando exista uno validado, que avise el recipe de que ya no hay que hacerlo a mano.
