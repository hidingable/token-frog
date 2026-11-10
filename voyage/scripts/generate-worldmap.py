#!/usr/bin/env python3
"""Rasterize world-atlas land TopoJSON into Sources/VoyageCore/WorldMapData.swift.

Usage: generate-worldmap.py <land-50m.json> <output.swift> [--width 480 --height 200]
"""
import argparse
import json
from pathlib import Path

WIDTH, HEIGHT = 480, 200
LAT_TOP, LAT_BOTTOM = 84.0, -60.0


def decode_arcs(topo):
    scale, translate = topo["transform"]["scale"], topo["transform"]["translate"]
    decoded = []
    for arc in topo["arcs"]:
        x = y = 0
        points = []
        for dx, dy in arc:
            x += dx
            y += dy
            points.append((x * scale[0] + translate[0], y * scale[1] + translate[1]))
        decoded.append(points)
    return decoded


def ring_points(ring, arcs):
    points = []
    for index in ring:
        arc = arcs[index] if index >= 0 else list(reversed(arcs[~index]))
        points.extend(arc[1:] if points else arc)
    return points


def land_rings(topo):
    arcs = decode_arcs(topo)
    rings = []

    def add(geometry):
        kind = geometry["type"]
        if kind == "GeometryCollection":
            for child in geometry["geometries"]:
                add(child)
        elif kind == "Polygon":
            rings.extend(ring_points(ring, arcs) for ring in geometry["arcs"])
        elif kind == "MultiPolygon":
            for polygon in geometry["arcs"]:
                rings.extend(ring_points(ring, arcs) for ring in polygon)

    add(topo["objects"]["land"])
    return rings


def unwrap(ring):
    """Makes longitudes continuous so rings crossing the antimeridian do not smear across the map."""
    points = [ring[0]]
    for lon, lat in ring[1:]:
        while lon - points[-1][0] > 180:
            lon -= 360
        while lon - points[-1][0] < -180:
            lon += 360
        points.append((lon, lat))
    return points


def scanline_events(rings, lat):
    """Return longitude boundaries whose parity determines land along this latitude."""
    events = []
    for ring, bottom, top in rings:
        if not bottom <= lat < top:
            continue
        crossings = []
        previous = ring[-1]
        for point in ring:
            if (point[1] > lat) != (previous[1] > lat):
                crossings.append(previous[0] + (lat - previous[1]) * (point[0] - previous[0]) / (point[1] - previous[1]))
            previous = point
        crossings.sort()

        # A point can lie in any wrapped copy of a ring, but counts only once for
        # that ring. Union its wrapped intervals before toggling polygon parity.
        intervals = sorted(
            (left - offset, right - offset)
            for left, right in zip(crossings[::2], crossings[1::2])
            for offset in (-360, 0, 360)
            if right - offset > -180 and left - offset < 180
        )
        if not intervals:
            continue
        start, end = intervals[0]
        for left, right in intervals[1:]:
            if left <= end:
                end = max(end, right)
            else:
                events.extend((start, end))
                start, end = left, right
        events.extend((start, end))
    return sorted(events)


def rasterize(rings, width, height):
    rings = [(ring, min(lat for _, lat in ring), max(lat for _, lat in ring)) for ring in rings]
    rows = []
    for y in range(height):
        hits = [0] * width
        # Keep the original five subcell samples and two-hit coastline threshold.
        # Samples sharing a latitude reuse the same coastline intersections.
        for sy, sample_xs in ((0.5, (0.5,)), (0.2, (0.2, 0.8)), (0.8, (0.2, 0.8))):
            lat = LAT_TOP - (y + sy) / height * (LAT_TOP - LAT_BOTTOM)
            events = scanline_events(rings, lat)
            for sx in sample_xs:
                event = 0
                inside = False
                for x in range(width):
                    lon = (x + sx) / width * 360 - 180
                    # Left boundaries belong to land; right boundaries do not,
                    # matching the original ray-crossing comparison.
                    while event < len(events) and events[event] <= lon:
                        inside = not inside
                        event += 1
                    hits[x] += inside
        rows.append("".join("#" if count >= 2 else "." for count in hits))
    return rows


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=positive_int, default=WIDTH)
    parser.add_argument("--height", type=positive_int, default=HEIGHT)
    args = parser.parse_args()
    with args.source.open(encoding="utf-8") as handle:
        rings = [unwrap(ring) for ring in land_rings(json.load(handle))]
    rows = rasterize(rings, args.width, args.height)
    body = ",\n".join(f'        "{row}"' for row in rows)
    swift = f"""// Generated by scripts/generate-worldmap.py from world-atlas {args.source.name} (Natural Earth, public domain).
public enum WorldMapData {{
    public static let width = {args.width}
    public static let height = {args.height}
    public static let latTop = {LAT_TOP}
    public static let latBottom = {LAT_BOTTOM}
    public static let rows: [String] = [
{body},
    ]
}}
"""
    with args.output.open("w", encoding="utf-8") as handle:
        handle.write(swift)
    print(f"Generated {args.width}×{args.height} world map: {args.output} ({len(swift.encode('utf-8')):,} bytes)")


if __name__ == "__main__":
    main()
