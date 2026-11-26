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

# Fechas en formato nginx: nginx escribe los meses siempre en inglés, así que
# se fija el locale a C para que `%b` dé inglés.
date_str() { LC_ALL=C date -d "$1" +%d/%b/%Y; }
# Fechas en ISO (%F), como las escribe el script en el JSON.
iso_str() { LC_ALL=C date -d "$1" +%F; }

log_line() { # ip, fecha, pedido, status, ua, [method=GET]
  printf '%s - - [%s:10:00:00 +0000] "%s %s HTTP/2" %s 10442 "-" "%s"\n' \
    "$1" "$2" "${6:-GET}" "$3" "$4" "$5"
}

# Lee un campo del JSON: field archivo '["unique_90d"]'
field() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1"; }
# Cuántos elementos tiene una lista del JSON.
field_len() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))$2))" "$1"; }

run() { # dir-de-logs, json, [args…]
  python3 "$script" --logs "$1/*" --out "$2" "${@:3}" 2>/dev/null
}

# Cuántas líneas alcanza a soltar un .gz cortado antes de reventar. El script no
# tiene que contar ninguna; esto es para comprobar que el fixture corta donde se
# cree que corta y no sobre un archivo que no soltó nada.
gz_lines_before_failure() {
  python3 - "$1" <<'PY'
import gzip, sys
n = 0
try:
    with gzip.open(sys.argv[1], "rt", errors="replace") as fh:
        for _ in fh:
            n += 1
except Exception:
    pass
print(n)
PY
}

printf '\033[1mContar instalaciones\033[0m\n'

