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

const NL = String.fromCharCode(10);

const path = pts => pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");

/* ---------------------------------------------------------------------
   Capacity, and what the pipeline would add to it.

   The one chart that changes a decision, so everything in it earns its
   place:

     a stepped CAPACITY LINE across the top of what each week can take,
     drawn over the bars so it is never hidden by them. Anything standing
     above that line is work with nowhere to go, and it is legible at a
     glance without reading a single number;

     committed work as a solid bar, and the weighted pipeline stacked on
     top in a lighter tint, because the question is committed plus likely
     against available and a separate line would make the reader add up;

     faint month bands behind, so the eye can find November without
     counting weeks, and a shaded region behind everything before today.

   Brass is the alarm and nothing else uses it: a week already over on
   committed work alone, before a single new enquiry lands.
   --------------------------------------------------------------------- */
export function capacityChart(weeks, { height = 290 } = {}) {
  if (!weeks.length) return emptySvg("No capacity data yet.");

  const W = 1000, H = height, padL = 48, padR = 16, padT = 26, padB = 52;
  const iw = W - padL - padR, ih = H - padT - padB;

  const num = (w, k) => Math.max(Number(w[k] || 0), 0);
  const rawMax = Math.max(
    ...weeks.map(w => Math.max(num(w, "available_days"),
                               num(w, "committed_days") + num(w, "weighted_pipeline_days"))), 1);
  const step = rawMax > 60 ? 20 : rawMax > 30 ? 10 : rawMax > 12 ? 5 : 2;
  const max = Math.ceil(rawMax / step) * step;

  const bw = iw / weeks.length;
  const barW = Math.max(Math.min(bw * 0.66, 30), 3);
  const y = v => padT + ih - (v / max) * ih;
  const hOf = v => Math.max((v / max) * ih, 0);

  const today = new Date(); today.setHours(0, 0, 0, 0);
  let todayIdx = weeks.findIndex(w => new Date(w.week_start) >= today);
  if (todayIdx < 0) todayIdx = weeks.length;

  /* ---- month bands, so a month can be found without counting ---- */
  const bands = [];
  let runStart = 0, runMonth = new Date(weeks[0].week_start).getMonth(), band = 0;
  const closeBand = (from, to) => {
    if (band % 2 === 0) bands.push(
      `<rect class="band" x="${(padL + from * bw).toFixed(1)}" y="${padT - 8}"
             width="${((to - from) * bw).toFixed(1)}" height="${ih + 8}"/>`);
    band++;
  };
  weeks.forEach((w, i) => {
    const mo = new Date(w.week_start).getMonth();
    if (mo !== runMonth) { closeBand(runStart, i); runStart = i; runMonth = mo; }
  });
  closeBand(runStart, weeks.length);

  const pastBand = todayIdx > 0
    ? `<rect class="past-band" x="${padL}" y="${padT - 8}"
             width="${(todayIdx * bw).toFixed(1)}" height="${ih + 8}"/>` : "";

  /* ---- gridlines ---- */
  const ticks = [];
  for (let v = 0; v <= max; v += step) {
    ticks.push(`<line class="grid${v === 0 ? " base" : ""}" x1="${padL}" x2="${W - padR}"
      y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}"/>
      <text class="tick" x="${padL - 10}" y="${(y(v) + 4).toFixed(1)}" text-anchor="end">${v}</text>`);
  }

  /* ---- bars ---- */
  const bars = weeks.map((w, i) => {
    const x = padL + i * bw + (bw - barW) / 2;
    const av = num(w, "available_days");
    const cd = num(w, "committed_days");
    const pl = num(w, "weighted_pipeline_days");
    const overNow = cd > av;
    const overLater = !overNow && cd + pl > av;

    /* Built as lines and joined, rather than embedding newline escapes.
       An escape sequence written into this file through a shell heredoc
       loses a level and lands as a real line break inside the string,
       which is a syntax error. NL avoids the question entirely. */
    const lines = [`Week of ${esc(w.week_start)}`,
                   `${cd} of ${av} job-days committed`];
    if (pl > 0) lines.push(`${pl} likely from the pipeline`);
    if (overNow) lines.push("Already over capacity");
    else if (overLater) lines.push("Would go over if the pipeline lands");
    if (w.capacity_note) lines.push(w.capacity_note);
    const title = lines.join(NL);

    return `<g class="wk${i < todayIdx ? " past" : ""}" style="--i:${i}">
      ${pl > 0 ? `<rect class="pipe" x="${x.toFixed(1)}" y="${y(cd + pl).toFixed(1)}"
            width="${barW.toFixed(1)}" height="${hOf(pl).toFixed(1)}" rx="2"/>` : ""}
      <rect class="bar${overNow ? " over" : ""}" x="${x.toFixed(1)}" y="${y(cd).toFixed(1)}"
            width="${barW.toFixed(1)}" height="${hOf(cd).toFixed(1)}" rx="2"/>
      <rect class="hit" x="${(padL + i * bw).toFixed(1)}" y="${padT - 8}"
            width="${bw.toFixed(1)}" height="${ih + 8}"><title>${title}</title></rect>
    </g>`;
  }).join("");

  /* ---- the capacity line, stepped across each week ---- */
  let cap = "";
  weeks.forEach((w, i) => {
    const x0 = padL + i * bw, x1 = x0 + bw, yv = y(num(w, "available_days"));
    cap += (i === 0 ? `M ${x0.toFixed(1)} ${yv.toFixed(1)}`
                    : ` L ${x0.toFixed(1)} ${yv.toFixed(1)}`) + ` L ${x1.toFixed(1)} ${yv.toFixed(1)}`;
  });

  /* ---- month names, once each, on a baseline rule ---- */
  let lastMonth = -1;
  const labels = weeks.map((w, i) => {
    const dt = new Date(w.week_start);
    if (dt.getMonth() === lastMonth) return "";
    lastMonth = dt.getMonth();
    const x = padL + i * bw + 2;
    if (x > W - padR - 30) return "";
    return `<text class="month" x="${x.toFixed(1)}" y="${H - 26}">${
      dt.toLocaleDateString("en-GB", { month: "short" })}${
      dt.getMonth() === 0 ? " " + dt.getFullYear() : ""}</text>`;
  }).join("");

  const todayX = padL + todayIdx * bw;
  const todayMark = (todayIdx > 0 && todayIdx < weeks.length)
    ? `<line class="today" x1="${todayX.toFixed(1)}" x2="${todayX.toFixed(1)}"
         y1="${padT - 14}" y2="${padT + ih}"/>
       <text class="today-l" x="${(todayX + 6).toFixed(1)}" y="${padT - 15}">today</text>` : "";

  return `<svg class="chart cap" viewBox="0 0 ${W} ${H}" role="img" preserveAspectRatio="xMidYMid meet"
      aria-label="Committed job-days and likely pipeline against a stepped capacity line, by week">
    ${bands.join("")}${pastBand}
    ${ticks.join("")}
    ${bars}
    <path class="capline" d="${cap}"/>
    ${todayMark}
    <line class="axis" x1="${padL}" x2="${W - padR}" y1="${(padT + ih).toFixed(1)}" y2="${(padT + ih).toFixed(1)}"/>
    ${labels}
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
