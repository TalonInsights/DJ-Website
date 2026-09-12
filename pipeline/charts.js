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
/* ---------------------------------------------------------------------
   THE PANEL CHARTS

   These four sit two to a row, so each is drawn on a 560-unit canvas
   rather than the capacity chart's 1000. An SVG scales its text with
   everything else: a 900-unit chart rendered into a 560px column halves
   every label, which is how a chart ends up with axis text at 6px. The
   canvas is sized for the column it actually lands in.
   --------------------------------------------------------------------- */
const PW = 560;

/* ---------------------------------------------------------------------
   Trend over time. One series, so no legend: the panel heading says what
   is plotted. A wash under the line at a tenth opacity gives the eye
   something to follow without adding ink that reads as data, and only
   the last point is labelled, because a number on every point is read as
   texture rather than as values.
   --------------------------------------------------------------------- */
export function lineChart(points, { height = 190, label = "", fmt = v => v } = {}) {
  const real = points.filter(p => p.value !== null && p.value !== undefined);
  if (real.length < 2) return emptySvg("Not enough months to draw a trend yet.");

  const W = PW, H = height, padL = 34, padR = 72, padT = 16, padB = 28;
  const iw = W - padL - padR, ih = H - padT - padB;
  const max = niceMax(Math.max(...real.map(p => Number(p.value)), 1));
  const step = iw / Math.max(points.length - 1, 1);
  const y = v => padT + ih - (v / max) * ih;
  const pts = points.map((p, i) => [padL + i * step, y(Number(p.value || 0))]);

  /* A month with no data is a gap, not a zero. Drawing it as zero makes
     a quiet month look like a collapse, so the line breaks instead. */
  const segments = [];
  let run = [];
  points.forEach((p, i) => {
    if (p.value === null || p.value === undefined) { if (run.length > 1) segments.push(run); run = []; }
    else run.push(pts[i]);
  });
  if (run.length > 1) segments.push(run);

  const washes = segments.map(s =>
    `<path class="wash" d="${path(s)} L${s[s.length - 1][0].toFixed(1)} ${(padT + ih).toFixed(1)} L${s[0][0].toFixed(1)} ${(padT + ih).toFixed(1)} Z"/>`).join("");

  const ticks = [0, max / 2, max].map(v =>
    `<line class="grid" x1="${padL}" x2="${W - padR}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}"/>
     <text class="tick" x="${padL - 7}" y="${(y(v) + 4).toFixed(1)}" text-anchor="end">${Math.round(v)}</text>`).join("");

  const every = Math.ceil(points.length / 6);
  const labels = points.map((p, i) => (i % every && i !== points.length - 1) ? "" :
    `<text class="tick" x="${(padL + i * step).toFixed(1)}" y="${H - 8}" text-anchor="middle">${esc(p.label)}</text>`).join("");

  /* Hit targets are the full column, not the 4px dot. */
  const hits = points.map((p, i) => p.value === null || p.value === undefined ? "" :
    `<g class="pt"><rect class="hit" x="${(padL + i * step - step / 2).toFixed(1)}" y="${padT}"
        width="${step.toFixed(1)}" height="${ih.toFixed(1)}"/>
      <circle class="dot" cx="${pts[i][0].toFixed(1)}" cy="${pts[i][1].toFixed(1)}" r="4"/>
      <title>${esc(p.label)}: ${esc(String(fmt(p.value)))}</title></g>`).join("");

  const last = points.map((p, i) => ({ p, i })).filter(o => o.p.value !== null && o.p.value !== undefined).pop();
  const end = last ? `
    <circle class="dot end" cx="${pts[last.i][0].toFixed(1)}" cy="${pts[last.i][1].toFixed(1)}" r="5"/>
    <text class="val" x="${(pts[last.i][0] + 9).toFixed(1)}" y="${(pts[last.i][1] + 4).toFixed(1)}">${esc(String(fmt(last.p.value)))}</text>` : "";

  return `<svg class="chart line-c" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)} by month">
    ${ticks}${washes}${segments.map(s => `<path class="line" d="${path(s)}"/>`).join("")}${end}${hits}${labels}
  </svg>`;
}

