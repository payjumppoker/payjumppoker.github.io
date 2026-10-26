#!/bin/bash
# Payjump — instalador para Mac (2026-10-26).
#
# Uso, desde la Terminal:
#     curl -fsSL https://payjumppoker.com/mac.sh | bash
#
# POR QUE ASI Y NO UN .pkg. En Mac no hay un equivalente gratis de la Microsoft
# Store: firmar y notarizar exige el Apple Developer Program (USD 99/año). Sin
# firma, lo que se baja con el NAVEGADOR queda marcado con
# `com.apple.quarantine` y Gatekeeper lo frena ("Apple no pudo verificar..."),
# con una salida escondida en Ajustes > Privacidad y seguridad. `curl` no pone
# esa marca, y lo que este script crea en el disco tampoco la tiene: por eso no
# aparece ningun cartel.
#
# Lo que hace:
#   1. baja el paquete de Payjump (dist/ + los .sh, sin nada de Windows);
#   2. baja el Node OFICIAL para macOS de nodejs.org, la MISMA version que va
#      embebida en el instalador de Windows (viene en node-version.txt adentro
#      del paquete), verifica su SHA-256 y deja solo el binario en runtime/.
#      Ese binario esta firmado y notarizado por el proyecto Node.js, no por
#      nosotros. Esto cierra lo que frenaba un instalador de Mac en
#      docs/INSTALADOR.md: "un instalador que igual pide instalar Node a mano
#      no ahorra el paso que duele";
#   3. instala en ~/Library/Application Support/Payjump. Al ACTUALIZAR no toca
#      config.txt, marca.json, la licencia ni manos.db: el paquete no los trae,
#      y la copia se hace encima;
#   4. crea ~/Applications/Payjump.app (aparece en Spotlight y Launchpad), que
#      abre una ventana de Terminal con el servidor — el equivalente de la
#      consola de Payjump.bat en Windows: cerrarla apaga la app;
#   5. la abre.
#
# Todo va adentro de main(), que se llama en la ULTIMA linea: si la descarga
# del script se corta a la mitad, bash no ejecuta un instalador a medias.
# Compatible con el bash 3.2 que trae macOS: nada de arrays asociativos ni
# ${var,,}.
#
# Variables para probar (no hacen falta para instalar):
#   PAYJUMP_PAQUETE_URL  de donde bajar el paquete (acepta file://)
#   PAYJUMP_NODE_MIRROR  de donde bajar Node (default https://nodejs.org/dist)
#   PAYJUMP_DIR          carpeta de instalacion
#   PAYJUMP_APPS_DIR     donde crear Payjump.app (default ~/Applications)
#   PAYJUMP_NO_ABRIR=1   no abrir la app al terminar

set -euo pipefail

PAQUETE_URL_DEFECTO="https://github.com/payjumppoker/payjumppoker.github.io/releases/latest/download/payjump-mac.tar.gz"

decir() { printf '%s\n' "$*"; }
fallar() {
    printf '\n[X] %s\n' "$1" >&2
    if [ -n "${2:-}" ]; then printf '    %s\n' "$2" >&2; fi
    printf '\n    Si no lo podes resolver, escribinos a support@payjumppoker.com\n    con este mensaje.\n\n' >&2
    exit 1
}

arquitectura_node() {
    local m
    m="$(uname -m)"
    # Una Terminal corriendo bajo Rosetta dice x86_64 en una Mac con chip
    # Apple. El Node de Intel andaria (emulado), pero mas lento y sin razon.
    if [ "$m" = "x86_64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
        m="arm64"
    fi
    case "$m" in
        arm64) echo "darwin-arm64" ;;
        x86_64) echo "darwin-x64" ;;
        *) fallar "No reconozco el procesador de esta Mac ($m)." ;;
    esac
}

