/* =====================================================================
   The analytics dashboard.

   Reads views only. Every number here is a column that arrived already
   computed; this file lays them out and nothing else.

   Two rules it enforces on the way out:
     - a tile without a direction is decoration, so every one carries its
       prior period;
     - a rate on a thin denominator is noise, so anything under ten is
       greyed and says what it was computed from.
   ===================================================================== */

import { $, mountGate } from "./client.js";
import {
  periodRange, getSummary, getFunnel, getCycleTimes, getLostAnalysis,
  getCapacity, getJobPerformance, getPromiseVsDelivery, getSourcePerformance,
  refreshDashboard, money, num, monthLabel, isThin, THIN_N, EXPLAIN
} from "./data.js";
import { capacityChart, lineChart, varianceChart, barList, funnelList } from "./charts.js";

let period = "90d";

/* The summary is a materialised view, so it holds whatever was true when
   it was last built. Rather than leaving that to a button nobody will
   press, the page rebuilds it whenever it finds it stale, and again on a
   timer while it is open and being looked at. The button stays for when
   someone wants it now. */
const STALE_MS = 20 * 60 * 1000;
let autoTimer = null;
let lastDrawn = 0;
let drawing = false;

const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

mountGate(async () => {
  wire();
  await draw();
  startAuto();
});

function startAuto() {
  clearInterval(autoTimer);
  autoTimer = setInterval(() => {
    if (document.visibilityState === "visible") draw({ auto: true });
  }, STALE_MS);

  /* Coming back to a tab left open overnight should not show yesterday. */
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && Date.now() - lastDrawn > STALE_MS) {
      draw({ auto: true });
    }
  });
}

/* Age of the figures, in words, plus what the page does about it. */
function stamp(at, rebuilt) {
  const el = $("stamp");
  if (!el) return;
  if (!at) { el.textContent = "These figures have not been built yet."; return; }
  const mins = Math.round((Date.now() - new Date(at).getTime()) / 60000);
  const when = rebuilt ? "just now"
             : mins < 1 ? "moments ago"
             : mins < 60 ? mins + " minute" + (mins === 1 ? "" : "s") + " ago"
             : new Date(at).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
  el.textContent = "Figures rebuilt " + when +
    ". They rebuild themselves when they go stale, so there is nothing to press.";
}

function wire() {
  document.querySelectorAll("#periodSeg [data-period]").forEach(b =>
    b.addEventListener("click", async () => {
      period = b.dataset.period;
      document.querySelectorAll("#periodSeg [data-period]").forEach(x =>
        x.setAttribute("aria-pressed", String(x === b)));
      await draw();
    }));

  $("btnRefresh").addEventListener("click", async () => {
    const btn = $("btnRefresh");
    btn.disabled = true; btn.textContent = "Rebuilding…";
    try { await refreshDashboard(); await draw(); }
    catch (e) {
      const stampEl = $("stamp");
      if (stampEl) { stampEl.textContent = "Could not rebuild: " + e.message; }
    }
    finally { btn.disabled = false; btn.textContent = "Rebuild now"; }
  });
}

/* Direction, or nothing. A bare number tells you where you are but not
   whether it is going the right way. */
function delta(now, before, { invert = false, suffix = "" } = {}) {
  if (now === null || now === undefined || before === null || before === undefined || Number(before) === 0) {
    return `<span class="delta flat">no prior period</span>`;
  }
  const change = ((Number(now) - Number(before)) / Math.abs(Number(before))) * 100;
  if (!isFinite(change)) return `<span class="delta flat">—</span>`;
  const good = invert ? change < 0 : change > 0;
  const cls = Math.abs(change) < 1 ? "flat" : (good ? "up" : "down");
  const arrow = Math.abs(change) < 1 ? "" : (change > 0 ? "▲ " : "▼ ");
  return `<span class="delta ${cls}">${arrow}${Math.abs(change).toFixed(0)}%${suffix}</span>`;
}

/* A question mark beside a figure, explaining it in plain words. Real
   buttons, so the keyboard reaches them; one open at a time; Escape or a
   click anywhere else closes it. */