/* ---------------------------------------------------------------------
   The funnel.

   A tapering shape rather than another row of bars, because the reader's
   question is not how many reached each stage but WHERE THEY LEAK, and a
   taper shows that without reading a number. Precision comes from the
   direct labels; the shape carries the story.

   The biggest single drop is called out in brass, because that is the one
   step worth fixing and it is otherwise easy to miss under a stage that
   simply has fewer people in it.
   --------------------------------------------------------------------- */
export function funnelChart(stages, { height = 250 } = {}) {
  const top = Math.max(...stages.map(s => Number(s.value) || 0), 0);
  if (!top) return emptySvg("No enquiries in this period.");

  const W = PW, H = height, padT = 10, padB = 8;
  const nameX = 86, pcX = 134, midX = 146, maxW = 292, dropX = midX + maxW + 12;
  const rowH = (H - padT - padB) / stages.length;
  const barH = Math.min(26, rowH * .6);

  /* Worked out before drawing, so the worst step can be coloured. */
  const drops = stages.map((s, i) => i === 0 ? -1 : (Number(stages[i - 1].value) || 0) - (Number(s.value) || 0));
  const worst = drops.indexOf(Math.max(...drops.filter(v => v > 0)));

  const rows = stages.map((s, i) => {
    const v = Number(s.value) || 0;
    const w = Math.max((v / top) * maxW, v > 0 ? 3 : 0);
    const cy = padT + i * rowH + rowH / 2;
    const x0 = midX + (maxW - w) / 2;          /* centred, so it tapers  */
    const pc = top ? Math.round(v / top * 100) : 0;
    const bad = i === worst;

    const drop = i === 0 || drops[i] <= 0 ? "" : `
      <text class="drop${bad ? " bad" : ""}" x="${dropX}" y="${(cy - rowH / 2 + 4).toFixed(1)}">
        &minus;${drops[i]}${bad ? " lost here" : ""}</text>`;

    return `
      ${i ? `<line class="lead" x1="${midX + maxW / 2}" x2="${midX + maxW / 2}"
             y1="${(cy - rowH / 2 - barH / 2 + 1).toFixed(1)}" y2="${(cy - barH / 2 - 1).toFixed(1)}"/>` : ""}
      ${drop}
      <g class="stage">
        <rect class="hit" x="0" y="${(cy - rowH / 2).toFixed(1)}" width="${W}" height="${rowH.toFixed(1)}"/>
        <text class="name" x="${nameX}" y="${(cy + 5).toFixed(1)}" text-anchor="end">${esc(s.label)}</text>
        <text class="pc" x="${pcX}" y="${(cy + 5).toFixed(1)}" text-anchor="end">${pc}%</text>
        <rect class="seg${bad ? " bad" : ""}" x="${x0.toFixed(1)}" y="${(cy - barH / 2).toFixed(1)}"
              width="${w.toFixed(1)}" height="${barH.toFixed(1)}" rx="4"/>
        <text class="val" x="${(midX + maxW / 2).toFixed(1)}" y="${(cy + 5).toFixed(1)}"
              text-anchor="middle">${v}</text>
        <title>${esc(s.label)}: ${v} of ${top} (${pc}%)</title>
      </g>`;
  }).join("");

  return `<svg class="chart funnel-c" viewBox="0 0 ${W} ${H}" role="img"
      aria-label="Enquiries reaching each stage, and where they drop out">${rows}</svg>`;
}

/* ---------------------------------------------------------------------
   Schedule variance, as a diverging histogram.

   The job here is polarity, not magnitude: the reader wants to know which
   SIDE of the promised date the work lands on. So zero is a real axis down
   the middle, early runs left and late runs right. A plain column chart
   would have made "three days early" and "three days late" look like
   neighbours on one scale rather than opposites.

   Both arms are scaled by the same maximum. Scaling each side to its own
   max would make four early jobs look like thirteen late ones.
   --------------------------------------------------------------------- */
