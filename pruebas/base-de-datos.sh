#!/usr/bin/env bash
#
# Que la base se arme de una sola pasada.
#
# # Por qué existe
#
# `repo-add` descomprime la base entera, la modifica, la vuelve a comprimir y
# —cuando se firma— la vuelve a firmar. Llamarlo una vez por paquete, como se
# hacía, son treinta y cuatro reescrituras completas de la base para llegar
# exactamente al mismo resultado que una. Y `.PKGINFO` se extraía del paquete
# una vez por cada campo que se le pedía: cuatro descompresiones por paquete
# para leer cuatro líneas.
#
# Nada de eso da error si vuelve: da una publicación que tarda de más. Por eso
# se comprueba sobre el texto del script, que es donde vive la diferencia —no
# hay salida distinta que mirar—.
#
# La igualdad del resultado se comprobó a mano corriendo las dos versiones sobre
# copias del repositorio: la base y el índice JSON salieron idénticos.
#
# Uso: pruebas/base-de-datos.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

[ -f build-db.sh ] || { echo "No se encontró build-db.sh" >&2; exit 1; }

printf '\033[1mUna sola pasada\033[0m\n'

# El cuerpo del bucle que recorre los paquetes: desde `for package in` hasta el
# `done` de esa misma columna.
bucle="$(awk '/^for package in "\$\{PACKAGES\[@\]\}"; do/ { dentro = 1 }
              dentro { print }
              dentro && /^done$/ { exit }' build-db.sh)"

# Sin comentarios: el bucle los tiene y varios nombran a `repo-add` para
# explicar por qué se firma antes de agregar. Buscar el nombre a secas encuentra
# esas líneas y no una llamada.
codigo="$(sed -e 's/[[:space:]]*#.*$//' <<<"$bucle" | grep -v '^[[:space:]]*$')"

if [ -z "$bucle" ]; then
    mal 'no se encontró el bucle que recorre los paquetes'
else
    if grep -qE '(^|[[:space:];&|])repo-add[[:space:]]' <<<"$codigo"; then
        mal 'repo-add volvió a quedar adentro del bucle: una reescritura de la base por paquete'
    else
        ok 'repo-add no se llama adentro del bucle'
    fi

    # Una sola lectura del paquete por vuelta. `pkginfo_de` es la que lo
    # descomprime; `campo_de` sólo mira el texto que aquélla devolvió.
    veces=$(grep -cE '(^|[[:space:]=$(])pkginfo_de[[:space:]"]' <<<"$codigo" || true)
    if [ "$veces" -eq 1 ]; then
        ok 'el paquete se descomprime exactamente una vez por vuelta'
    else
        mal "el paquete se descomprime $veces veces por vuelta; tendría que ser una"
    fi

    # Y que nadie descomprima por su cuenta salteándose esa función.
    if grep -q 'bsdtar' <<<"$codigo"; then
        mal 'hay un bsdtar suelto en el bucle, fuera de pkginfo_de'
    else
        ok 'no hay descompresiones sueltas en el bucle'
    fi
fi

# Y que efectivamente se llame una vez, con todos los paquetes.
if grep -qE '^repo-add .*"\$\{PACKAGES\[@\]\}"' build-db.sh; then
    ok 'repo-add recibe todos los paquetes en una llamada'
else
    mal 'no hay una llamada a repo-add con todos los paquetes'
fi

# La marca de la extracción única: una función que devuelve el .PKGINFO entero
# y otra que busca un campo adentro de ese texto.
if grep -q '^pkginfo_de()' build-db.sh && grep -q '^campo_de()' build-db.sh; then
    ok 'el .PKGINFO se lee una vez y se consulta sobre lo leído'
else
    mal 'volvió la función que descomprime el paquete por cada campo'
fi

# Que el script siga siendo bash válido, que es lo mínimo antes de firmar nada.
if bash -n build-db.sh 2>/dev/null; then
    ok 'build-db.sh es sintácticamente válido'
else
    mal 'build-db.sh no es bash válido'
fi

echo
if [ "$fallos" -eq 0 ]; then
    printf '\033[32mTodo bien.\033[0m\n'
    exit 0
fi
printf '\033[31m%d comprobación(es) fallaron.\033[0m\n' "$fallos"
exit 1
