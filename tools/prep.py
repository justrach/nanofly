#!/usr/bin/env python3
"""Makes data/ from public sources (run again to refresh them):

  land110.bin, land50.bin  Natural Earth's land (public domain), 1:110m and 1:50m:
                           each outline as points on the Web Mercator square
                           (0 to 1, x east, y south), little-endian:
                           "NFL1", u32 outlines, then each: u32 points, f32 x, f32 y...
  airports.tsv             OpenFlights' airports (ODbL): IATA, ICAO, name, city,
                           country, latitude, longitude, time zone
  airlines.tsv             vradarserver's standing data (CC0): ICAO, IATA, name

  python3 tools/prep.py [DOWNLOAD_DIR]
"""
import csv, io, json, math, os, struct, sys, urllib.request

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "data")
cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", ".prep-cache")
os.makedirs(cache, exist_ok=True)

SOURCES = {
    "land110.json": "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_land.geojson",
    "land50.json": "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_50m_land.geojson",
    "airports.dat": "https://raw.githubusercontent.com/jpatokal/openflights/master/data/airports.dat",
    "airlines.csv": "https://raw.githubusercontent.com/vradarserver/standing-data/main/airlines/schema-01/airlines.csv",
}


def fetch(name):
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        urllib.request.urlretrieve(SOURCES[name], path)
    return path


def mercator(lon, lat):
    lat = max(-85.0, min(85.0, lat))
    y = math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
    return (lon + 180.0) / 360.0, 0.5 - y / (2 * math.pi)


def land(name, dest):
    data = json.load(open(fetch(name)))
    rings = []
    for f in data["features"]:
        g = f["geometry"]
        for poly in [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"]:
            ring = [mercator(lon, lat) for lon, lat in poly[0]]
            # GeoJSON closes each ring by repeating its first point.
            if len(ring) > 1 and ring[0] == ring[-1]:
                ring.pop()
            # Points the projection made the same (Antarctica's edge).
            dedup = [p for i, p in enumerate(ring) if i == 0 or p != ring[i - 1]]
            if len(dedup) >= 3:
                rings.append(dedup)
    with open(os.path.join(out, dest), "wb") as f:
        f.write(b"NFL1" + struct.pack("<I", len(rings)))
        for r in rings:
            f.write(struct.pack("<I", len(r)))
            f.write(b"".join(struct.pack("<ff", x, y) for x, y in r))
    print(dest, len(rings), "outlines,", sum(len(r) for r in rings), "points")


def clean(s):
    return s.replace("\t", " ").replace("\n", " ").strip()


def airports():
    rows = []
    for r in csv.reader(open(fetch("airports.dat"), encoding="utf-8")):
        iata, icao, kind, tz = r[4], r[5], r[12], r[11]
        if kind != "airport" or len(icao) != 4 or icao == "\\N":
            continue
        iata = iata if len(iata) == 3 else ""
        tz = "" if tz == "\\N" else tz
        rows.append([iata, icao, clean(r[1]), clean(r[2]), clean(r[3]), "%.5f" % float(r[6]), "%.5f" % float(r[7]), tz])
    rows.sort(key=lambda r: r[1])
    with open(os.path.join(out, "airports.tsv"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    print("airports.tsv", len(rows))


def airlines():
    rows = []
    text = open(fetch("airlines.csv"), encoding="utf-8-sig").read()
    for r in csv.DictReader(io.StringIO(text)):
        if len(r["ICAO"]) == 3:
            rows.append([r["ICAO"], r["IATA"] if len(r["IATA"]) == 2 else "", clean(r["Name"])])
    rows.sort()
    with open(os.path.join(out, "airlines.tsv"), "w", encoding="utf-8") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    print("airlines.tsv", len(rows))


land("land110.json", "land110.bin")
land("land50.json", "land50.bin")
airports()
airlines()