export function varianceChart(values, { height = 236 } = {}) {
  const vals = values.filter(v => v !== null && v !== undefined).map(Number);
  if (!vals.length) return emptySvg("No completed jobs with a baseline yet.");

  const buckets = [
    { lo: -Infinity, hi: -6,       name: "6+ days early", side: -1 },
    { lo: -6,        hi: -1,       name: "1-5 early",     side: -1 },
    { lo: -1,        hi: 2,        name: "On the day",    side: 0 },
    { lo: 2,         hi: 6,        name: "2-5 late",      side: 1 },
    { lo: 6,         hi: 15,       name: "6-14 late",     side: 1 },
    { lo: 15,        hi: Infinity, name: "15+ days late", side: 1 }
  ].map(b => ({ ...b, n: vals.filter(v => v >= b.lo && v < b.hi).length }));

  const W = PW, H = height, padT = 36, padB = 26;
  const nameX = 118, zero = 322, arm = 160;
  const rowH = (H - padT - padB) / buckets.length;
  const barH = Math.min(20, rowH * .62);
  const max = Math.max(...buckets.map(b => b.n), 1);

  const rows = buckets.map((b, i) => {
    const cy = padT + i * rowH + rowH / 2;
    const w = (b.n / max) * arm;
    /* 2px of surface between the mark and the axis, per the spacer rule. */
    const x = b.side < 0 ? zero - 2 - w : zero + 2;
    const cls = b.side < 0 ? "early" : b.side > 0 ? "late" : "ontime";
    const tipX = b.side < 0 ? zero - 2 - w - 6 : zero + 2 + w + 6;
    return `
      <g class="vb">
        <rect class="hit" x="0" y="${(cy - rowH / 2).toFixed(1)}" width="${W}" height="${rowH.toFixed(1)}"/>
        <text class="name" x="${nameX}" y="${(cy + 4).toFixed(1)}" text-anchor="end">${esc(b.name)}</text>
        <rect class="seg ${cls}" x="${x.toFixed(1)}" y="${(cy - barH / 2).toFixed(1)}"
              width="${Math.max(w, b.n ? 3 : 0).toFixed(1)}" height="${barH.toFixed(1)}" rx="4"/>
        ${b.n ? `<text class="val" x="${tipX.toFixed(1)}" y="${(cy + 4).toFixed(1)}"
              text-anchor="${b.side < 0 ? "end" : "start"}">${b.n}</text>` : ""}
        <title>${esc(b.name)}: ${b.n} job${b.n === 1 ? "" : "s"}</title>
      </g>`;
  }).join("");

  const early = buckets.filter(b => b.side < 0).reduce((a, b) => a + b.n, 0);
  const late = buckets.filter(b => b.side > 0).reduce((a, b) => a + b.n, 0);

  return `<svg class="chart var-c" viewBox="0 0 ${W} ${H}" role="img"
      aria-label="How far completed jobs ran from their baseline, early against late">
    <text class="cap early" x="${zero - 10}" y="18" text-anchor="end">&larr; Early &middot; ${early}</text>
    <text class="cap late"  x="${zero + 10}" y="18">Late &middot; ${late} &rarr;</text>
    <line class="zero" x1="${zero}" x2="${zero}" y1="${padT - 8}" y2="${H - padB + 4}"/>
    ${rows}
    <text class="tick" x="${zero}" y="${H - 8}" text-anchor="middle">the date the customer was given</text>
  </svg>`;
}

/* ---------------------------------------------------------------------
   Rates across a few named things, against a benchmark.

   A dot on a track rather than a bar, because a bar invites the eye to
   compare areas when the only thing that matters is where each dot sits
   relative to the dashed line. The line is the overall rate, so "which
   products drag the average down" is answerable without arithmetic.
   --------------------------------------------------------------------- */
