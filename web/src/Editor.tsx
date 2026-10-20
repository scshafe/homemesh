import { useEffect, useRef, useState } from "preact/hooks";
import { addHole, addJack, addOpening, addOutlet, addSwitch, addWall, addZone, hitTest, nearestWall, remove, setEntry, snap, type Ref } from "./edit";
import type { House, JackType, P2, Zone } from "./types";

export type Tool = "select" | "wall" | "door" | "window" | "jack" | "outlet" | "switch" | "entry" | "zone" | "hole" | "delete";
export interface Opts { material: string; thickness: number; jackType: JackType; zoneKind: Zone["kind"] }

interface Props {
  house: House; level: string; tool: Tool; opts: Opts; selected: Ref | null;
  onCommit: (h: House) => void; onSelect: (r: Ref | null) => void;
}

const ZONE_FILL: Record<Zone["kind"], string> = { allow: "rgba(40,160,80,.25)", forbid: "rgba(210,50,50,.25)", demand: "rgba(60,110,220,.22)" };
const JACK_COLOR = { live: "#1a9850", dead: "#d73027", unknown: "#f0a020" };

/** 2D plan editor for one level: pan with right/middle drag or empty-space drag in Select, wheel to zoom. */
export function Editor(p: Props) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const view = useRef({ scale: 40, ox: 40, oy: 400 });
  const [pending, setPending] = useState<P2[]>([]);
  const [cursor, setCursor] = useState<P2 | null>(null);
  const [tick, setTick] = useState(0);
  const drag = useRef<{ x: number; y: number; pan: boolean; moved: boolean } | null>(null);

  const toWorld = (sx: number, sy: number): P2 => [(sx - view.current.ox) / view.current.scale, (view.current.oy - sy) / view.current.scale];

  useEffect(() => { setPending([]); }, [p.tool, p.level]);

  useEffect(() => {
    const c = canvas.current!;
    const ro = new ResizeObserver(() => {
      c.width = c.clientWidth * devicePixelRatio; c.height = c.clientHeight * devicePixelRatio; setTick((t) => t + 1);
    });
    ro.observe(c);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const c = canvas.current!, g = c.getContext("2d")!;
    const { scale, ox, oy } = view.current;
    const X = (x: number) => ox + x * scale, Y = (y: number) => oy - y * scale;
    g.setTransform(devicePixelRatio, 0, 0, devicePixelRatio, 0, 0);
    g.clearRect(0, 0, c.clientWidth, c.clientHeight);
    g.fillStyle = "#fbfbfa"; g.fillRect(0, 0, c.clientWidth, c.clientHeight);
    // metre grid
    g.strokeStyle = "#e6e6e2"; g.lineWidth = 1; g.beginPath();
    const w0 = toWorld(0, c.clientHeight), w1 = toWorld(c.clientWidth, 0);
    for (let x = Math.floor(w0[0]); x <= w1[0]; x++) { g.moveTo(X(x), 0); g.lineTo(X(x), c.clientHeight); }
    for (let y = Math.floor(w0[1]); y <= w1[1]; y++) { g.moveTo(0, Y(y)); g.lineTo(c.clientWidth, Y(y)); }
    g.stroke();
    const poly = (pts: P2[], close: boolean) => { g.beginPath(); pts.forEach((q, i) => (i ? g.lineTo(X(q[0]), Y(q[1])) : g.moveTo(X(q[0]), Y(q[1])))); if (close) g.closePath(); };
    const sel = (r: Ref) => p.selected && JSON.stringify(p.selected) === JSON.stringify(r);
    for (const z of p.house.zones) if (z.level === p.level) {
      poly(z.polygon, true); g.fillStyle = ZONE_FILL[z.kind]; g.fill();
      g.strokeStyle = sel({ kind: "zone", id: z.id }) ? "#000" : "#667"; g.setLineDash([5, 4]); g.lineWidth = 1.5; g.stroke(); g.setLineDash([]);
      if (z.polygon.length === 1) { g.beginPath(); g.arc(X(z.polygon[0][0]), Y(z.polygon[0][1]), 6, 0, 7); g.fill(); }
      if (z.name) { g.fillStyle = "#334"; g.font = "11px system-ui"; g.fillText(z.name, X(z.polygon[0][0]) + 4, Y(z.polygon[0][1]) - 4); }
    }
    for (const h of p.house.slab_holes) if (h.level === p.level) {
      poly(h.polygon, true); g.fillStyle = "rgba(120,120,120,.3)"; g.fill(); g.strokeStyle = sel({ kind: "hole", id: h.id }) ? "#000" : "#888"; g.stroke();
    }
    for (const w of p.house.walls) if (w.level === p.level) {
      const len = Math.hypot(w.b[0] - w.a[0], w.b[1] - w.a[1]) || 1, ux = (w.b[0] - w.a[0]) / len, uy = (w.b[1] - w.a[1]) / len;
      const seg = (u0: number, u1: number, color: string, wd: number) => {
        g.strokeStyle = color; g.lineWidth = wd; g.beginPath();
        g.moveTo(X(w.a[0] + ux * u0), Y(w.a[1] + uy * u0)); g.lineTo(X(w.a[0] + ux * u1), Y(w.a[1] + uy * u1)); g.stroke();
      };
      const wd = Math.max(2, w.thickness * scale);
      seg(0, len, sel({ kind: "wall", id: w.id }) ? "#1e5bd6" : "#5b574f", wd);
      for (const o of w.openings) seg(o.offset, o.offset + o.width, o.kind === "door" ? "#c8873a" : "#6aa6d6", wd + 1);
    }
    for (const j of p.house.jacks) if (j.level === p.level) {
      g.fillStyle = JACK_COLOR[j.state]; g.fillRect(X(j.position[0]) - 5, Y(j.position[1]) - 5, 10, 10);
      g.strokeStyle = sel({ kind: "jack", id: j.id }) ? "#000" : "#fff"; g.lineWidth = 2; g.strokeRect(X(j.position[0]) - 5, Y(j.position[1]) - 5, 10, 10);
    }
    for (const o of p.house.outlets) if (o.level === p.level) {
      g.beginPath(); g.arc(X(o.position[0]), Y(o.position[1]), 4, 0, 7); g.fillStyle = "#555"; g.fill();
      if (sel({ kind: "outlet", id: o.id })) { g.strokeStyle = "#000"; g.lineWidth = 2; g.stroke(); }
    }
    for (const s of p.house.switches) if (s.level === p.level) {
      const x = X(s.position[0]), y = Y(s.position[1]);
      g.beginPath(); g.moveTo(x, y - 7); g.lineTo(x + 7, y); g.lineTo(x, y + 7); g.lineTo(x - 7, y); g.closePath();
      g.fillStyle = "#7a4fc4"; g.fill(); if (sel({ kind: "switch", id: s.id })) { g.strokeStyle = "#000"; g.lineWidth = 2; g.stroke(); }
    }
    const e = p.house.entry;
    if (e && e.level === p.level) {
      const x = X(e.position[0]), y = Y(e.position[1]);
      g.beginPath(); g.moveTo(x, y - 8); g.lineTo(x + 8, y + 7); g.lineTo(x - 8, y + 7); g.closePath(); g.fillStyle = "#1e5bd6"; g.fill();
      if (sel({ kind: "entry" })) { g.strokeStyle = "#000"; g.lineWidth = 2; g.stroke(); }
    }
    if (pending.length || (cursor && p.tool === "wall")) {
      const pts = cursor ? [...pending, cursor] : pending;
      g.strokeStyle = "#1e5bd6"; g.lineWidth = 2; g.setLineDash([4, 3]); poly(pts, p.tool === "zone" || p.tool === "hole"); g.stroke(); g.setLineDash([]);
    }
    if (cursor) { g.beginPath(); g.arc(X(cursor[0]), Y(cursor[1]), 3, 0, 7); g.fillStyle = "#1e5bd6"; g.fill(); }
  }, [p.house, p.level, p.selected, pending, cursor, tick, p.tool]);

  const local = (e: PointerEvent): [number, number] => {
    const r = canvas.current!.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  };

  function finishArea() {
    if (p.tool === "zone") p.onCommit(addZone(p.house, p.level, pending, p.opts.zoneKind));
    else if (p.tool === "hole") p.onCommit(addHole(p.house, p.level, pending));
    setPending([]);
  }

  function click(w: P2) {
    const h = p.house, L = p.level;
    const s = snap(h, L, w);
    switch (p.tool) {
      case "select": p.onSelect(hitTest(h, L, w, 10 / view.current.scale)); break;
      case "delete": { const r = hitTest(h, L, w, 10 / view.current.scale); if (r) { p.onCommit(remove(h, r)); p.onSelect(null); } break; }
      case "wall":
        if (!pending.length) setPending([s]);
        else { p.onCommit(addWall(h, L, pending[0], s, p.opts.material, p.opts.thickness)); setPending([s]); }
        break;
      case "door": case "window": {
        const n = nearestWall(h, L, w, 0.4);
        if (n) p.onCommit(addOpening(h, n.wall.id, n.along, p.tool, p.tool === "door" ? "wood-door" : "glass"));
        break;
      }
      case "jack": p.onCommit(addJack(h, L, s, p.opts.jackType)); break;
      case "outlet": p.onCommit(addOutlet(h, L, s)); break;
      case "switch": p.onCommit(addSwitch(h, L, s)); break;
      case "entry": p.onCommit(setEntry(h, L, s)); break;
      case "zone": case "hole": {
        const last = pending[pending.length - 1];
        if (!last || last[0] !== s[0] || last[1] !== s[1]) setPending([...pending, s]);
        break;
      }
    }
  }

  return (
    <canvas
      ref={canvas} style="width:100%;height:100%;touch-action:none;display:block;cursor:crosshair" tabIndex={0}
      onContextMenu={(e) => e.preventDefault()}
      onKeyDown={(e) => { if (e.key === "Escape") setPending([]); if (e.key === "Enter" && pending.length) finishArea(); }}
      onWheel={(e) => {
        e.preventDefault();
        const [sx, sy] = local(e as unknown as PointerEvent), wp = toWorld(sx, sy);
        const v = view.current, f = e.deltaY < 0 ? 1.15 : 1 / 1.15;
        v.scale = Math.min(300, Math.max(5, v.scale * f)); v.ox = sx - wp[0] * v.scale; v.oy = sy + wp[1] * v.scale; setTick((t) => t + 1);
      }}
      onPointerDown={(e) => {
        (e.currentTarget as HTMLCanvasElement).setPointerCapture(e.pointerId);
        const [sx, sy] = local(e);
        const emptyDrag = p.tool === "select" && !hitTest(p.house, p.level, toWorld(sx, sy), 10 / view.current.scale);
        drag.current = { x: sx, y: sy, pan: e.button !== 0 || emptyDrag, moved: false };
      }}
      onPointerMove={(e) => {
        const [sx, sy] = local(e), d = drag.current;
        setCursor(snap(p.house, p.level, toWorld(sx, sy)));
        if (d && d.pan) {
          if (Math.hypot(sx - d.x, sy - d.y) > 3) d.moved = true;
          view.current.ox += sx - d.x; view.current.oy += sy - d.y; d.x = sx; d.y = sy; setTick((t) => t + 1);
        } else if (d && Math.hypot(sx - d.x, sy - d.y) > 3) d.moved = true;
      }}
      onPointerUp={(e) => {
        const d = drag.current; drag.current = null;
        if (!d || d.moved || e.button !== 0) { if (d && !d.moved && e.button === 2) setPending([]); return; }
        const [sx, sy] = local(e); click(toWorld(sx, sy));
      }}
      onDblClick={() => { if (p.tool === "wall") setPending([]); else if (pending.length) finishArea(); }}
    />
  );
}