# ── 1. La misma máquina que pide dos veces cuenta una ────────────────────────
d="$tmp/1"; mkdir -p "$d"
{
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/1.json"
if [ "$(field "$tmp/1.json" '["unique_90d"]')" = 1 ] &&
   [ "$(field "$tmp/1.json" '["daily"][0]["ips"]')" = 1 ]; then
  ok "dos pedidos de la misma IP son una instalación"
else
  mal "dos pedidos de la misma IP tendrían que ser una: $(cat "$tmp/1.json" | tr -d '\n ')"
fi

# ── 2. Lo que no es una instalación, no cuenta ───────────────────────────────
d="$tmp/2"; mkdir -p "$d"
{
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
  log_line 2.2.2.2 "$(date_str today)" "$DB.sig" 200 "$PACMAN"
  log_line 3.3.3.3 "$(date_str today)" /repo/x86_64/vasakos/vasakos.files 200 "$PACMAN"
  log_line 4.4.4.4 "$(date_str today)" "$DB" 404 "$PACMAN"
  log_line 5.5.5.5 "$(date_str today)" "$DB" 200 "curl/8.5.0"
  log_line 6.6.6.6 "$(date_str today)" "$DB" 200 "Mozilla/5.5 (compatible; Googlebot/2.1)"
  log_line 7.7.7.7 "$(date_str today)" /repo/x86_64/vasakos/vasak-desktop-0.7.2-1-x86_64.pkg.tar.zst 200 "$PACMAN"
  log_line 10.10.10.10 "$(date_str today)" "$DB" 500 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/2.json"
if [ "$(field "$tmp/2.json" '["unique_90d"]')" = 1 ]; then
  ok "quedan afuera .sig, .files, 404, 500, curl, bots y las descargas de paquetes"
else
  mal "contó de más: $(field "$tmp/2.json" '["unique_90d"]') en vez de 1"
fi

# ── 3. La ventana de días filtra ─────────────────────────────────────────────
d="$tmp/3"; mkdir -p "$d"
{
  log_line 8.8.8.8 "$(date_str today)" "$DB" 200 "$PACMAN"
  log_line 9.9.9.9 "$(date_str '200 days ago')" "$DB" 200 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/3.json"
run "$d" "$tmp/3b.json" --days 365
if [ "$(field "$tmp/3.json" '["unique_90d"]')" = 1 ] &&
   [ "$(field "$tmp/3b.json" '["unique_90d"]')" = 2 ]; then
  ok "una IP de hace 200 días entra con --days 365 y no con la ventana de 90"
else
  mal "la ventana no filtra: 90d=$(field "$tmp/3.json" '["unique_90d"]') 365d=$(field "$tmp/3b.json" '["unique_90d"]')"
fi

# ── 4. El total de la ventana es la unión, no la suma de los días ────────────
d="$tmp/4"; mkdir -p "$d"
{
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
  log_line 1.1.1.1 "$(date_str '10 days ago')" "$DB" 200 "$PACMAN"
  log_line 2.2.2.2 "$(date_str today)" "$DB" 200 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/4.json"
if [ "$(field "$tmp/4.json" '["unique_90d"]')" = 2 ] &&
   [ "$(field_len "$tmp/4.json" '["daily"]')" = 2 ]; then
  ok "una IP que actualiza dos días distintos cuenta una vez"
else
  mal "sumó los días en vez de unir: $(cat "$tmp/4.json" | tr -d '\n ')"
fi

# ── 5. Lee los logs comprimidos ──────────────────────────────────────────────
d="$tmp/5"; mkdir -p "$d"
log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN" | gzip -c > "$d/access.log-20260101.gz"
run "$d" "$tmp/5.json"
if [ "$(field "$tmp/5.json" '["unique_90d"]')" = 1 ]; then
  ok "lee los logs rotados en .gz"
else
  mal "no leyó el .gz: $(field "$tmp/5.json" '["unique_90d"]')"
fi

# ── 6. El JSON queda escrito y entero, sin el temporal colgado ───────────────
d="$tmp/6"; mkdir -p "$d"
log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN" > "$d/access.log"
run "$d" "$tmp/6/out/users.json"
if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$tmp/6/out/users.json" 2>/dev/null &&
   [ -z "$(find "$tmp/6" -name '*.tmp' -print -quit)" ]; then
  ok "escribe un JSON válido, creando el directorio y sin dejar el .tmp"
else
  mal "el JSON no quedó válido o quedó un .tmp: $(ls -R "$tmp/6")"
fi

# ── 7. Sin tráfico igual escribe, y no falla ─────────────────────────────────
d="$tmp/7"; mkdir -p "$d"
run "$d" "$tmp/7.json"
status=$?
if [ "$status" = 0 ] && [ "$(field "$tmp/7.json" '["unique_90d"]')" = 0 ] &&
   [ "$(field "$tmp/7.json" '["daily"]')" = '[]' ]; then
  ok "sin logs escribe el JSON en cero y sale 0"
else
  mal "sin tráfico salió $status o el JSON no es válido"
fi

# ── 8. Una línea con la fecha rota no lo tumba ───────────────────────────────
d="$tmp/8"; mkdir -p "$d"
{
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
  printf '2.2.2.2 - - [99/Foo/2026:10:00:00 +0000] "GET %s HTTP/2" 200 10442 "-" "%s"\n' "$DB" "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/8.json"
status=$?
if [ "$status" = 0 ] && [ "$(field "$tmp/8.json" '["unique_90d"]')" = 1 ]; then
  ok "una fecha rota se saltea y el conteo sigue"
else
  mal "la fecha rota lo tumbó (salió con $status) o contó mal"
fi

# ── 9. Sólo GET cuenta ───────────────────────────────────────────────────────
d="$tmp/9"; mkdir -p "$d"
log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN" HEAD > "$d/access.log"
run "$d" "$tmp/9.json"
if [ "$(field "$tmp/9.json" '["unique_90d"]')" = 0 ] &&
   [ "$(field "$tmp/9.json" '["daily"]')" = '[]' ]; then
  ok "un HEAD /repo/x86_64/vasakos/vasakos.db con agente pacman no cuenta"
else
  mal "un HEAD con agente pacman cuenta como instalación: $(cat "$tmp/9.json" | tr -d '\n ')"
fi

# ── 10. El JSON trae la ventana y los totales por día ────────────────────────
d="$tmp/10"; mkdir -p "$d"
{
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
  log_line 2.2.2.2 "$(date_str '20 days ago')" "$DB" 200 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/10.json"
if [ "$(field "$tmp/10.json" '["unique_7d"]')" = 1 ] &&
   [ "$(field "$tmp/10.json" '["unique_30d"]')" = 2 ] &&
   [ "$(field "$tmp/10.json" '["unique_90d"]')" = 2 ] &&
   [ "$(field "$tmp/10.json" '["first_day"]')" = "$(iso_str '20 days ago')" ] &&
   [ "$(field "$tmp/10.json" '["last_day"]')" = "$(iso_str today)" ] &&
   [ "$(field "$tmp/10.json" '["window_days"]')" = 90 ] &&
   [ "$(field "$tmp/10.json" '["source"]')" = "vasakos.db" ] &&
   [ -n "$(field "$tmp/10.json" '["generated"]')" ]; then
  ok "el JSON trae first_day, last_day, generated, source, window_days, unique_7d y unique_30d"
else
  mal "claves faltantes o con valores raros: $(cat "$tmp/10.json" | tr -d '\n ')"
fi

# ── 11. Sin --out imprime el JSON por stdout ─────────────────────────────────
d="$tmp/11"; mkdir -p "$d"
log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN" > "$d/access.log"
output=$(python3 "$script" --logs "$d/*" 2>/dev/null)
if printf '%s' "$output" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)['unique_90d'] == 1 else 1)"; then
  ok "sin --out imprime el JSON por stdout"
else
  mal "sin --out no imprime el JSON por stdout: $(printf '%s' "$output" | head -c 120)"
fi

# ── 12. El agente se mira en el campo del agente, no en la línea entera ──────
d="$tmp/12"; mkdir -p "$d"
printf '9.9.9.9 - - [%s:10:00:00 +0000] "GET %s HTTP/2" 200 10442 "pacman/7.0.0" "curl/8.5.0"\n' \
  "$(date_str today)" "$DB" > "$d/access.log"
run "$d" "$tmp/12.json"
if [ "$(field "$tmp/12.json" '["unique_90d"]')" = 0 ]; then
  ok "un curl con pacman en el referer no cuenta"
else
  mal "un curl con pacman en el referer contó como instalación: $(cat "$tmp/12.json" | tr -d '\n ')"
fi

# ── 13. Un .gz truncado se descarta entero ───────────────────────────────────
#
# El `.gz` tiene que ser grande a propósito. gzip descomprime en bloques, así que
# un archivo cortado cerca del final suelta miles de líneas antes de reventar;
# con una sola línea no suelta ninguna y la prueba pasaría igual aunque el script
# contara el pedazo leído. Se comprueba primero que el fixture corte donde se
# cree que corta, y si no, la prueba falla por el fixture y no por el script.
d="$tmp/13"; mkdir -p "$d"
today=$(date_str today)
log_line 1.1.1.1 "$today" "$DB" 200 "$PACMAN" > "$d/access.log"
for i in $(seq 1 3000); do
  log_line "192.0.2.$((i % 250 + 1))" "$today" "$DB" 200 "$PACMAN"
done | gzip -c > "$d/access.log.gz"
size=$(stat -c %s "$d/access.log.gz")
head -c $((size - size / 8)) "$d/access.log.gz" > "$d/cut.gz" && mv "$d/cut.gz" "$d/access.log.gz"
yielded=$(gz_lines_before_failure "$d/access.log.gz")
run "$d" "$tmp/13.json"
status=$?
if [ "$yielded" -lt 100 ]; then
  mal "el fixture no sirve: el .gz truncado soltó $yielded línea(s) antes de fallar y así no distingue nada"
elif [ "$status" = 0 ] && [ "$(field "$tmp/13.json" '["unique_90d"]')" = 1 ]; then
  ok "un .gz truncado grande se descarta entero (soltó $yielded líneas), el resto se cuenta y sale 0"
else
  mal "el .gz truncado tumbó la corrida (salió con $status) o contó algo de adentro: $(field "$tmp/13.json" '["unique_90d"]')"
fi

# ── 14. --days pequeño no corta unique_30d ───────────────────────────────────
d="$tmp/14"; mkdir -p "$d"
{
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
  log_line 2.2.2.2 "$(date_str '20 days ago')" "$DB" 200 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/14.json" --days 7
if [ "$(field "$tmp/14.json" '["unique_7d"]')" = 1 ] &&
   [ "$(field "$tmp/14.json" '["unique_30d"]')" = 2 ] &&
   [ "$(field "$tmp/14.json" '["unique_90d"]')" = 1 ] &&
   [ "$(field "$tmp/14.json" '["first_day"]')" = "$(iso_str today)" ]; then
  ok "con --days 7: uno hoy, otro de hace 20 días; 7d=1, 30d=2, 90d=1"
else
  mal "con --days 7: 7d=$(field "$tmp/14.json" '["unique_7d"]') 30d=$(field "$tmp/14.json" '["unique_30d"]') 90d=$(field "$tmp/14.json" '["unique_90d"]') first_day=$(field "$tmp/14.json" '["first_day"]')"
fi

# ── 15. logs_from mide hasta dónde llegan los logs, no hasta dónde llega el tráfico
d="$tmp/15"; mkdir -p "$d"
{
  log_line 8.8.8.8 "$(date_str '60 days ago')" /repo/x86_64/otro-0.1-1-x86_64.pkg.tar.zst 200 "$PACMAN"
  log_line 1.1.1.1 "$(date_str today)" "$DB" 200 "$PACMAN"
} > "$d/access.log"
run "$d" "$tmp/15.json"
if [ "$(field "$tmp/15.json" '["logs_from"]')" = "$(iso_str '60 days ago')" ] &&
   [ "$(field "$tmp/15.json" '["first_day"]')" = "$(iso_str today)" ]; then
  ok "logs_from llega al día del log más viejo; first_day al más viejo con tráfico"
else
  mal "logs_from o first_day no reflejan la retención: $(cat "$tmp/15.json" | tr -d '\n ')"
fi

echo
if [ "$fallos" -eq 0 ]; then
  printf '\033[32mTodo bien.\033[0m\n'
else
  printf '\033[31m%d prueba(s) en rojo.\033[0m\n' "$fallos"
fi
exit "$fallos"
