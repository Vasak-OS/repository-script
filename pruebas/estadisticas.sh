#!/usr/bin/env bash
#
# Que el contador de instalaciones cuente lo que dice contar.
#
# # Por qué existe
#
# El número es lo único que sale de acá, y no se puede verificar a ojo: si el
# filtro deja pasar un archivo de más, o toma el `.sig` como una visita, el JSON
# sale un poco más grande y se ve exactamente igual que uno que cuenta bien. Un
# contador que cuenta de más no falla nunca; miente despacio.
#
# Lo mismo con la ventana: si los 90 días se calcularan mal, el número cambiaría
# sin que nada avise.
#
# Las fechas del fixture se calculan desde hoy, no se escriben fijas: fijas, la
# prueba se pudre sola y dentro de 90 días pasa o falla sin que nadie entienda
# por qué.
#
# Uso: pruebas/estadisticas.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

fallos=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
mal() { printf '  \033[31m✗\033[0m %s\n' "$1"; fallos=$((fallos + 1)); }

script=stats/count-users.py
command -v python3 >/dev/null || { echo "Falta python3." >&2; exit 1; }
[ -f "$script" ] || { echo "No se encontró $script" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

DB=/repo/x86_64/vasakos/vasakos.db
PACMAN='pacman/7.0.0 (Linux 6.12 x86_64) libalpm/15.0.0'

# `%b` depende del locale, y nginx escribe los meses siempre en inglés.
fecha() { LC_ALL=C date -d "$1" +%d/%b/%Y; }

linea() { # ip, fecha, pedido, estado, ua
  printf '%s - - [%s:10:00:00 +0000] "GET %s HTTP/2" %s 10442 "-" "%s"\n' \
    "$1" "$2" "$3" "$4" "$5"
}

# Lee un campo del JSON: j archivo '["unique_90d"]'
j() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1"; }
# Cuántos elementos tiene una lista del JSON.
jl() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))$2))" "$1"; }

corre() { # dir-de-logs, json, [args…]
  python3 "$script" --logs "$1/*" --out "$2" "${@:3}" 2>/dev/null
}

printf '\033[1mContar instalaciones\033[0m\n'

# ── 1. La misma máquina que pide dos veces cuenta una ────────────────────────
d="$tmp/1"; mkdir -p "$d"
{
  linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN"
  linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN"
} > "$d/access.log"
corre "$d" "$tmp/1.json"
if [ "$(j "$tmp/1.json" '["unique_90d"]')" = 1 ] &&
   [ "$(j "$tmp/1.json" '["daily"][0]["ips"]')" = 1 ]; then
  ok "dos pedidos de la misma IP son una instalación"
else
  mal "dos pedidos de la misma IP tendrían que ser una: $(cat "$tmp/1.json" | tr -d '\n ')"
fi

# ── 2. Lo que no es una instalación, no cuenta ───────────────────────────────
d="$tmp/2"; mkdir -p "$d"
{
  linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN"
  linea 2.2.2.2 "$(fecha today)" "$DB.sig" 200 "$PACMAN"
  linea 3.3.3.3 "$(fecha today)" /repo/x86_64/vasakos/vasakos.files 200 "$PACMAN"
  linea 4.4.4.4 "$(fecha today)" "$DB" 404 "$PACMAN"
  linea 5.5.5.5 "$(fecha today)" "$DB" 200 "curl/8.5.0"
  linea 6.6.6.6 "$(fecha today)" "$DB" 200 "Mozilla/5.0 (compatible; Googlebot/2.1)"
  linea 7.7.7.7 "$(fecha today)" /repo/x86_64/vasakos/vasak-desktop-0.7.2-1-x86_64.pkg.tar.zst 200 "$PACMAN"
} > "$d/access.log"
corre "$d" "$tmp/2.json"
if [ "$(j "$tmp/2.json" '["unique_90d"]')" = 1 ]; then
  ok "quedan afuera .sig, .files, 404, curl, bots y las descargas de paquetes"
else
  mal "contó de más: $(j "$tmp/2.json" '["unique_90d"]') en vez de 1"
fi

