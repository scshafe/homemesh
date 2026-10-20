import { useEffect, useRef, useState } from "preact/hooks";
import { getJob, loadCatalogue, rateMap, startPlan, type Equip, type ClientProfile, type NodeSpec, type PlanOutput, type PlanRequest, type PlanResult, type RateGrid } from "./api";
import { diffColor, rateColor } from "./ratecolor";
import type { House } from "./types";

const DEFAULTS: PlanRequest = { k_max: 3, equipment: [], gateway_equipment: "generic-router-ax", client: "phone-2x2-ax", trust_unknown_jacks: false, price_ceiling: null, candidate_step: 1.0, grid: 1.0 };

function Heat(p: { house: House; level: string; grid: RateGrid | undefined; other?: RateGrid; gateway: NodeSpec; nodes: PlanResult["nodes"]; backhaul: PlanResult["backhaul"]; label: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const c = ref.current!, g = c.getContext("2d")!, W = 380, H = 280;
    c.width = W; c.height = H;
    g.fillStyle = "#fbfbfa"; g.fillRect(0, 0, W, H);
    const gr = p.grid;
    if (!gr) { g.fillStyle = "#666"; g.fillText("no cells on this level", 10, 20); return; }
    const sc = Math.min((W - 10) / (gr.nx * gr.step), (H - 10) / (gr.ny * gr.step));
    const X = (x: number) => 5 + (x - gr.x0) * sc, Y = (y: number) => H - 5 - (y - gr.y0) * sc;
    for (let j = 0; j < gr.ny; j++) for (let i = 0; i < gr.nx; i++) {
      const v = gr.rate[j * gr.nx + i];
      const [r, gg, b] = p.other ? diffColor(p.other.rate[j * gr.nx + i], v) : rateColor(v);
      g.fillStyle = `rgb(${r},${gg},${b})`;
      g.fillRect(X(gr.x0 + i * gr.step), Y(gr.y0 + (j + 1) * gr.step), gr.step * sc + 0.5, gr.step * sc + 0.5);
    }
    g.strokeStyle = "#444"; g.lineWidth = 1.5;
    for (const w of p.house.walls) if (w.level === p.level) { g.beginPath(); g.moveTo(X(w.a[0]), Y(w.a[1])); g.lineTo(X(w.b[0]), Y(w.b[1])); g.stroke(); }
    const all = [p.gateway, ...p.nodes];
    for (const b of p.backhaul) if (b.kind === "wireless" && b.parent !== null) {
      const a = all[b.parent], n = all[b.index];
      if (a.level === p.level && n.level === p.level) {
        g.strokeStyle = "#222"; g.setLineDash([5, 4]); g.lineWidth = 2; g.beginPath();
        g.moveTo(X(a.position[0]), Y(a.position[1])); g.lineTo(X(n.position[0]), Y(n.position[1])); g.stroke(); g.setLineDash([]);
      }
    }
    all.forEach((n, i) => {
      if (n.level !== p.level) return;
      const wired = p.backhaul[i]?.kind === "wired";
      g.beginPath(); g.arc(X(n.position[0]), Y(n.position[1]), 7, 0, 7);
      g.fillStyle = i === 0 ? "#1e5bd6" : wired ? "#7a4fc4" : "#111"; g.fill(); g.strokeStyle = "#fff"; g.lineWidth = 2; g.stroke();
      g.fillStyle = "#fff"; g.font = "bold 9px system-ui"; g.textAlign = "center"; g.fillText(i === 0 ? "G" : String(i), X(n.position[0]), Y(n.position[1]) + 3);
    });
    g.textAlign = "left";
  }, [p.grid, p.other, p.level, p.nodes]);
  return <div style="margin:4px"><div style="font-size:12px">{p.label}</div><canvas ref={ref} style="width:380px;height:280px;border:1px solid #ccc" /></div>;
}

