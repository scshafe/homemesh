// Display units are a per-user setting (owner decision D3); the default follows
// the browser locale. Data stays in metres.
export type Units = "metric" | "imperial";

export function defaultUnits(): Units {
  let region = "";
  try {
    region = (new Intl.Locale(navigator.language).maximize().region ?? "").toUpperCase();
  } catch {
    // an empty or malformed locale: fall back to metric
  }
  return ["US", "LR", "MM"].includes(region) ? "imperial" : "metric";
}

export function loadUnits(): Units {
  const v = localStorage.getItem("units");
  return v === "metric" || v === "imperial" ? v : defaultUnits();
}

export function saveUnits(u: Units): void {
  localStorage.setItem("units", u);
}

export function fmtLength(m: number, u: Units): string {
  if (u === "metric") return `${m.toFixed(1)} m`;
  const inches = Math.round(m / 0.0254);
  return `${Math.floor(inches / 12)}' ${inches % 12}"`;
}
