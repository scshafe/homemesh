"""Synthetic RoomPlan-shaped JSON for tests: invented rooms, never a real scan."""

import math


def surface(kind, centre, axis_xz, w, h, ident, opts=None, confidence="high", nested=False, parent=None):
    ux, uz = axis_xz
    n = math.hypot(ux, uz)
    ux, uz = ux / n, uz / n
    cols = [[ux, 0, uz, 0], [0, 1, 0, 0], [-uz, 0, ux, 0], [centre[0], centre[1], centre[2], 1]]
    s = {"identifier": ident, "category": {kind: opts or {}}, "confidence": {confidence: {}}, "dimensions": [w, h, 0.0],
         "transform": cols if nested else [v for c in cols for v in c], "curve": None, "completedEdges": []}
    if parent:
        s["parentIdentifier"] = parent
    return s


def room(x0, z0, x1, z1, tag, h=2.5, y0=0.0, doors=(), windows=(), nested=False):
    """Axis-aligned room in ARKit (x, z) metres; the floor at y0. Walls run counter-clockwise."""
    cy = y0 + h / 2
    walls = [
        surface("wall", ((x0 + x1) / 2, cy, z0), (1, 0), x1 - x0, h, f"{tag}-s", nested=nested),
        surface("wall", (x1, cy, (z0 + z1) / 2), (0, 1), z1 - z0, h, f"{tag}-e", nested=nested),
        surface("wall", ((x0 + x1) / 2, cy, z1), (1, 0), x1 - x0, h, f"{tag}-n", nested=nested),
        surface("wall", (x0, cy, (z0 + z1) / 2), (0, 1), z1 - z0, h, f"{tag}-w", nested=nested),
    ]
    return {
        "identifier": tag, "story": 0, "walls": walls,
        "doors": [surface("door", (dx, y0 + 1.0, dz), (ax, az), 0.9, 2.0, f"{tag}-door{i}", {"isOpen": False}, nested=nested)
                  for i, (dx, dz, ax, az) in enumerate(doors)],
        "windows": [surface("window", (wx, y0 + 1.5, wz), (ax, az), 1.2, 1.2, f"{tag}-win{i}", nested=nested)
                    for i, (wx, wz, ax, az) in enumerate(windows)],
        "openings": [], "objects": [{"identifier": "sofa", "category": {"sofa": {}}, "dimensions": [2, 1, 1], "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 0.4, 1, 1]}],
    }


def two_rooms(nested=False):
    """A: x 0..4, B: x 4.12..8.12 (the shared wall is two faces 0.12 m apart), both z 0..3.
    The door in the shared wall is seen from both rooms; one window in A's south wall."""
    a = room(0, 0, 4, 3, "A", doors=[(4.0, 1.5, 0, 1)], windows=[(2.0, 0.0, 1, 0)], nested=nested)
    b = room(4.12, 0, 8.12, 3, "B", doors=[(4.12, 1.5, 0, 1)], nested=nested)
    return {"format": "homemesh-capture-1", "rooms": [a, b]}
