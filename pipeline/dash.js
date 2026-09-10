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
  refreshDashboard, money, num, monthLabel, isThin, THIN_N
} from "./data.js";
import { capacityChart, lineChart, varianceChart, barList, funnelList } from "./charts.js";

let period = "90d";

const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

mountGate(async () => {
  wire();
  await draw();
});

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
    btn.disabled = true; btn.textContent = "Refreshing…";
    try { await refreshDashboard(); await draw(); }
    catch (e) { alert(e.message); }
    finally { btn.disabled = false; btn.textContent = "Refresh"; }
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

function tile({ title, value, sub, deltaHtml, thin, n, action, href }) {
  const inner = `
    <h3>${esc(title)}</h3>
    <div class="big">${value}${deltaHtml || ""}</div>
    <div class="sub">${thin
      ? `Only ${n} to go on, so treat this as a hint, not a trend.`
      : (sub || "")}</div>`;
  return `<div class="tile${action ? " action" : ""}${thin ? " thin" : ""}"
    ${thin ? `title="Computed from ${n} records. Rates need at least ${THIN_N} before they mean much."` : ""}>
    ${href ? `<a href="${href}">${inner}</a>` : inner}</div>`;
}

async function draw() {
  const range = periodRange(period);
  const dash = $("dash");
  dash.innerHTML = `<p class="thin-note">Loading…</p>`;

  let s, funnel, cycles, lost, capacity, jobs, delivery, sources;
  try {
    [s, funnel, cycles, lost, capacity, jobs, delivery, sources] = await Promise.all([
      getSummary(), getFunnel(range), getCycleTimes(range), getLostAnalysis(range),
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
      title: "Enquiries, 90 days", value: num(s.enquiries),
      deltaHtml: delta(s.enquiries, s.enquiries_prev),
      sub: `${num(s.enquiries_prev)} in the 90 before`
    }),
    tile({
      title: "Win rate", value: s.win_rate === null ? "—" : s.win_rate + "%",
      deltaHtml: delta(s.win_rate, s.win_rate_prev),
      thin: isThin(s.win_rate_n), n: s.win_rate_n,
      sub: `from ${num(s.win_rate_n)} decided enquiries`
    }),
    tile({
      title: "Weighted pipeline", value: money(s.weighted_pipeline),
      sub: `${num(s.open_enquiries)} open, ${money(s.open_pipeline_value)} unweighted`,
      href: "/pipeline"
    }),
    tile({
      title: "Forward capacity", value: s.weeks_at_capacity + " wk",
      sub: s.weeks_at_capacity > 0
        ? `full for the next ${s.weeks_at_capacity} week${s.weeks_at_capacity === 1 ? "" : "s"}`
        : "room in every week ahead",
      action: Number(s.weeks_at_capacity) >= 6
    }),
    tile({
      title: "Overdue follow-ups", value: num(s.overdue_actions),
      sub: s.overdue_actions > 0 ? "oldest first on the board" : "nothing waiting",
      action: Number(s.overdue_actions) > 0,
      href: "/pipeline"
    }),
    tile({
      title: "Delivered on time", value: s.on_time_rate === null ? "—" : s.on_time_rate + "%",
      thin: isThin(s.on_time_rate_n), n: s.on_time_rate_n,
      sub: `from ${num(s.on_time_rate_n)} completed jobs, 12 months`
    })
  ].join("");

  /* ---- capacity, first because it is the only chart that changes a plan ---- */
  const window = capacity.filter(w => {
    const d = new Date(w.week_start), now = new Date();
    return d >= new Date(now.getTime() - 84 * 86400000) && d <= new Date(now.getTime() + 250 * 86400000);
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
      <h2>Capacity against pipeline</h2>
      <p class="note">Bars are job-days already committed to the schedule; the pale bar behind is what the
        week can take. The line is open pipeline weighted by probability. Where the line runs above the
        bars, the work being sold has nowhere to go.</p>
      ${capacityChart(window)}
      <div class="legend">
        <span><i style="background:var(--green)"></i>Committed</span>
        <span><i style="background:var(--rule-dk)"></i>Available</span>
        <span><i style="background:var(--brass)"></i>Over capacity, and weighted pipeline</span>
      </div>
      ${usingDefault ? `<p class="thin-note" style="margin-top:.5rem">${usingDefault} of these weeks have no
        capacity set and are assuming 15 job-days. Set the real figures in capacity_weeks.</p>` : ""}
    </section>

    <div class="pair">
      <section class="panel">
        <h2>Funnel</h2>
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
        <h2>Cycle times</h2>
        <p class="note">Median days from enquiry to a decision. Medians, not averages, so one job that sat
          for months does not move the line on its own.</p>
        ${lineChart(cycles.map(c => ({ label: monthLabel(c.period), value: c.median_days_total })),
          { label: "days end to end" })}
      </section>
    </div>

    <div class="pair">
      <section class="panel">
        <h2>Why work is lost</h2>
        <p class="note">By value, not by count. Losing one large job to price matters more than three
          small ones going quiet.</p>
        ${barList(lostByReason, { fmt: money, accent: true })}
      </section>

      <section class="panel">
        <h2>Schedule variance</h2>
        <p class="note">How far completed jobs ran from the baseline they were first committed to,
          in days. Not from the current plan, which moves every time a bar is dragged.</p>
        ${varianceChart(jobs.filter(j => j.is_complete).map(j => j.actual_end_variance_days))}
      </section>
    </div>

    <div class="pair">
      <section class="panel">
        <h2>Delivered on time, by product</h2>
        <p class="note">Against the date the customer was actually given.</p>
        ${byProduct.length
          ? barList(byProduct.map(p => ({ ...p, value: p.value })), { fmt: v => v + "%" })
          : `<p class="thin-note">No completed jobs with a promised date in this period.</p>`}
        ${byProduct.some(p => isThin(p.n))
          ? `<p class="thin-note" style="margin-top:.6rem">Products with fewer than ${THIN_N} jobs are
             shown with their count because the percentage on its own would mislead.</p>` : ""}
      </section>

      <section class="panel">
        <h2>Where the work comes from</h2>
        <p class="note">Revenue by source. Only enquiries that became jobs count, so work typed
          straight onto the schedule is not represented here.</p>
        ${barList(bySource, { fmt: money })}
      </section>
    </div>

    <p class="thin-note">Summary generated ${s.generated_at ? new Date(s.generated_at).toLocaleString("en-GB") : "—"}.
      Press Refresh to rebuild it.</p>`;
}