# ── 3. La ventana de días filtra ─────────────────────────────────────────────
d="$tmp/3"; mkdir -p "$d"
{
  linea 8.8.8.8 "$(fecha today)" "$DB" 200 "$PACMAN"
  linea 9.9.9.9 "$(fecha '200 days ago')" "$DB" 200 "$PACMAN"
} > "$d/access.log"
corre "$d" "$tmp/3.json"
corre "$d" "$tmp/3b.json" --days 365
if [ "$(j "$tmp/3.json" '["unique_90d"]')" = 1 ] &&
   [ "$(j "$tmp/3b.json" '["unique_90d"]')" = 2 ]; then
  ok "una IP de hace 200 días entra con --days 365 y no con la ventana de 90"
else
  mal "la ventana no filtra: 90d=$(j "$tmp/3.json" '["unique_90d"]') 365d=$(j "$tmp/3b.json" '["unique_90d"]')"
fi

# ── 4. El total de la ventana es la unión, no la suma de los días ────────────
d="$tmp/4"; mkdir -p "$d"
{
  linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN"
  linea 1.1.1.1 "$(fecha '10 days ago')" "$DB" 200 "$PACMAN"
  linea 2.2.2.2 "$(fecha today)" "$DB" 200 "$PACMAN"
} > "$d/access.log"
corre "$d" "$tmp/4.json"
if [ "$(j "$tmp/4.json" '["unique_90d"]')" = 2 ] &&
   [ "$(jl "$tmp/4.json" '["daily"]')" = 2 ]; then
  ok "una IP que actualiza dos días distintos cuenta una vez"
else
  mal "sumó los días en vez de unir: $(cat "$tmp/4.json" | tr -d '\n ')"
fi

# ── 5. Lee los logs comprimidos ──────────────────────────────────────────────
d="$tmp/5"; mkdir -p "$d"
linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN" | gzip -c > "$d/access.log-20260101.gz"
corre "$d" "$tmp/5.json"
if [ "$(j "$tmp/5.json" '["unique_90d"]')" = 1 ]; then
  ok "lee los logs rotados en .gz"
else
  mal "no leyó el .gz: $(j "$tmp/5.json" '["unique_90d"]')"
fi

# ── 6. El JSON queda escrito y entero, sin el temporal colgado ───────────────
d="$tmp/6"; mkdir -p "$d"
linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN" > "$d/access.log"
corre "$d" "$tmp/6/out/users.json"
if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$tmp/6/out/users.json" 2>/dev/null &&
   [ -z "$(find "$tmp/6" -name '*.tmp' -print -quit)" ]; then
  ok "escribe un JSON válido, creando el directorio y sin dejar el .tmp"
else
  mal "el JSON no quedó válido o quedó un .tmp: $(ls -R "$tmp/6")"
fi

# ── 7. Sin tráfico igual escribe, y no falla ─────────────────────────────────
d="$tmp/7"; mkdir -p "$d"
corre "$d" "$tmp/7.json"
estado=$?
if [ "$estado" = 0 ] && [ "$(j "$tmp/7.json" '["unique_90d"]')" = 0 ] &&
   [ "$(j "$tmp/7.json" '["daily"]')" = '[]' ]; then
  ok "sin logs escribe el JSON en cero y sale 0"
else
  mal "sin tráfico salió $estado o el JSON no es válido"
fi

# ── 8. Una línea con la fecha rota no lo tumba ───────────────────────────────
d="$tmp/8"; mkdir -p "$d"
{
  linea 1.1.1.1 "$(fecha today)" "$DB" 200 "$PACMAN"
  printf '2.2.2.2 - - [99/Foo/2026:10:00:00 +0000] "GET %s HTTP/2" 200 10442 "-" "%s"\n' "$DB" "$PACMAN"
} > "$d/access.log"
corre "$d" "$tmp/8.json"
estado=$?
if [ "$estado" = 0 ] && [ "$(j "$tmp/8.json" '["unique_90d"]')" = 1 ]; then
  ok "una fecha rota se saltea y el conteo sigue"
else
  mal "la fecha rota lo tumbó (salida $estado) o contó mal"
fi

echo
if [ "$fallos" -eq 0 ]; then
  printf '\033[32mTodo bien.\033[0m\n'
else
  printf '\033[31m%d prueba(s) en rojo.\033[0m\n' "$fallos"
fi
exit "$fallos"
