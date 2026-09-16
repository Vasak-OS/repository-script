#!/usr/bin/env bash
#
# Que toda bandera que el script acepta esté en su ayuda.
#
# # Por qué existe
#
# `--no-portability-check` existía y funcionaba desde siempre, y no figuraba en
# la ayuda. O sea que la única forma de encontrarla era leer el `case` del
# script. Cuando el control de portabilidad empezó a tardar de más, la respuesta
# —«se puede saltear»— ya estaba escrita y era invisible.
#
# Una bandera sin documentar no falla nunca: simplemente no la usa nadie. Por
# eso se comprueba a máquina, comparando lo que el script **acepta** contra lo
# que **dice** que acepta.
#
# Uso: pruebas/banderas-documentadas.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

script=update-repo.sh
[ -f "$script" ] || { echo "No se encontró $script" >&2; exit 1; }

printf '\033[1mLas banderas de %s\033[0m\n' "$script"

# Lo que acepta: las ramas del `case` del bucle de argumentos. Cada rama puede
# ofrecer varias formas separadas por `|`, y `*)` es la de «cualquier otra cosa».
mapfile -t aceptadas < <(
    awk '/^while \[\[ \$# -gt 0 \]\]; do/ { dentro = 1; next }
         dentro && /^done$/ { exit }
         dentro' "$script" |
        grep -oE '^[[:space:]]*-[^)]*\)' |
        tr -d ' )' | tr '|' '\n' | grep -E '^-' | sort -u
)

if [ "${#aceptadas[@]}" -eq 0 ]; then
    mal 'no se encontró ninguna bandera en el bucle de argumentos'
    printf '\n\033[31mNo se pudo comprobar nada.\033[0m\n'
    exit 1
fi

ayuda="$(./"$script" --help 2>/dev/null)"
if [ -z "$ayuda" ]; then
    mal '--help no imprimió nada'
    printf '\n\033[31mNo se pudo comprobar nada.\033[0m\n'
    exit 1
fi

sin_documentar=()
for bandera in "${aceptadas[@]}"; do
    grep -qF -- "$bandera" <<<"$ayuda" || sin_documentar+=("$bandera")
done

if [ "${#sin_documentar[@]}" -eq 0 ]; then
    ok "las ${#aceptadas[@]} banderas que acepta están en la ayuda"
else
    mal "sin documentar: ${sin_documentar[*]}"
fi

# Y la de este arreglo, por nombre: es la que hay que poder encontrar cuando el
# control de portabilidad molesta.
if grep -qF -- '--no-portability-check' <<<"$ayuda"; then
    ok '--no-portability-check figura en la ayuda'
else
    mal '--no-portability-check volvió a quedar invisible'
fi

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
    exit 0
fi
printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
exit 1
