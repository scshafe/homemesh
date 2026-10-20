import { mapWall, remove, type Ref } from "./edit";
import type { House, JackType, Zone } from "./types";

interface Props { house: House; selected: Ref | null; onCommit: (h: House) => void; onSelect: (r: Ref | null) => void }

const num = (v: string, d: number) => { const n = parseFloat(v); return Number.isFinite(n) ? n : d; };
const Row = (p: { label: string; children: preact.ComponentChildren }) => <label style="display:block;margin:6px 0">{p.label}<br />{p.children}</label>;

export function Panel({ house: h, selected: s, onCommit, onSelect }: Props) {
  if (!s) return <p style="color:#666">Select an element to edit it.</p>;
  const del = () => { onCommit(remove(h, s)); onSelect(null); };
  const delBtn = <button onClick={del}>Delete</button>;
  const mats = h.materials;

  if (s.kind === "wall") {
    const w = h.walls.find((x) => x.id === s.id);
    if (!w) return null;
    const set = (patch: Partial<typeof w>) => onCommit(mapWall(h, w.id, (x) => ({ ...x, ...patch })));
    return <div>
      <b>Wall {w.id}</b>
      <Row label="Material"><select value={w.material} onChange={(e) => set({ material: (e.target as HTMLSelectElement).value })}>
        {mats.map((m) => <option value={m.id}>{m.name}</option>)}</select></Row>
      <Row label="Thickness (m)"><input type="number" step="0.01" min="0.01" value={w.thickness} onChange={(e) => set({ thickness: Math.max(0.01, num((e.target as HTMLInputElement).value, w.thickness)) })} /></Row>
      <Row label="Height (m)"><input type="number" step="0.1" min="0.1" value={w.height} onChange={(e) => set({ height: Math.max(0.1, num((e.target as HTMLInputElement).value, w.height)) })} /></Row>
      {w.openings.map((o, i) => <div>{o.kind} {o.width.toFixed(1)} m at {o.offset.toFixed(1)} m{" "}
        <button onClick={() => set({ openings: w.openings.map((q, k) => (k === i ? { ...q, state: q.state === "open" ? "closed" : "open" } : q)) })}>{o.state}</button>{" "}
        <button onClick={() => onCommit(remove(h, { kind: "opening", wall: w.id, index: i }))}>x</button></div>)}
      {delBtn}
    </div>;
  }
  if (s.kind === "jack") {
    const j = h.jacks.find((x) => x.id === s.id);
    if (!j) return null;
    const set = (patch: Partial<typeof j>) => onCommit({ ...h, jacks: h.jacks.map((x) => (x.id === j.id ? { ...x, ...patch } : x)) });
    return <div>
      <b>Jack {j.id}</b>
      <Row label="Type"><select value={j.type} onChange={(e) => set({ type: (e.target as HTMLSelectElement).value as JackType })}>
        {["cat5e", "cat6", "cat6a", "coax_moca"].map((t) => <option>{t}</option>)}</select></Row>
      <Row label="State"><select value={j.state} onChange={(e) => set({ state: (e.target as HTMLSelectElement).value as typeof j.state })}>
        {["live", "dead", "unknown"].map((t) => <option>{t}</option>)}</select></Row>
      <Row label="Leads to"><input value={j.leads_to} onChange={(e) => set({ leads_to: (e.target as HTMLInputElement).value })} /></Row>
      <Row label="Switch"><select value={j.switch ?? ""} onChange={(e) => set({ switch: (e.target as HTMLSelectElement).value || null })}>
        <option value="">none</option>{h.switches.map((x) => <option>{x.id}</option>)}</select></Row>
      <label><input type="checkbox" checked={j.poe} onChange={(e) => set({ poe: (e.target as HTMLInputElement).checked })} /> PoE available</label>
      <p>{delBtn}</p>
    </div>;
  }
  if (s.kind === "zone") {
    const z = h.zones.find((x) => x.id === s.id);
    if (!z) return null;
    const set = (patch: Partial<Zone>) => onCommit({ ...h, zones: h.zones.map((x) => (x.id === z.id ? { ...x, ...patch } : x)) });
    const setKind = (kind: Zone["kind"]) => set({ kind, need: kind === "demand" ? (z.need ?? { must: false, rx_height: 1.0, min_throughput: 50 }) : null });
    const setNeed = (patch: Partial<NonNullable<Zone["need"]>>) => z.need && set({ need: { ...z.need, ...patch } });
    return <div>
      <b>Zone {z.id}</b>
      <Row label="Name"><input value={z.name} onChange={(e) => set({ name: (e.target as HTMLInputElement).value })} /></Row>
      <Row label="Kind"><select value={z.kind} onChange={(e) => setKind((e.target as HTMLSelectElement).value as Zone["kind"])}>
        <option value="allow">allow (a node may go here)</option><option value="forbid">forbid</option><option value="demand">demand (coverage matters)</option></select></Row>
      {z.kind === "allow" && <Row label="Needs"><select value={z.requires} onChange={(e) => set({ requires: (e.target as HTMLSelectElement).value as Zone["requires"] })}>
        <option value="none">nothing</option><option value="outlet">an outlet</option><option value="poe">PoE</option></select></Row>}
      {z.kind === "demand" && z.need && <>
        <Row label="Weight"><input type="number" min="0" step="0.5" value={z.weight} onChange={(e) => set({ weight: Math.max(0, num((e.target as HTMLInputElement).value, z.weight)) })} /></Row>
        <Row label="Min throughput (Mbit/s)"><input type="number" min="1" value={z.need.min_throughput ?? ""} onChange={(e) => setNeed({ min_throughput: num((e.target as HTMLInputElement).value, 0) || null })} /></Row>
        <Row label="Receiver height (m)"><input type="number" min="0" step="0.1" value={z.need.rx_height} onChange={(e) => setNeed({ rx_height: Math.max(0, num((e.target as HTMLInputElement).value, 1)) })} /></Row>
        <label><input type="checkbox" checked={z.need.must} onChange={(e) => setNeed({ must: (e.target as HTMLInputElement).checked })} /> must be met</label>
      </>}
      <p>{delBtn}</p>
    </div>;
  }
  if (s.kind === "entry" && h.entry) {
    const e = h.entry;
    const set = (patch: Partial<typeof e>) => onCommit({ ...h, entry: { ...e, ...patch } });
    return <div><b>Internet entry</b>
      <Row label="Kind"><select value={e.kind} onChange={(ev) => set({ kind: (ev.target as HTMLSelectElement).value })}>{["modem", "ont", "coax_drop"].map((k) => <option>{k}</option>)}</select></Row>
      <Row label="WAN down (Mbit/s)"><input type="number" min="1" value={e.wan_down ?? ""} onChange={(ev) => set({ wan_down: num((ev.target as HTMLInputElement).value, 0) || null })} /></Row>
      <Row label="WAN up (Mbit/s)"><input type="number" min="1" value={e.wan_up ?? ""} onChange={(ev) => set({ wan_up: num((ev.target as HTMLInputElement).value, 0) || null })} /></Row>
      {delBtn}</div>;
  }
  return <div><b>{s.kind} {"id" in s ? s.id : ""}</b><p>{delBtn}</p></div>;
}
