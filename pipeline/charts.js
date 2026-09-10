/* =====================================================================
   Inline SVG charts.

   No charting library. The page's content security policy allows scripts
   only from itself and esm.sh, and every library worth loading would
   need styling back to the brand anyway. These are small, themed with
   the same tokens as everything else, and readable.

   Each function takes data that is already aggregated by a view and
   returns an SVG string. None of them compute a metric.
   ===================================================================== */

const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const path = pts => pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");

/* ---------------------------------------------------------------------
   Committed work against available capacity, with weighted pipeline
   riding over the top as a line.

   This is the one chart that changes a decision: where the line climbs
   above the bars, Harry is about to sell work he has no room to build.
   Over-capacity weeks are the only bars allowed to use the accent.
   --------------------------------------------------------------------- */
export function capacityChart(weeks, { height = 210 } = {}) {
  if (!weeks.length) return emptySvg("No capacity data yet.");

  const W = 900, H = height, padL = 38, padR = 12, padT = 12, padB = 26;
  const iw = W - padL - padR, ih = H - padT - padB;
  const max = Math.max(
    ...weeks.map(w => Math.max(Number(w.available_days || 0), Number(w.committed_days || 0),
      Number(w.weighted_pipeline_days || 0))), 1);

  const bw = iw / weeks.length;
  const y = v => padT + ih - (v / max) * ih;

  const bars = weeks.map((w, i) => {
    const x = padL + i * bw;
    const cd = Number(w.committed_days || 0);
    const av = Number(w.available_days || 0);
    const over = cd > av;
    return `
      <rect class="bar ghost" x="${(x + bw * .13).toFixed(1)}" y="${y(av).toFixed(1)}"
            width="${(bw * .74).toFixed(1)}" height="${Math.max(padT + ih - y(av), 0).toFixed(1)}" rx="2"/>
      <rect class="bar${over ? " over" : ""}" x="${(x + bw * .13).toFixed(1)}" y="${y(cd).toFixed(1)}"
            width="${(bw * .74).toFixed(1)}" height="${Math.max(padT + ih - y(cd), 0).toFixed(1)}" rx="2">
        <title>Week of ${esc(w.week_start)}: ${cd} of ${av} job-days committed${over ? " — over capacity" : ""}</title>
      </rect>`;
  }).join("");

  const line = path(weeks.map((w, i) =>
    [padL + i * bw + bw / 2, y(Number(w.weighted_pipeline_days || 0))]));

  const ticks = [0, max / 2, max].map(v =>
    `<line class="axis" x1="${padL}" x2="${W - padR}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}" opacity=".45"/>
     <text x="${padL - 6}" y="${(y(v) + 3).toFixed(1)}" text-anchor="end">${Math.round(v)}</text>`).join("");

  const every = Math.ceil(weeks.length / 12);
  const labels = weeks.map((w, i) => i % every ? "" :
    `<text x="${(padL + i * bw + bw / 2).toFixed(1)}" y="${H - 8}" text-anchor="middle">${
      new Date(w.week_start).toLocaleDateString("en-GB", { month: "short", day: "numeric" })}</text>`).join("");

  const today = weeks.findIndex(w => new Date(w.week_start) >= new Date());
  const todayMark = today > 0
    ? `<line class="axis" x1="${(padL + today * bw).toFixed(1)}" x2="${(padL + today * bw).toFixed(1)}"
        y1="${padT}" y2="${padT + ih}" stroke-dasharray="3 3"/>` : "";

  return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img"
      aria-label="Committed job-days against available capacity by week, with weighted pipeline over the top">
    ${ticks}${todayMark}${bars}
    <path class="line" d="${line}"/>${labels}
  </svg>`;
}

/* ---------------------------------------------------------------------
   A simple monthly line, used for cycle times.
   --------------------------------------------------------------------- */
export function lineChart(points, { height = 180, label = "" } = {}) {
  const real = points.filter(p => p.value !== null && p.value !== undefined);
  if (real.length < 2) return emptySvg("Not enough months to draw a trend yet.");

  const W = 900, H = height, padL = 34, padR = 12, padT = 12, padB = 24;
  const iw = W - padL - padR, ih = H - padT - padB;
  const max = Math.max(...real.map(p => Number(p.value)), 1);
  const step = iw / Math.max(points.length - 1, 1);
  const y = v => padT + ih - (v / max) * ih;

  /* A month with no data is a gap, not a zero. Drawing it as zero makes
     a quiet month look like a collapse, so the line breaks instead and
     resumes at the next month that has a figure. */
  const drawn = points.map((p, i) => ({ p, i })).filter(o => o.p.value !== null && o.p.value !== undefined);
  const pts = points.map((p, i) => [padL + i * step, y(Number(p.value || 0))]);

  const segments = [];
  let run = [];
  points.forEach((p, i) => {
    if (p.value === null || p.value === undefined) { if (run.length > 1) segments.push(run); run = []; }
    else run.push(pts[i]);
  });
  if (run.length > 1) segments.push(run);

  const ticks = [0, max / 2, max].map(v =>
    `<line class="axis" x1="${padL}" x2="${W - padR}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}" opacity=".45"/>
     <text x="${padL - 6}" y="${(y(v) + 3).toFixed(1)}" text-anchor="end">${Math.round(v)}</text>`).join("");

  const every = Math.ceil(points.length / 8);
  const labels = points.map((p, i) => i % every ? "" :
    `<text x="${(padL + i * step).toFixed(1)}" y="${H - 6}" text-anchor="middle">${esc(p.label)}</text>`).join("");

  const dots = drawn.map(o =>
    `<circle class="dot" cx="${pts[o.i][0].toFixed(1)}" cy="${pts[o.i][1].toFixed(1)}" r="3">
      <title>${esc(o.p.label)}: ${o.p.value} ${esc(label)}</title></circle>`).join("");

  return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)} by month">
    ${ticks}${segments.map(s => `<path class="line" d="${path(s)}"/>`).join("")}${dots}${labels}
  </svg>`;
}

