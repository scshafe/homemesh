import { useState } from "preact/hooks";
import { calibrate, parseMeasurements, type CalibrationOut, type Hint } from "./api";
import { addMeasurements } from "./edit";
import type { House } from "./types";

interface Props {
  house: House; level: string; onCommit: (h: House) => void; band: string;
  onResult: (hints: Hint[], residuals: Record<string, number>) => void; onError: (e: unknown) => void;
}

const f1 = (v: number) => v.toFixed(1);

/** Calibration: readings in (tap or CSV), fit, per-parameter result with its uncertainty, apply. */
export function CalPanel({ house: h, level, onCommit, band, onResult, onError }: Props) {
  const [out, setOut] = useState<CalibrationOut | null>(null);
  const [busy, setBusy] = useState(false);
  const bands = Object.keys(out?.fits ?? {});

  async function fit() {
    setBusy(true);
    try {
      const r = await calibrate(h);
      setOut(r);
      onResult(Object.values(r.suggestions).flat(), Object.assign({}, ...Object.values(r.fits).map((x) => x.residuals)));
    } catch (e) { onError(e); }
    setBusy(false);
  }

  return <div>
    <b>Calibration</b>
    <p><small>1. Place the existing access point (AP tool). 2. Walk the house; tap Reading and click where you stood, or import a CSV (x, y, band, rssi; optional level, device, bssid). 3. Fit.</small></p>
    <div>{h.access_points.length} AP, {h.measurements.length} readings ({h.measurements.filter((m) => m.band === band).length} at {band} GHz; at least 8 per band to fit)</div>
    <p><label>Import CSV <input type="file" accept=".csv,text/csv" onChange={async (e) => {
      const el = e.target as HTMLInputElement, file = el.files?.[0]; el.value = "";
      if (!file) return;
      try { onCommit(addMeasurements(h, await parseMeasurements(h.id, file, level, "imported"))); } catch (err) { onError(err); }
    }} /></label></p>
    <button disabled={busy || !h.access_points.length || !h.measurements.length} onClick={fit}>{busy ? "Fitting…" : "Fit the model"}</button>
    {out && bands.length === 0 && <p style="color:#a60">Not enough usable readings in any band (need 8 matched to an AP).</p>}
    {out && bands.map((b) => {
      const f = out.fits[b];
      return <div style="margin:8px 0;font-size:12px">
        <b>{b} GHz</b>: {f.n_meas} readings; error on the walk {f1(f.rmse_train)} dB{f.rmse_cv !== null ? `, held out by area ${f1(f.rmse_cv)} dB (bias ${f1(f.bias_cv ?? 0)})` : ""}
        {f.note && <div style="color:#a60">{f.note}</div>}
        <table style="border-collapse:collapse"><tbody>
          <tr><td>distance exponent n</td><td>{f1(f.n.mean)} ± {f1(f.n.sd)}</td><td>(prior {f1(f.n.prior_mean)})</td></tr>
          <tr><td>extra loss</td><td>{f1(f.extra_loss.mean)} ± {f1(f.extra_loss.sd)} dB</td><td /></tr>
          {Object.entries(f.materials).map(([m, p]) => <tr style={p.identified ? "" : "color:#999"}>
            <td>{m}</td><td>{f1(p.mean)} ± {f1(p.sd)} dB</td><td>{p.identified ? `(prior ${f1(p.prior_mean)})` : "not identified: prior kept"}</td></tr>)}
        </tbody></table>
        {(out.suggestions[b]?.length ?? 0) > 0 && <div>Measure next (dashed rings on the plan): {out.suggestions[b].map((s) => `${s.material} at ${f1(s.x)}, ${f1(s.y)}`).join("; ")}</div>}
      </div>;
    })}
    {out?.calibrated && <p><button onClick={() => { onCommit(out.calibrated!); setOut(null); onResult([], {}); }}>Apply to the house</button>{" "}
      <small>Updates the identified materials, exponents and the planner margin; undoable, saved with the house.</small></p>}
  </div>;
}