export function dotPlot(items, { reference = null, refLabel = "" } = {}) {
  if (!items.length) return `<p class="thin-note">Nothing recorded in this period.</p>`;
  const W = PW, rowH = 40, padT = 30, padB = 14;
  const H = padT + padB + items.length * rowH;
  const padL = 176, padR = 48;
  const iw = W - padL - padR;
  const x = v => padL + (Math.max(0, Math.min(100, v)) / 100) * iw;

  const ref = reference === null || reference === undefined ? "" : `
    <line class="refline" x1="${x(reference).toFixed(1)}" x2="${x(reference).toFixed(1)}" y1="${padT - 14}" y2="${H - padB + 2}"/>
    <text class="reflbl" x="${x(reference).toFixed(1)}" y="${padT - 19}" text-anchor="middle">${esc(refLabel)} ${Math.round(reference)}%</text>`;

  const rows = items.map((it, i) => {
    const cy = padT + i * rowH + rowH / 2;
    const v = Number(it.value) || 0;
    const below = reference !== null && reference !== undefined && v < reference;
    return `
      <g class="dp">
        <rect class="hit" x="0" y="${(cy - rowH / 2).toFixed(1)}" width="${W}" height="${rowH.toFixed(1)}"/>
        <text class="name" x="${padL - 14}" y="${(cy + 1).toFixed(1)}" text-anchor="end">${esc(it.label)}</text>
        ${it.n !== undefined ? `<text class="nn" x="${padL - 14}" y="${(cy + 14).toFixed(1)}" text-anchor="end">${it.n} job${it.n === 1 ? "" : "s"}</text>` : ""}
        <line class="track" x1="${padL}" x2="${(W - padR).toFixed(1)}" y1="${cy.toFixed(1)}" y2="${cy.toFixed(1)}"/>
        <line class="stem${below ? " below" : ""}" x1="${padL}" x2="${x(v).toFixed(1)}" y1="${cy.toFixed(1)}" y2="${cy.toFixed(1)}"/>
        <circle class="dot${below ? " below" : ""}" cx="${x(v).toFixed(1)}" cy="${cy.toFixed(1)}" r="6"/>
        <text class="val" x="${(W - padR + 10).toFixed(1)}" y="${(cy + 4).toFixed(1)}">${Math.round(v)}%</text>
        <title>${esc(it.label)}: ${Math.round(v)}%${it.n !== undefined ? " from " + it.n + " jobs" : ""}</title>
      </g>`;
  }).join("");

  return `<svg class="chart dot-c" viewBox="0 0 ${W} ${H}" role="img"
      aria-label="Rate by category against the overall rate">${ref}${rows}</svg>`;
}

function niceMax(v) {
  const mag = Math.pow(10, Math.floor(Math.log10(v || 1)));
  return Math.ceil(v / mag) * mag;
}

function emptySvg(message) {
  return `<svg class="chart" viewBox="0 0 ${PW} 90" role="img" aria-label="${esc(message)}">
    <text class="tick" x="${PW / 2}" y="50" text-anchor="middle">${esc(message)}</text></svg>`;
}

/* ---------------------------------------------------------------------
   Ranked categories by value. A horizontal bar is the right form here and
   nothing beats it, so this stays a bar list - but built to the same mark
   spec as the SVG charts: a capped thickness, a rounded data-end, and the
   value at the tip rather than in a column of its own.
   --------------------------------------------------------------------- */
export function barList(items, { fmt = v => v, accent = false, unit = "" } = {}) {
  if (!items.length) return `<p class="thin-note">Nothing recorded in this period.</p>`;
  const max = Math.max(...items.map(i => Number(i.value) || 0), 1);
  return `<ul class="bars${accent ? " accent" : ""}">${items.map(i => {
    const pc = (Number(i.value) || 0) / max * 100;
    return `
    <li>
      <span class="lbl">${esc(i.label)}${i.n !== undefined ? `<span class="nn">${i.n}${unit ? " " + esc(unit) : ""}</span>` : ""}</span>
      <span class="track"><span class="fill" style="width:${pc.toFixed(1)}%"></span></span>
      <span class="n">${esc(String(fmt(i.value)))}</span>
    </li>`;
  }).join("")}</ul>`;
}