let infoSeq = 0;
function info(key) {
  const text = EXPLAIN[key];
  if (!text) return "";
  const id = "info-" + (++infoSeq);
  return `<span class="info">
    <button type="button" class="info-btn" aria-expanded="false" aria-controls="${id}"
            aria-label="What does this mean?">?</button>
    <span class="info-pop" id="${id}" role="tooltip" hidden>${esc(text)}</span>
  </span>`;
}

function closeInfo() {
  document.querySelectorAll(".info-btn[aria-expanded='true']").forEach(b => {
    b.setAttribute("aria-expanded", "false");
    const pop = document.getElementById(b.getAttribute("aria-controls"));
    if (pop) pop.hidden = true;
  });
}

/* Registered once for the life of the page. wireInfo runs on every draw,
   and adding these each time would stack a listener per redraw. */
let infoGlobals = false;
function infoGlobalsOnce() {
  if (infoGlobals) return;
  infoGlobals = true;
  /* Closing on any click except one inside the widget itself, rather
     than relying on stopPropagation reaching document in the right
     order. Order-independent, so a real click cannot open and
     immediately close the same popover. */
  document.addEventListener("click", e => {
    if (e.target.closest && e.target.closest(".info")) return;
    closeInfo();
  });
  document.addEventListener("keydown", e => { if (e.key === "Escape") closeInfo(); });
}

function wireInfo(root) {
  infoGlobalsOnce();
  root.querySelectorAll(".info-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      const pop = document.getElementById(btn.getAttribute("aria-controls"));
      const wasOpen = btn.getAttribute("aria-expanded") === "true";
      closeInfo();
      if (!wasOpen && pop) { btn.setAttribute("aria-expanded", "true"); pop.hidden = false; }
    });
  });
}

function tile({ title, value, sub, deltaHtml, thin, n, action, href, explain }) {
  const inner = `
    <h3>${esc(title)}${explain ? info(explain) : ""}</h3>
    <div class="big">${value}${deltaHtml || ""}</div>
    <div class="sub">${thin
      ? `Only ${n} to go on, so treat this as a hint, not a trend.`
      : (sub || "")}</div>`;
  return `<div class="tile${action ? " action" : ""}${thin ? " thin" : ""}"
    ${thin ? `title="Computed from ${n} records. Rates need at least ${THIN_N} before they mean much."` : ""}>
    ${href ? `<a href="${href}">${inner}</a>` : inner}</div>`;
}

async function draw({ auto = false } = {}) {
  /* A period button pressed twice quickly, or a timer landing on top of
     a manual rebuild, would otherwise run two draws over each other and
     render whichever finished last. */
  if (drawing) return;
  drawing = true;
  try { await drawInner({ auto }); } finally { drawing = false; }
}

