import { render } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { listHouses, loadHeatmap, loadHouse } from "./api";
import { Viewer } from "./scene";
import type { HeatMap, House } from "./types";
import { fmtLength, loadUnits, saveUnits, type Units } from "./units";

function App() {
  const host = useRef<HTMLDivElement>(null);
  const viewer = useRef<Viewer | null>(null);
  const [ids, setIds] = useState<string[]>([]);
  const [house, setHouse] = useState<House | null>(null);
  const [band, setBand] = useState("5");
  const [tx, setTx] = useState<{ x: number; y: number; level: string } | null>(null);
  const [units, setUnits] = useState<Units>(loadUnits());
  const [error, setError] = useState("");

  useEffect(() => {
    viewer.current = new Viewer(host.current!);
    listHouses().then((l) => { setIds(l); if (l[0]) open(l[0]); }).catch((e) => setError(String(e)));
    return () => viewer.current?.dispose();
  }, []);

  function open(id: string) {
    setTx(null);
    loadHouse(id).then((h) => { setHouse(h); viewer.current?.setHouse(h); }).catch((e) => setError(String(e)));
  }

  useEffect(() => {
    if (viewer.current) viewer.current.onPick = (x, y, level) => setTx({ x, y, level });
  }, []);

  useEffect(() => {
    if (!house || !tx) { viewer.current?.setHeatmap(null, new Map()); return; }
    let live = true;
    const elev = new Map(house.levels.map((l) => [l.id, l.elevation]));
    loadHeatmap(house.id, tx.x, tx.y, tx.level, band)
      .then((hm: HeatMap) => live && viewer.current?.setHeatmap(hm, elev))
      .catch((e) => setError(String(e)));
    return () => { live = false; };
  }, [house, tx, band]);

  return (
    <div style="display:flex;height:100vh;font:14px system-ui">
      <div style="width:260px;padding:12px;overflow:auto;border-right:1px solid #ccc">
        <h3 style="margin:0 0 8px">homemesh</h3>
        <label>House<br />
          <select value={house?.id} onChange={(e) => open((e.target as HTMLSelectElement).value)}>
            {ids.map((i) => <option value={i}>{i}</option>)}
          </select>
        </label>
        <p><label>Band<br />
          <select value={band} onChange={(e) => setBand((e.target as HTMLSelectElement).value)}>
            {["2.4", "5", "6"].map((b) => <option value={b}>{b} GHz</option>)}
          </select></label></p>
        <p><label>Units<br />
          <select value={units} onChange={(e) => { const u = (e.target as HTMLSelectElement).value as Units; saveUnits(u); setUnits(u); }}>
            <option value="metric">metric</option><option value="imperial">imperial</option>
          </select></label></p>
        <p>{tx ? `Node at ${fmtLength(tx.x, units)}, ${fmtLength(tx.y, units)} on ${tx.level}` : "Click a floor to place a node and see its predicted signal."}</p>
        {house?.synthetic && <p style="color:#666">Synthetic demo house.</p>}
        <p style="color:#666;font-size:12px">Median RSSI, single transmitter, uncalibrated model.</p>
        {error && <p style="color:#b00">{error}</p>}
      </div>
      <div ref={host} style="flex:1;min-width:0" />
    </div>
  );
}

render(<App />, document.getElementById("app")!);