main() {
    if [ "$(uname -s)" != "Darwin" ]; then
        fallar "Este instalador es para Mac." \
            "En Windows, Payjump se baja de la Microsoft Store. En Linux, pedinos el ZIP."
    fi
    command -v curl >/dev/null 2>&1 || fallar "No encuentro curl, que viene con macOS."
    command -v shasum >/dev/null 2>&1 || fallar "No encuentro shasum, que viene con macOS."

    local paquete_url node_mirror dest apps arch tmp
    paquete_url="${PAYJUMP_PAQUETE_URL:-$PAQUETE_URL_DEFECTO}"
    node_mirror="${PAYJUMP_NODE_MIRROR:-https://nodejs.org/dist}"
    dest="${PAYJUMP_DIR:-$HOME/Library/Application Support/Payjump}"
    apps="${PAYJUMP_APPS_DIR:-$HOME/Applications}"
    arch="$(arquitectura_node)"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/payjump.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf \"$tmp\"" EXIT

    decir ""
    decir "============================================"
    decir "  Instalando Payjump"
    decir "============================================"
    decir ""

    # --- 1. El paquete -------------------------------------------------------
    decir "1/4  Bajando Payjump..."
    curl -fL --progress-bar "$paquete_url" -o "$tmp/payjump.tar.gz" \
        || fallar "No pude bajar el paquete de Payjump." "Revisa tu conexion a internet y volve a correr el comando."
    mkdir "$tmp/nuevo"
    tar -xzf "$tmp/payjump.tar.gz" -C "$tmp/nuevo" \
        || fallar "El paquete bajado esta dañado." "Volve a correr el comando."
    [ -f "$tmp/nuevo/dist/index.js" ] || fallar "El paquete bajado esta incompleto (falta dist/index.js)."
    [ -f "$tmp/nuevo/node-version.txt" ] || fallar "El paquete bajado esta incompleto (falta node-version.txt)."

    local node_version
    node_version="$(tr -d ' \r\n' < "$tmp/nuevo/node-version.txt")"
    case "$node_version" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *) fallar "El paquete trae una version de Node que no entiendo: '$node_version'." ;;
    esac

    # --- 2. Node -------------------------------------------------------------
    local node_actual=""
    if [ -x "$dest/runtime/node" ]; then
        node_actual="$("$dest/runtime/node" --version 2>/dev/null || true)"
    fi
    local node_nuevo=""
    if [ "$node_actual" = "$node_version" ]; then
        decir "2/4  Node $node_version ya esta instalado."
    else
        decir "2/4  Bajando el motor (Node $node_version, de nodejs.org)..."
        local base="node-$node_version-$arch"
        curl -fsSL "$node_mirror/$node_version/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt" \
            || fallar "No pude bajar la lista de verificacion de Node." "Revisa tu conexion a internet."
        curl -fL --progress-bar "$node_mirror/$node_version/$base.tar.gz" -o "$tmp/$base.tar.gz" \
            || fallar "No pude bajar Node." "Revisa tu conexion a internet y volve a correr el comando."
        local esperado obtenido
        # `|| true`: con set -e + pipefail, un grep sin resultado mataria el
        # script EN SILENCIO; asi llega al chequeo de abajo, que dice por que.
        esperado="$(grep " $base.tar.gz\$" "$tmp/SHASUMS256.txt" | awk '{print $1}' || true)"
        obtenido="$(shasum -a 256 "$tmp/$base.tar.gz" | awk '{print $1}')"
        [ -n "$esperado" ] || fallar "nodejs.org no publica $base.tar.gz."
        [ "$esperado" = "$obtenido" ] \
            || fallar "El Node bajado no coincide con el que publica nodejs.org." "Puede ser una descarga cortada: volve a correr el comando."
        tar -xzf "$tmp/$base.tar.gz" -C "$tmp" "$base/bin/node" \
            || fallar "No pude descomprimir Node."
        node_nuevo="$tmp/$base/bin/node"
        chmod +x "$node_nuevo"
        "$node_nuevo" --version >/dev/null 2>&1 \
            || fallar "Node no arranca en esta Mac." "Puede que tu macOS sea muy viejo para esta version: actualiza macOS y volve a probar."
        "$node_nuevo" -e "require('node:sqlite')" >/dev/null 2>&1 \
            || fallar "Este Node no puede abrir la biblioteca de manos (node:sqlite)."
    fi

    # --- 3. Instalar ---------------------------------------------------------
    decir "3/4  Instalando en: $dest"
    mkdir -p "$dest"
    # dist/ se reemplaza ENTERO (un archivo que la version nueva ya no trae no
    # tiene que quedar dando vueltas). Lo demas se copia ENCIMA: config.txt,
    # marca.json, la licencia y manos.db no vienen en el paquete, asi que
    # sobreviven a la actualizacion.
    rm -rf "$dest/dist"
    cp -R "$tmp/nuevo/." "$dest/"
    if [ -n "$node_nuevo" ]; then
        mkdir -p "$dest/runtime"
        rm -f "$dest/runtime/node"
        cp "$node_nuevo" "$dest/runtime/node"
    fi
    # El paquete se arma en Windows, donde no existe el permiso de ejecucion.
    chmod +x "$dest"/*.sh "$dest/runtime/node"

    cat > "$dest/Payjump.command" <<'COMANDO'
#!/bin/bash
# Lo abre Payjump.app en una ventana de Terminal. Cerrar la ventana apaga la app.
cd "$(dirname "$0")" && exec ./start.sh
COMANDO
    chmod +x "$dest/Payjump.command"

    # --- 4. Payjump.app ------------------------------------------------------
    decir "4/4  Creando Payjump en Aplicaciones..."
    local app="$apps/Payjump.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Payjump</string>
    <key>CFBundleDisplayName</key><string>Payjump</string>
    <key>CFBundleIdentifier</key><string>com.payjumppoker.payjump</string>
    <key>CFBundleExecutable</key><string>Payjump</string>
    <key>CFBundleIconFile</key><string>Payjump</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    # El ejecutable de la .app solo abre la Terminal con Payjump.command y
    # termina: el servidor vive en esa ventana, como en Windows.
    {
        printf '#!/bin/bash\n'
        printf 'open -a Terminal %q\n' "$dest/Payjump.command"
    } > "$app/Contents/MacOS/Payjump"
    chmod +x "$app/Contents/MacOS/Payjump"
    if [ -f "$dest/icono.png" ] && command -v sips >/dev/null 2>&1; then
        sips -s format icns "$dest/icono.png" --out "$app/Contents/Resources/Payjump.icns" >/dev/null 2>&1 || true
    fi
    touch "$app"

    decir ""
    decir "============================================"
    decir "  Listo. Payjump quedo instalado."
    decir "============================================"
    decir ""
    decir "Para abrirlo: buscalo como \"Payjump\" en Spotlight (Cmd+Espacio) o en"
    decir "Launchpad. Se abre una ventana de Terminal con el servidor y despues el"
    decir "navegador: deja esa ventana abierta mientras lo uses."
    decir ""
    decir "Si Payjump ya estaba abierto, cerra su ventana de Terminal y volvelo a"
    decir "abrir para usar la version nueva."
    decir ""
    decir "Para actualizar mas adelante, corre el mismo comando de nuevo: tu"
    decir "configuracion, tu licencia y tus manos importadas se conservan."
    decir ""

    if [ "${PAYJUMP_NO_ABRIR:-}" != "1" ]; then
        open "$app" 2>/dev/null \
            || decir "No pude abrirlo solo. Abrilo desde Spotlight, o corre: open $(printf '%q' "$dest/Payjump.command")"
    fi
}

main "$@"