async function drawInner({ auto = false } = {}) {
  const range = periodRange(period);
  const dash = $("dash");
  if (!auto) dash.innerHTML = `<p class="thin-note">Loading…</p>`;

  let s, funnel, cycles, lost, capacity, jobs, delivery, sources;
  let rebuilt = false;
  try {
    /* Fetch the summary first so its age can be judged before anything
       is drawn. Rebuilding after rendering would mean showing a stale
       figure and then quietly changing it under the reader. */
    s = await getSummary();
    const stale = !s || !s.generated_at ||
                  Date.now() - new Date(s.generated_at).getTime() > STALE_MS;
    if (stale) {
      try { await refreshDashboard(); s = await getSummary(); rebuilt = true; }
      catch (e) { /* keep the stale figures rather than showing nothing */ }
    }

    [funnel, cycles, lost, capacity, jobs, delivery, sources] = await Promise.all([
      getFunnel(range), getCycleTimes(range), getLostAnalysis(range),
      getCapacity(), getJobPerformance(), getPromiseVsDelivery(range), getSourcePerformance(range)
    ]);
  } catch (e) {
    dash.innerHTML = `<div class="empty-state"><h3>Could not load the dashboard</h3>
      <p>${esc(e.message)}</p>
      <p class="thin-note">If the views are not there yet, run the migrations in supabase/migrations first.</p></div>`;
    return;
  }

  if (!s) {
    dash.innerHTML = `<div class="empty-state"><h3>Nothing to show yet</h3>
      <p>The summary has not been built. Press Refresh, or add your first enquiry.</p>
      <a class="btn" href="/pipeline">Go to enquiries</a></div>`;
    return;
  }

  /* ---- tiles ---- */
  const tiles = [
    tile({
      title: "Enquiries, 90 days", value: num(s.enquiries), explain: "enquiries",
      deltaHtml: delta(s.enquiries, s.enquiries_prev),
      sub: `${num(s.enquiries_prev)} in the 90 before`
    }),
    tile({
      title: "Win rate", value: s.win_rate === null ? "—" : s.win_rate + "%", explain: "win_rate",
      deltaHtml: delta(s.win_rate, s.win_rate_prev),
      thin: isThin(s.win_rate_n), n: s.win_rate_n,
      sub: `from ${num(s.win_rate_n)} decided enquiries`
    }),
    tile({
      title: "Weighted pipeline", value: money(s.weighted_pipeline), explain: "weighted_pipeline",
      sub: `${num(s.open_enquiries)} open, ${money(s.open_pipeline_value)} unweighted`,
      href: "/pipeline"
    }),
    tile({
      title: "Forward capacity", value: s.weeks_at_capacity + " wk", explain: "forward_capacity",
      sub: s.weeks_at_capacity > 0
        ? `full for the next ${s.weeks_at_capacity} week${s.weeks_at_capacity === 1 ? "" : "s"}`
        : "room in every week ahead",
      action: Number(s.weeks_at_capacity) >= 6
    }),
    tile({
      title: "Overdue follow-ups", value: num(s.overdue_actions), explain: "overdue",
      sub: s.overdue_actions > 0 ? "oldest first on the board" : "nothing waiting",
      action: Number(s.overdue_actions) > 0,
      href: "/pipeline"
    }),
    tile({
      title: "Delivered on time", value: s.on_time_rate === null ? "—" : s.on_time_rate + "%", explain: "on_time",
      thin: isThin(s.on_time_rate_n), n: s.on_time_rate_n,
      sub: `from ${num(s.on_time_rate_n)} completed jobs, 12 months`
    })
  ].join("");

  /* ---- capacity, first because it is the only chart that changes a plan ---- */
  /* Four weeks behind for context, six months ahead for planning.
     Forty-plus weeks squeezed every bar into a sliver. */
  const window = capacity.filter(w => {
    const d = new Date(w.week_start), now = new Date();
    return d >= new Date(now.getTime() - 28 * 86400000) && d <= new Date(now.getTime() + 182 * 86400000);
  });
  const usingDefault = window.filter(w => w.using_default_capacity).length;

  /* ---- funnel ---- */
  const tot = funnel.reduce((a, f) => ({
    received: a.received + Number(f.received || 0),
    contacted: a.contacted + Number(f.contacted || 0),
    surveyed: a.surveyed + Number(f.surveyed || 0),
    quoted: a.quoted + Number(f.quoted || 0),
    won: a.won + Number(f.won || 0)
  }), { received: 0, contacted: 0, surveyed: 0, quoted: 0, won: 0 });

  /* ---- lost reasons ---- */
  const lostByReason = Object.values(lost.reduce((m, r) => {
    const k = r.lost_reason;
    m[k] = m[k] || { label: k, value: 0, n: 0 };
    m[k].value += Number(r.lost_value || 0);
    m[k].n += Number(r.lost_count || 0);
    return m;
  }, {})).sort((a, b) => b.value - a.value);

  /* ---- promise vs delivery, by product ---- */
  const byProduct = Object.values(delivery.reduce((m, d) => {
    const k = d.product_type || "Not recorded";
    m[k] = m[k] || { label: k, on: 0, n: 0 };
    m[k].n += 1;
    if (d.on_time) m[k].on += 1;
    return m;
  }, {})).map(p => ({ label: p.label, value: p.n ? Math.round(p.on / p.n * 100) : 0, n: p.n }))
    .sort((a, b) => b.n - a.n);

  /* ---- sources ---- */
  const bySource = Object.values(sources.reduce((m, r) => {
    const k = r.source;
    m[k] = m[k] || { label: k, value: 0, n: 0 };
    m[k].value += Number(r.revenue || 0);
    m[k].n += Number(r.enquiries || 0);
    return m;
  }, {})).sort((a, b) => b.value - a.value);

  dash.innerHTML = `
    <div class="tiles">${tiles}</div>

    <section class="panel">
      <h2>Capacity against pipeline${info("capacity")}</h2>
      <p class="note">The dark line steps across what each week can take. Committed work is the solid bar,
        and what the open pipeline would likely add is stacked on top, each enquiry spread across the window
        it might land in. Anything standing above the line is work with nowhere to go.</p>
      ${capacityChart(window)}
      <div class="legend">
        <span><i class="rule-key"></i>Capacity &mdash; anything above this line has nowhere to go</span>
        <span><i style="background:var(--green)"></i>Committed</span>
        <span><i style="background:var(--brass);opacity:.34"></i>Likely from the pipeline</span>
        <span><i style="background:var(--brass)"></i>Already over capacity</span>
      </div>
      ${usingDefault ? `<p class="thin-note" style="margin-top:.5rem">${usingDefault} of these weeks have no
        capacity set and are assuming 15 job-days. Set the real figures in capacity_weeks.</p>` : ""}
    </section>

    <div class="pair">
      <section class="panel">
        <h2>Funnel${info("funnel")}</h2>
        <p class="note">Enquiries that reached each stage in this period.</p>
        ${funnelList([
          { label: "Received", value: tot.received },
          { label: "Contacted", value: tot.contacted },
          { label: "Surveyed", value: tot.surveyed },
          { label: "Quoted", value: tot.quoted },
          { label: "Won", value: tot.won }
        ])}
      </section>

      <section class="panel">
        <h2>Cycle times${info("cycle")}</h2>
        <p class="note">Median days from enquiry to a decision. Medians, not averages, so one job that sat
          for months does not move the line on its own.</p>
        ${lineChart(cycles.map(c => ({ label: monthLabel(c.period), value: c.median_days_total })),
          { label: "days end to end" })}
      </section>
    </div>

    <div class="pair">
      <section class="panel">
        <h2>Why work is lost${info("lost")}</h2>
        <p class="note">By value, not by count. Losing one large job to price matters more than three
          small ones going quiet.</p>
        ${barList(lostByReason, { fmt: money, accent: true })}
      </section>

      <section class="panel">
        <h2>Schedule variance${info("variance")}</h2>
        <p class="note">How far completed jobs ran from the baseline they were first committed to,
          in days. Not from the current plan, which moves every time a bar is dragged.</p>
        ${varianceChart(jobs.filter(j => j.is_complete).map(j => j.actual_end_variance_days))}
      </section>
    </div>

    <div class="pair">
      <section class="panel">
        <h2>Delivered on time, by product${info("delivery")}</h2>
        <p class="note">Against the date the customer was actually given.</p>
        ${byProduct.length
          ? barList(byProduct.map(p => ({ ...p, value: p.value })), { fmt: v => v + "%" })
          : `<p class="thin-note">No completed jobs with a promised date in this period.</p>`}
        ${byProduct.some(p => isThin(p.n))
          ? `<p class="thin-note" style="margin-top:.6rem">Products with fewer than ${THIN_N} jobs are
             shown with their count because the percentage on its own would mislead.</p>` : ""}
      </section>

      <section class="panel">
        <h2>Where the work comes from${info("sources")}</h2>
        <p class="note">Revenue by source. Only enquiries that became jobs count, so work typed
          straight onto the schedule is not represented here.</p>
        ${barList(bySource, { fmt: money })}
      </section>
    </div>

    <p class="thin-note" id="stamp"></p>`;

  wireInfo(dash);
  stamp(s.generated_at, rebuilt);
  lastDrawn = Date.now();
}
