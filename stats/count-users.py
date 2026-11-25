#!/usr/bin/env python3
"""Cuenta las IPs únicas que piden vasakos.db y deja el conteo en un JSON.

Lo consume la web (os.vasak.net.ar). El JSON lleva sólo números: no se guarda
ninguna IP en ningún lado, y el conteo se recalcula entero desde los logs cada
vez, así que el script no mantiene estado ni necesita base de datos.

Se corre por cron una vez al día. Ver la sección «Contar instalaciones» del
README para lo que tiene que estar puesto antes (IP real en nginx, retención de
logs, CORS).

Uso:
    ./count-users.py --logs '/www/wwwlogs/repo.vasak.net.ar.log*' \
                     --out /www/wwwroot/repo.vasak.net.ar/stats/users.json
"""

import argparse
import glob
import gzip
import json
import os
import re
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

# Lo que pide cada instalación al actualizar. `.files` queda afuera porque
# pacman sólo lo baja con `-Fy`, que casi nadie usa; `.sig` también, porque lo
# pide la misma máquina que pidió el `.db` y no sumaría nada.
TARGET = "/repo/x86_64/vasakos/vasakos.db"
AGENT = "pacman/"

# El formato `combined` de nginx:
#   ip - user [fecha] "request" estado bytes "referer" "ua"
# Anclado al principio y sin anclar al final: aaPanel agrega `$request_time`
# detrás, y eso no tiene por qué romper el parseo.
LINE = re.compile(
    r'^(?P<ip>\S+) \S+ \S+ \[(?P<ts>[^\]]+)\] "(?P<req>[^"]*)" '
    r'(?P<status>\d{3}) \S+ "[^"]*" "(?P<ua>[^"]*)"'
)

MONTHS = {
    m: n
    for n, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)
}


def log_day(ts):
    """`24/Nov/2026:14:26:59 +0000` -> date(2026, 11, 24).

    A mano y no con strptime porque `%b` depende del locale del servidor y nginx
    escribe los meses siempre en inglés: en un servidor en español, strptime
    fallaría con todos los meses.

    La fecha es la del servidor. Un pedido a las 23:50 cae en el día del
    servidor, no en el del visitante, y para un conteo diario eso alcanza.
    """
    day, month, year = ts.split(":", 1)[0].split("/")
    return date(int(year), MONTHS[month], int(day))


def open_log(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace")
    return open(path, "rt", errors="replace")


def count(paths, since):
    """Devuelve {día: {ip, ...}} con lo pedido desde `since`."""
    ips = defaultdict(set)
    parsed = 0

    for path in paths:
        try:
            handle = open_log(path)
        except OSError as e:
            print(f"aviso: no se pudo leer {path}: {e}", file=sys.stderr)
            continue
        with handle:
            for line in handle:
                # Prefiltro barato antes del regex: la mayoría de las líneas no
                # son del repositorio.
                if TARGET not in line or AGENT not in line:
                    continue
                m = LINE.match(line)
                if not m:
                    continue
                parsed += 1
                # GET sobre el pedido exacto. El método importa: un HEAD es
                # alguien mirando si el archivo está, no una máquina que se
                # actualiza. Y el pedido exacto deja afuera `vasakos.db.sig`.
                request = m["req"].split(" ")
                if len(request) < 2 or request[0] != "GET" or request[1] != TARGET:
                    continue
                # 4xx y 5xx son bots, escaneos y errores: no son instalaciones.
                if int(m["status"]) >= 400:
                    continue
                try:
                    day = log_day(m["ts"])
                except (ValueError, KeyError):
                    # Una línea con la fecha rota no puede tumbar el cron.
                    continue
                if day >= since:
                    ips[day].add(m["ip"])

    if parsed == 0 and paths:
        print(
            "aviso: ninguna línea se pudo parsear. ¿El formato del log no es "
            "`combined`, o las rutas de --logs no son las correctas?",
            file=sys.stderr,
        )
    return ips


def unique(ips, since=None):
    total = set()
    for day, seen in ips.items():
        if since is None or day >= since:
            total |= seen
    return len(total)


def main():
    today = date.today()

    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "--logs",
        action="append",
        metavar="GLOB",
        help="log o patrón de logs de nginx (repetible). "
        "Por defecto: /www/wwwlogs/repo.vasak.net.ar.log*",
    )
    p.add_argument(
        "--out",
        help="dónde escribir el JSON. Sin esto, se imprime por stdout.",
    )
    p.add_argument("--days", type=int, default=90, help="ventana en días (90)")
    p.add_argument(
        "--print",
        dest="print_json",
        action="store_true",
        help="imprimir el JSON por stdout además de escribirlo",
    )
    args = p.parse_args()

    since = today - timedelta(days=args.days - 1)
    patterns = args.logs or ["/www/wwwlogs/repo.vasak.net.ar.log*"]

    paths = []
    for pattern in patterns:
        found = sorted(glob.glob(pattern))
        if not found:
            print(f"aviso: {pattern} no coincide con ningún archivo", file=sys.stderr)
        paths.extend(found)

    ips = count(paths, since)
    if not ips:
        print(
            "aviso: cero días con tráfico en la ventana. Se escribe el JSON "
            "igual, con los conteos en cero, para no dejar a la web con un "
            "archivo viejo.",
            file=sys.stderr,
        )

    days = sorted(ips)
    doc = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": TARGET.rsplit("/", 1)[-1],
        "window_days": args.days,
        "first_day": days[0].isoformat() if days else None,
        "last_day": days[-1].isoformat() if days else None,
        "unique_7d": unique(ips, today - timedelta(days=6)),
        "unique_30d": unique(ips, today - timedelta(days=29)),
        "unique_90d": unique(ips),
        "daily": [{"date": d.isoformat(), "ips": len(ips[d])} for d in days],
    }

    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"

    if args.out:
        # Atómico: la web puede estar leyendo el archivo mientras se reescribe.
        # El pid en el nombre evita que dos corridas solapadas compartan el
        # temporal y una le borre el archivo a la otra.
        tmp = f"{args.out}.{os.getpid()}.tmp"
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, args.out)

    if args.print_json or not args.out:
        sys.stdout.write(text)

    print(
        f"{len(paths)} archivo(s), {len(days)} día(s) con tráfico, "
        f"{doc['unique_90d']} IP(s) únicas en {args.days} días",
        file=sys.stderr,
    )

    # Si los logs no llegan tan atrás como la ventana, el número no es de 90
    # días y hay que verlo, no adivinarlo.
    if days and days[0] > since + timedelta(days=1):
        print(
            f"aviso: los logs empiezan el {days[0]}, no el {since}. "
            f"`unique_90d` cubre {len(days)} días, no {args.days}.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
