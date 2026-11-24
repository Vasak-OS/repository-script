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

MESES = {
    m: n
    for n, m in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)
}


def dia_del_log(ts):
    """`24/Nov/2026:14:26:59 +0000` -> date(2026, 11, 24).

    A mano y no con strptime porque `%b` depende del locale del servidor y nginx
    escribe los meses siempre en inglés: en un servidor en español, strptime
    fallaría con todos los meses.

    La fecha es la del servidor. Un pedido a las 23:50 cae en el día del
    servidor, no en el del visitante, y para un conteo diario eso alcanza.
    """
    dia, mes, anio = ts.split(":", 1)[0].split("/")
    return date(int(anio), MESES[mes], int(dia))


def abrir(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", errors="replace")
    return open(path, "rt", errors="replace")


def contar(paths, desde):
    """Devuelve {día: {ip, ...}} con lo pedido desde `desde`."""
    ips = defaultdict(set)
    parseadas = 0

    for path in paths:
        try:
            fh = abrir(path)
        except OSError as e:
            print(f"aviso: no se pudo leer {path}: {e}", file=sys.stderr)
            continue
        with fh:
            for line in fh:
                # Prefiltro barato antes del regex: la mayoría de las líneas no
                # son del repositorio.
                if TARGET not in line or AGENT not in line:
                    continue
                m = LINE.match(line)
                if not m:
                    continue
                parseadas += 1
                # El pedido exacto, para que `vasakos.db.sig` no pase.
                pedido = m["req"].split(" ")
                if len(pedido) < 2 or pedido[1] != TARGET:
                    continue
                # 4xx y 5xx son bots, escaneos y errores: no son instalaciones.
                if int(m["status"]) >= 400:
                    continue
                try:
                    dia = dia_del_log(m["ts"])
                except (ValueError, KeyError):
                    # Una línea con la fecha rota no puede tumbar el cron.
                    continue
                if dia >= desde:
                    ips[dia].add(m["ip"])

    if parseadas == 0 and paths:
        print(
            "aviso: ninguna línea se pudo parsear. ¿El formato del log no es "
            "`combined`, o las rutas de --logs no son las correctas?",
            file=sys.stderr,
        )
    return ips


def unicas(ips, desde=None):
    total = set()
    for dia, conjunto in ips.items():
        if desde is None or dia >= desde:
            total |= conjunto
    return len(total)


def main():
    hoy = date.today()

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
        dest="imprimir",
        action="store_true",
        help="imprimir el JSON por stdout además de escribirlo",
    )
    args = p.parse_args()

    desde = hoy - timedelta(days=args.days - 1)
    patrones = args.logs or ["/www/wwwlogs/repo.vasak.net.ar.log*"]

    paths = []
    for patron in patrones:
        encontrados = sorted(glob.glob(patron))
        if not encontrados:
            print(f"aviso: {patron} no coincide con ningún archivo", file=sys.stderr)
        paths.extend(encontrados)

    ips = contar(paths, desde)
    if not ips:
        print(
            "aviso: cero días con tráfico en la ventana. Se escribe el JSON "
            "igual, con los conteos en cero, para no dejar a la web con un "
            "archivo viejo.",
            file=sys.stderr,
        )

    dias = sorted(ips)
    doc = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": TARGET.rsplit("/", 1)[-1],
        "window_days": args.days,
        "first_day": dias[0].isoformat() if dias else None,
        "last_day": dias[-1].isoformat() if dias else None,
        "unique_7d": unicas(ips, hoy - timedelta(days=6)),
        "unique_30d": unicas(ips, hoy - timedelta(days=29)),
        "unique_90d": unicas(ips),
        "daily": [{"date": d.isoformat(), "ips": len(ips[d])} for d in dias],
    }

    texto = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"

    if args.out:
        # Atómico: la web puede estar leyendo el archivo mientras se reescribe.
        tmp = args.out + ".tmp"
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(texto)
        os.replace(tmp, args.out)

    if args.imprimir or not args.out:
        sys.stdout.write(texto)

    print(
        f"{len(paths)} archivo(s), {len(dias)} día(s) con tráfico, "
        f"{doc['unique_90d']} IP(s) únicas en {args.days} días",
        file=sys.stderr,
    )

    # Si los logs no llegan tan atrás como la ventana, el número no es de 90
    # días y hay que verlo, no adivinarlo.
    if dias and dias[0] > desde + timedelta(days=1):
        print(
            f"aviso: los logs empiezan el {dias[0]}, no el {desde}. "
            f"`unique_90d` cubre {len(dias)} días, no {args.days}.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