export function Mesh({ house, dirty }: { house: House; dirty: boolean }) {
  const [cat, setCat] = useState<{ equipment: Equip[]; clients: ClientProfile[] } | null>(null);
  const [cfg, setCfg] = useState<PlanRequest>(DEFAULTS);
  const [out, setOut] = useState<PlanOutput | null>(null);
  const [busy, setBusy] = useState<string[] | null>(null);
  const [err, setErr] = useState("");
  const [picked, setPicked] = useState<number[]>([]);
  const [focus, setFocus] = useState(0);
  const [level, setLevel] = useState(house.levels[0].id);
  const [diff, setDiff] = useState(false);
  const [maps, setMaps] = useState<Record<number, RateGrid[]>>({});

  useEffect(() => { loadCatalogue().then(setCat).catch((e) => setErr(String(e))); }, []);
  useEffect(() => { setOut(null); setPicked([]); setMaps({}); setLevel(house.levels[0].id); }, [house.id, house.revision]);

  async function run() {
    setErr(""); setOut(null); setPicked([]); setMaps({}); setBusy([]);
    try {
      const { job } = await startPlan(house.id, { ...cfg, equipment: cfg.equipment.length ? cfg.equipment : (cat?.equipment.filter((e) => e.kind !== "router").map((e) => e.id) ?? []) });
      for (;;) {
        await new Promise((r) => setTimeout(r, 700));
        const j = await getJob(job);
        setBusy(j.progress);
        if (j.state === "done") { setOut(j.result); setPicked(j.result && j.result.results.length ? [0, ...(j.result.results.length > 1 ? [1] : [])] : []); setFocus(0); break; }
        if (j.state === "error") { setErr(j.error ?? "failed"); break; }
      }
    } catch (e) { setErr(String(e)); }
    setBusy(null);
  }

  useEffect(() => {
    if (!out) return;
    for (const i of picked) if (!maps[i]) {
      const r = out.results[i];
      rateMap(house.id, r.nodes, { gateway_equipment: cfg.gateway_equipment, client: cfg.client, trust_unknown_jacks: cfg.trust_unknown_jacks, grid: cfg.grid })
        .then((m) => setMaps((x) => ({ ...x, [i]: m.grids }))).catch((e) => setErr(String(e)));
    }
  }, [picked, out]);

  const toggle = (i: number) => setPicked(picked.includes(i) ? picked.filter((x) => x !== i) : picked.length < 4 ? [...picked, i] : picked);
  const sel = out?.results[focus];

  return (
    <div style="padding:12px;overflow:auto;height:100%;box-sizing:border-box">
      {dirty && <p style="color:#a60">You have unsaved edits. The plan uses the saved revision ({house.revision}); save first to include them.</p>}
      <div style="display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start">
        <fieldset><legend>Plan</legend>
          <label>Extra nodes up to <input type="number" min="0" max="8" style="width:50px" value={cfg.k_max} onChange={(e) => setCfg({ ...cfg, k_max: parseInt((e.target as HTMLInputElement).value) || 0 })} /></label><br />
          <label>Gateway <select value={cfg.gateway_equipment} onChange={(e) => setCfg({ ...cfg, gateway_equipment: (e.target as HTMLSelectElement).value })}>
            {cat?.equipment.map((q) => <option value={q.id}>{q.name}</option>)}</select></label><br />
          <label>Client <select value={cfg.client} onChange={(e) => setCfg({ ...cfg, client: (e.target as HTMLSelectElement).value })}>
            {cat?.clients.map((q) => <option value={q.id}>{q.name}</option>)}</select></label><br />
          <label><input type="checkbox" checked={cfg.trust_unknown_jacks} onChange={(e) => setCfg({ ...cfg, trust_unknown_jacks: (e.target as HTMLInputElement).checked })} /> trust jacks marked unknown (the "if it works" plan)</label><br />
          <label>Price ceiling <input type="number" min="0" style="width:80px" value={cfg.price_ceiling ?? ""} onChange={(e) => setCfg({ ...cfg, price_ceiling: parseFloat((e.target as HTMLInputElement).value) || null })} /></label><br />
          <label>Spot spacing (m) <input type="number" min="0.25" max="3" step="0.25" style="width:60px" value={cfg.candidate_step} onChange={(e) => setCfg({ ...cfg, candidate_step: parseFloat((e.target as HTMLInputElement).value) || 1 })} /></label>
        </fieldset>
        <fieldset><legend>Node models (none ticked = all)</legend>
          {cat?.equipment.filter((q) => q.kind !== "router").map((q) => <div><label><input type="checkbox" checked={cfg.equipment.includes(q.id)}
            onChange={(e) => setCfg({ ...cfg, equipment: (e.target as HTMLInputElement).checked ? [...cfg.equipment, q.id] : cfg.equipment.filter((x) => x !== q.id) })} /> {q.name} ({q.price})</label></div>)}
          <small>Catalogue figures are generic and assumed.</small>
        </fieldset>
        <div><button disabled={busy !== null} onClick={run}>{busy ? "Planning…" : "Find arrangements"}</button>
          {busy && <div style="font-size:12px;color:#555;max-width:300px">{busy.slice(-4).map((l) => <div>{l}</div>)}</div>}
          {err && <p style="color:#b00">{err}</p>}</div>
      </div>

      {out && <>
        <h4>Ranking <small style="font-weight:normal">(score = weighted zone utility; tick up to 4 to compare)</small></h4>
        <table style="border-collapse:collapse;font-size:13px">
          <thead><tr>{["", "#", "nodes", "model", "score", "at margin", "worst zone", "cost", "notes"].map((h) => <th style="text-align:left;padding:2px 8px;border-bottom:1px solid #ccc">{h}</th>)}</tr></thead>
          <tbody>{out.results.map((r, i) =>
            <tr style={`background:${focus === i ? "#eef3ff" : "none"}`} onClick={() => setFocus(i)}>
              <td><input type="checkbox" checked={picked.includes(i)} onChange={() => toggle(i)} /></td>
              <td style="padding:2px 8px">{i + 1}</td><td style="padding:2px 8px">{r.k}</td><td style="padding:2px 8px">{r.k ? r.equipment : "gateway only"}</td>
              <td style="padding:2px 8px">{r.score.toFixed(3)}</td><td style="padding:2px 8px">{r.score_margin.toFixed(3)}</td>
              <td style="padding:2px 8px">{r.worst.toFixed(2)}</td><td style="padding:2px 8px">{r.cost.toFixed(0)}</td>
              <td style="padding:2px 8px;color:#555">{[r.pareto && "Pareto", !r.valid && "INVALID", !r.must_ok && "must-zone unmet", !r.stable && "within model error", r.jacks_unverified.length > 0 && `needs jack ${r.jacks_unverified.join(",")}`].filter(Boolean).join("; ")}</td>
            </tr>)}</tbody>
        </table>

        {sel && <div style="margin:10px 0"><b>Why #{focus + 1}</b>
          {sel.problems.length > 0 && <div style="color:#b00">{sel.problems.join("; ")}</div>}
          <ul style="margin:4px 0">{(sel.explanation?.lines ?? ["(no explanation computed for this rank)"]).map((l) => <li>{l}</li>)}</ul>
          <small>{sel.backhaul.slice(1).map((b) => `node ${b.index}: ${b.kind}${b.kind === "wireless" ? ` via ${b.parent === 0 ? "gateway" : "node " + b.parent} on ${b.band} GHz${b.shared ? " (shared radio)" : ""}` : b.jack ? ` jack ${b.jack}` : ""}, ${b.mbps === null ? "unlimited" : b.mbps.toFixed(0)} Mbit/s`).join(" | ")}</small>
        </div>}

        <div>
          Level <select value={level} onChange={(e) => setLevel((e.target as HTMLSelectElement).value)}>{house.levels.map((l) => <option value={l.id}>{l.name}</option>)}</select>{" "}
          <label><input type="checkbox" checked={diff} onChange={(e) => setDiff((e.target as HTMLInputElement).checked)} /> difference from the first ticked (blue = faster)</label>
          <div style="display:flex;flex-wrap:wrap">
            {picked.map((i, n) => {
              const r = out.results[i], g = maps[i]?.find((x) => x.level === level), first = maps[picked[0]]?.find((x) => x.level === level);
              return <Heat house={house} level={level} grid={g} other={diff && n > 0 ? first : undefined} gateway={out.gateway} nodes={r.nodes} backhaul={r.backhaul}
                label={`#${i + 1}: ${r.k ? r.equipment + " x" + r.k : "gateway only"}, score ${r.score.toFixed(3)}, cost ${r.cost.toFixed(0)}`} />;
            })}
          </div>
          <small>G = gateway, black = wireless node (dashed line to its parent), purple = wired node. Median single-client downlink rate, uncalibrated model.</small>
        </div>
      </>}
    </div>
  );
}
