import { useEffect, useState } from "preact/hooks";
import { importCapture, listCaptures, type CaptureMeta, type ImportReport } from "./api";
import type { House, P2 } from "./types";

interface Props {
  house: House; level: string; saved: boolean; onCommit: (h: House) => void; onError: (e: unknown) => void;
  picks: P2[]; onPicksChange: (p: P2[]) => void; regActive: boolean; onRegTool: (on: boolean) => void;
}

/** Import a RoomPlan scan the capture app uploaded, then align it to the plan with picked point pairs. */
export function ScanPanel({ house: h, level, saved, onCommit, onError, picks, onPicksChange, regActive, onRegTool }: Props) {
  const [caps, setCaps] = useState<CaptureMeta[]>([]);
  const [active, setActive] = useState<string | null>(null);
  const [report, setReport] = useState<ImportReport | null>(null);
  const [msg, setMsg] = useState("");

  const refresh = () => listCaptures(h.id).then(setCaps).catch(onError);
  useEffect(() => { refresh(); }, [h.id]);

  async function run(blob: string, registration?: { src: number[][]; dst: number[][] }) {
    try {
      const r = await importCapture(h, blob, level, registration);
      onCommit(r.house); setReport(r.report); setActive(blob);
      setMsg(r.registration ? `Aligned: turned ${r.registration.rotation.toFixed(1)}°, worst pick error ${(r.registration.max_error_m * 100).toFixed(0)} cm.`
        : "Imported in the scan's own frame. Align it with two or three point pairs if it should sit elsewhere.");
      onPicksChange([]); onRegTool(false);
    } catch (e) { onError(e); }
  }

  const pairs = Math.floor(picks.length / 2);
  return <div>
    <b>Scans</b>
    {caps.length === 0 && <p><small>No scans yet. Upload from the capture app; they appear here.</small></p>}
    {caps.map((c) => <div style="margin:4px 0;font-size:12px">
      {c.name || c.blob.slice(0, 8)} · {c.counts.rooms} room(s), {c.counts.walls} walls, {c.counts.doors} doors
      <button style="margin-left:4px" disabled={!saved && false} onClick={() => run(c.blob)}>Import to this level</button>
    </div>)}
    <button onClick={refresh}>Refresh</button>
    {report && <p style="font-size:12px;color:#345">{report.walls} walls ({report.paired_walls} measured thickness from two faces), {report.openings} openings
      {report.skipped_openings ? `, ${report.skipped_openings} duplicate or unplaceable skipped` : ""}{report.replaced ? `; replaced ${report.replaced} earlier walls from this scan` : ""}. {report.notes.join(" ")}</p>}
    {active && <div style="font-size:12px">
      <button style={regActive ? "font-weight:bold;background:#cfe0ff" : ""} onClick={() => { onRegTool(!regActive); onPicksChange([]); }}>Align scan</button>
      {regActive && <div>Click a point on the scan (a), then where it belongs (b). {pairs} pair(s){picks.length % 2 ? ", now click its target" : ""}.
        <br /><button disabled={pairs < 2 || picks.length % 2 === 1} onClick={() => run(active, { src: picks.filter((_, i) => i % 2 === 0), dst: picks.filter((_, i) => i % 2 === 1) })}>Apply ({pairs} pairs)</button>{" "}
        <button onClick={() => onPicksChange([])}>Clear picks</button></div>}
    </div>}
    {msg && <p style="font-size:12px;color:#345">{msg}</p>}
  </div>;
}
