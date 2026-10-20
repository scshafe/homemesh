import { render } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { ApiError, createHouse, listHouses, loadHeatmap, loadHouse, saveHouse } from "./api";
import { Editor, type Opts, type Tool } from "./Editor";
import { History, addLevel, type Ref } from "./edit";
import { Panel } from "./Panel";
import { Viewer } from "./scene";
import type { HeatMap, House } from "./types";
import { fmtLength, loadUnits, saveUnits, type Units } from "./units";

const TOOLS: [Tool, string][] = [
  ["select", "Select"], ["wall", "Wall"], ["door", "Door"], ["window", "Window"], ["jack", "Jack"], ["outlet", "Outlet"],
  ["switch", "Switch"], ["entry", "Entry"], ["zone", "Zone"], ["hole", "Slab hole"], ["delete", "Delete"],
];

function App() {
  const host = useRef<HTMLDivElement>(null);
  const viewer = useRef<Viewer | null>(null);
  const hist = useRef<History | null>(null);
  const [, redraw] = useState(0);
  const [ids, setIds] = useState<string[]>([]);
  const [saved, setSaved] = useState<House | null>(null); // what the server has
  const [mode, setMode] = useState<"3d" | "plan">("3d");
  const [level, setLevel] = useState("L0");
  const [tool, setTool] = useState<Tool>("select");
  const [sel, setSel] = useState<Ref | null>(null);
  const [opts, setOpts] = useState<Opts>({ material: "drywall", thickness: 0.1, jackType: "cat6", zoneKind: "allow" });
  const [band, setBand] = useState("5");
  const [tx, setTx] = useState<{ x: number; y: number; level: string } | null>(null);
  const [units, setUnits] = useState<Units>(loadUnits());
  const [error, setError] = useState("");

  const house = hist.current?.present ?? null;
  const dirty = !!house && house !== saved;
  const fail = (e: unknown) => setError(e instanceof ApiError && e.status === 409 ? "Someone saved a newer revision. Reload to continue from it." : String(e));

  function commit(h: House) { hist.current!.push(h); redraw((n) => n + 1); }
  function undo() { if (hist.current?.undo()) { setSel(null); redraw((n) => n + 1); } }
  function redo() { if (hist.current?.redo()) { setSel(null); redraw((n) => n + 1); } }

  function open(id: string) {
    setTx(null); setSel(null); setError("");
    loadHouse(id).then((h) => { hist.current = new History(h); setSaved(h); setLevel(h.levels[0].id); redraw((n) => n + 1); }).catch(fail);
  }

  useEffect(() => {
    viewer.current = new Viewer(host.current!);
    viewer.current.onPick = (x, y, lv) => setTx({ x, y, level: lv });
    listHouses().then((l) => { setIds(l); if (l[0]) open(l[0]); }).catch(fail);
    return () => viewer.current?.dispose();
  }, []);

  useEffect(() => { if (house) viewer.current?.setHouse(house); }, [house]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement).tagName === "INPUT" || (e.target as HTMLElement).tagName === "SELECT") return;
      if ((e.ctrlKey || e.metaKey) && e.key === "z") { e.preventDefault(); e.shiftKey ? redo() : undo(); }
      if ((e.ctrlKey || e.metaKey) && e.key === "y") { e.preventDefault(); redo(); }
      if (e.key === "Delete" || e.key === "Backspace") { /* handled by the panel's Delete to avoid accidents */ }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    if (!saved || !tx || dirty) { if (!tx) viewer.current?.setHeatmap(null, new Map()); return; }
    let live = true;
    const elev = new Map(saved.levels.map((l) => [l.id, l.elevation]));
    loadHeatmap(saved.id, tx.x, tx.y, tx.level, band)
      .then((hm: HeatMap) => live && viewer.current?.setHeatmap(hm, elev))
      .catch(fail);
    return () => { live = false; };
  }, [saved, tx, band, dirty]);

  async function save() {
    if (!house) return;
    try { const s = await saveHouse(house); hist.current = new History(s); setSaved(s); setError(""); redraw((n) => n + 1); } catch (e) { fail(e); }
  }

  async function newHouse() {
    const name = prompt("Name of the new house");
    if (!name) return;
    const id = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
    try { await createHouse(id, name); setIds(await listHouses()); open(id); } catch (e) { fail(e); }
  }

  const btn = (on: boolean) => `margin:2px;${on ? "font-weight:bold;background:#cfe0ff" : ""}`;
  return (
    <div style="display:flex;height:100vh;font:14px system-ui">
      <div style="width:290px;padding:12px;overflow:auto;border-right:1px solid #ccc">
        <h3 style="margin:0 0 8px">homemesh</h3>
        <label>House<br />
          <select value={house?.id} onChange={(e) => (!dirty || confirm("Discard unsaved changes?")) && open((e.target as HTMLSelectElement).value)}>
            {ids.map((i) => <option value={i}>{i}</option>)}
          </select></label>{" "}
        <button onClick={newHouse}>New</button>
        {house && <>
          <p>
            <button style={btn(mode === "3d")} onClick={() => setMode("3d")}>3D</button>
            <button style={btn(mode === "plan")} onClick={() => setMode("plan")}>Plan editor</button>
          </p>
          <p>
            <button disabled={!dirty} onClick={save}>{dirty ? "Save" : "Saved"} (rev {saved?.revision})</button>{" "}
            <button disabled={!hist.current?.canUndo} onClick={undo}>Undo</button>
            <button disabled={!hist.current?.canRedo} onClick={redo}>Redo</button>
          </p>
          <label>Level<br />
            <select value={level} onChange={(e) => setLevel((e.target as HTMLSelectElement).value)}>
              {house.levels.map((l) => <option value={l.id}>{l.name}</option>)}</select></label>{" "}
          <button onClick={() => { const n = prompt("Name of the new level"); if (n) { const h = addLevel(house, n); commit(h); setLevel(h.levels[h.levels.length - 1].id); } }}>Add level</button>
        </>}
        {mode === "plan" && house && <>
          <p>{TOOLS.map(([t, label]) => <button style={btn(tool === t)} onClick={() => { setTool(t); setSel(null); }}>{label}</button>)}</p>
          {tool === "wall" && <p>
            <select value={opts.material} onChange={(e) => setOpts({ ...opts, material: (e.target as HTMLSelectElement).value })}>
              {house.materials.map((m) => <option value={m.id}>{m.name}</option>)}</select>{" "}
            <input type="number" step="0.01" min="0.01" style="width:60px" value={opts.thickness}
              onChange={(e) => setOpts({ ...opts, thickness: Math.max(0.01, parseFloat((e.target as HTMLInputElement).value) || 0.1) })} /> m
            <br /><small>Click to start, click to add; double-click or Esc ends.</small></p>}
          {tool === "jack" && <p><select value={opts.jackType} onChange={(e) => setOpts({ ...opts, jackType: (e.target as HTMLSelectElement).value as Opts["jackType"] })}>
            {["cat5e", "cat6", "cat6a", "coax_moca"].map((t) => <option>{t}</option>)}</select></p>}
          {tool === "zone" && <p><select value={opts.zoneKind} onChange={(e) => setOpts({ ...opts, zoneKind: (e.target as HTMLSelectElement).value as Opts["zoneKind"] })}>
            <option value="allow">allow</option><option value="forbid">forbid</option><option value="demand">demand</option></select>
            <br /><small>Click corners; Enter or double-click finishes (one point = one spot).</small></p>}
          {tool === "hole" && <p><small>Click corners of a stairwell/atrium; Enter or double-click finishes.</small></p>}
          <hr /><Panel house={house} selected={sel} onCommit={commit} onSelect={setSel} />
        </>}
        {mode === "3d" && <>
          <p><label>Band<br /><select value={band} onChange={(e) => setBand((e.target as HTMLSelectElement).value)}>
            {["2.4", "5", "6"].map((b) => <option value={b}>{b} GHz</option>)}</select></label></p>
          <p>{tx ? `Node at ${fmtLength(tx.x, units)}, ${fmtLength(tx.y, units)} on ${tx.level}` : "Click a floor to place a node and see its predicted signal."}</p>
          {dirty && tx && <p style="color:#a60">Save to refresh the signal map with your edits.</p>}
        </>}
        <p><label>Units <select value={units} onChange={(e) => { const u = (e.target as HTMLSelectElement).value as Units; saveUnits(u); setUnits(u); }}>
          <option value="metric">metric</option><option value="imperial">imperial</option></select></label></p>
        {house?.synthetic && <p style="color:#666">Synthetic demo house.</p>}
        <p style="color:#666;font-size:12px">Median RSSI, single transmitter, uncalibrated model.</p>
        {error && <p style="color:#b00">{error}</p>}
      </div>
      <div style="flex:1;min-width:0;position:relative">
        <div ref={host} style={`position:absolute;inset:0;${mode === "3d" ? "" : "visibility:hidden"}`} />
        {mode === "plan" && house && <div style="position:absolute;inset:0">
          <Editor house={house} level={level} tool={tool} opts={opts} selected={sel} onCommit={commit} onSelect={setSel} />
        </div>}
      </div>
    </div>
  );
}

render(<App />, document.getElementById("app")!);