/* ---------------------------------------------------------------------
   Spread of schedule variance in days. A histogram rather than an
   average, because "on average two days late" hides a job that was six
   weeks out.
   --------------------------------------------------------------------- */
export function varianceChart(values, { height = 190 } = {}) {
  const vals = values.filter(v => v !== null && v !== undefined).map(Number);
  if (!vals.length) return emptySvg("No completed jobs with a baseline yet.");

  const buckets = [
    { lo: -Infinity, hi: -6, name: "Early 6+" },
    { lo: -6, hi: -1, name: "Early 1-5" },
    { lo: -1, hi: 2, name: "On time" },
    { lo: 2, hi: 6, name: "Late 2-5" },
    { lo: 6, hi: 15, name: "Late 6-14" },
    { lo: 15, hi: Infinity, name: "Late 15+" }
  ].map(b => ({ ...b, n: vals.filter(v => v >= b.lo && v < b.hi).length }));

  const W = 900, H = height, padL = 30, padR = 12, padT = 12, padB = 34;
  const iw = W - padL - padR, ih = H - padT - padB;
  const max = Math.max(...buckets.map(b => b.n), 1);
  const bw = iw / buckets.length;

  const bars = buckets.map((b, i) => {
    const h = (b.n / max) * ih;
    const x = padL + i * bw;
    const late = b.lo >= 2;
    return `
      <rect class="bar${late ? " over" : ""}" x="${(x + bw * .16).toFixed(1)}" y="${(padT + ih - h).toFixed(1)}"
            width="${(bw * .68).toFixed(1)}" height="${h.toFixed(1)}" rx="2">
        <title>${esc(b.name)}: ${b.n} job${b.n === 1 ? "" : "s"}</title></rect>
      <text x="${(x + bw / 2).toFixed(1)}" y="${(padT + ih - h - 5).toFixed(1)}" text-anchor="middle"
            class="lbl">${b.n || ""}</text>
      <text x="${(x + bw / 2).toFixed(1)}" y="${H - 10}" text-anchor="middle">${esc(b.name)}</text>`;
  }).join("");

  return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img"
      aria-label="How far completed jobs ran from their baseline, in days">
    <line class="axis" x1="${padL}" x2="${W - padR}" y1="${padT + ih}" y2="${padT + ih}"/>${bars}
  </svg>`;
}

function emptySvg(message) {
  return `<svg class="chart" viewBox="0 0 900 120" role="img" aria-label="${esc(message)}">
    <text x="450" y="62" text-anchor="middle">${esc(message)}</text></svg>`;
}

/* ---------------------------------------------------------------------
   HTML bar lists. Cheaper than SVG for a ranked list, and they wrap and
   reflow on a phone without any work.
   --------------------------------------------------------------------- */
export function barList(items, { fmt = v => v, accent = false } = {}) {
  if (!items.length) return `<p class="thin-note">Nothing recorded in this period.</p>`;
  const max = Math.max(...items.map(i => Number(i.value) || 0), 1);
  return `<ul class="bars">${items.map(i => `
    <li>
      <span>${esc(i.label)}</span>
      <span class="track"><span class="fill" style="width:${((Number(i.value) || 0) / max * 100).toFixed(1)}%${
        accent ? "" : ";background:var(--green)"}"></span></span>
      <span class="n">${esc(fmt(i.value))}${i.n !== undefined ? ` <span class="thin-note">n=${i.n}</span>` : ""}</span>
    </li>`).join("")}</ul>`;
}

export function funnelList(stages) {
  const top = Math.max(...stages.map(s => s.value), 1);
  return `<ul class="funnel">${stages.map(s => `
    <li>
      <span class="name">${esc(s.label)}</span>
      <span class="track"><span class="fill" style="width:${(s.value / top * 100).toFixed(1)}%"></span></span>
      <span class="n">${s.value}</span>
      <span class="pc">${top ? (s.value / top * 100).toFixed(0) + "%" : "—"}</span>
    </li>`).join("")}</ul>`;
}
