/* =====================================================================
   The enquiry board.

   Columns follow the status order. Dragging a card calls the database,
   and if the transition is refused the card snaps back and the drawer
   opens focused on the field that was missing — an error message alone
   makes the person hunt for it.

   No metric is computed here. Column totals come from the rows the views
   already returned.
   ===================================================================== */

import { sb, $, mountGate } from "./client.js";
import {
  STATUSES, STATUS_NAME, SOURCES, PRODUCT_TYPES, FIELD_LABEL,
  missingFor, getPipelineOpen, getEnquiries, getEnquiry, getEvents,
  getSurveyDiary, getOverdue, createEnquiry, updateEnquiry, transitionStatus,
  convertToJob, money, shortDate, longDate, toCsv, downloadCsv
} from "./data.js";

let rows = [];          /* every enquiry, as the flat view returns it */
let view = "board";
let term = "";
let current = null;     /* the enquiry open in the drawer */
let dirty = {};

const esc = s => String(s ?? "").replace(/[&<>"']/g, c =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/* ---------------------------------------------------------------- boot */

mountGate(async () => {
  try {
    await load();
    wire();
  } catch (e) {
    document.querySelector("main").innerHTML =
      '<div class="empty-state"><h3>Could not load the pipeline</h3><p>' + esc(e.message) +
      '</p><p class="thin-note">If the tables are not there yet, run the migrations in supabase/migrations first.</p></div>';
  }
});

async function load() {
  const [all, surveys, overdue] = await Promise.all([
    getEnquiries({}), getSurveyDiary(), getOverdue()
  ]);
  rows = all;
  renderStrips(surveys, overdue);
  render();
}

/* ------------------------------------------------------------- strips */

function renderStrips(surveys, overdue) {
  const soon = surveys.filter(s => s.days_away >= 0 && s.days_away <= 7);
  $("nSurveys").textContent = soon.length;
  $("listSurveys").innerHTML = soon.length ? soon.map(s => `
    <li data-id="${s.id}">
      <span class="when">${s.is_today ? "Today" : shortDate(s.survey_date)}${s.survey_slot ? " " + s.survey_slot : ""}</span>
      <span class="who">${esc(s.customer_name)}</span>
      <span class="where">${esc(s.site_town || "")}</span>
      ${s.surveyor ? `<span class="tag">${esc(s.surveyor)}</span>` : ""}
    </li>`).join("")
    : `<li class="empty">No surveys booked in the next week. Book one from any surveyed enquiry.</li>`;

  $("nOverdue").textContent = overdue.length;
  $("stripOverdue").classList.toggle("urgent", overdue.length > 0);
  $("listOverdue").innerHTML = overdue.length ? overdue.map(o => `
    <li data-id="${o.id}">
      <span class="when">${o.days_overdue} day${o.days_overdue === 1 ? "" : "s"}</span>
      <span class="who">${esc(o.customer_name)}</span>
      <span class="where">${esc(o.next_action || "")}</span>
      ${o.quote_value ? `<span class="tag">${money(o.quote_value)}</span>` : ""}
    </li>`).join("")
    : `<li class="empty">Nothing overdue. Every live enquiry has a date against it.</li>`;

  document.querySelectorAll(".strip li[data-id]").forEach(li =>
    li.addEventListener("click", () => openDrawer(li.dataset.id)));
}

/* -------------------------------------------------------------- board */

function visible() {
  if (!term) return rows;
  const t = term.toLowerCase();
  return rows.filter(r =>
    (r.customer_name || "").toLowerCase().includes(t) ||
    (r.site_town || "").toLowerCase().includes(t) ||
    (r.ref || "").toLowerCase().includes(t));
}

function render() {
  const list = visible();
  $("countLabel").textContent = list.length + " of " + rows.length + " enquiries";
  $("boardView").hidden = view !== "board";
  $("tableView").hidden = view !== "table";
  if (view === "board") renderBoard(list); else renderTable(list);
}

function renderBoard(list) {
  $("board").innerHTML = STATUSES.map(s => {
    const inCol = list.filter(r => r.status === s.key);
    const value = inCol.reduce((a, r) => a + Number(r.quote_value || 0), 0);
    return `
      <div class="col${s.key === "won" || s.key === "lost" ? " closed" : ""}" data-status="${s.key}">
        <h3>${esc(s.name)} <b>${inCol.length}</b>
          ${value ? `<span class="val">${money(value)}</span>` : ""}</h3>
        <div class="drop" data-status="${s.key}">
          ${inCol.map(card).join("") || `<p class="thin-note" style="padding:.5rem">Nothing here.</p>`}
        </div>
      </div>`;
  }).join("");

  document.querySelectorAll(".card").forEach(el => {
    el.addEventListener("click", () => openDrawer(el.dataset.id));
    el.addEventListener("dragstart", e => {
      e.dataTransfer.setData("text/plain", el.dataset.id);
      e.dataTransfer.effectAllowed = "move";
      el.classList.add("dragging");
    });
    el.addEventListener("dragend", () => el.classList.remove("dragging"));
  });

  document.querySelectorAll(".drop").forEach(zone => {
    zone.addEventListener("dragover", e => { e.preventDefault(); zone.parentElement.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.parentElement.classList.remove("over"));
    zone.addEventListener("drop", async e => {
      e.preventDefault();
      zone.parentElement.classList.remove("over");
      await moveTo(e.dataTransfer.getData("text/plain"), zone.dataset.status);
    });
  });
}

function card(r) {
  return `
    <article class="card${r.is_overdue ? " overdue" : ""}" draggable="true" data-id="${r.id}"
             tabindex="0" role="button" aria-label="Open ${esc(r.customer_name)}">
      <div class="name">${esc(r.customer_name)}</div>
      <div class="meta">
        <span class="ref">${esc(r.ref)}</span>
        ${r.site_town ? `<span>${esc(r.site_town)}</span>` : ""}
        ${(r.product_type || []).length ? `<span>${esc(r.product_type[0])}</span>` : ""}
      </div>
      <div class="foot">
        ${r.quote_value ? `<span class="value">${money(r.quote_value)}</span>` : ""}
        <span>${r.age_days}d old</span>
        ${r.is_overdue ? `<span class="flag">Overdue</span>` : ""}
      </div>
    </article>`;
}

/* Optimistic: the card moves, and goes back if the database refuses. */
async function moveTo(id, status) {
  const row = rows.find(r => r.id === id);
  if (!row || row.status === status) return;

  const was = row.status;
  row.status = status;
  render();

  const gaps = missingFor(status, row);
  if (gaps.length) {
    row.status = was; render();
    await openDrawer(id, { missing: gaps, status,
      message: "Needs " + gaps.map(f => FIELD_LABEL[f] || f).join(" and ") + " first." });
    return;
  }

  try {
    await transitionStatus(id, status);
    await load();
  } catch (e) {
    row.status = was; render();
    await openDrawer(id, { missing: e.missing || [], status, message: e.message });
  }
}

/* -------------------------------------------------------------- table */

const COLS = [
  { key: "ref", label: "Ref" },
  { key: "customer_name", label: "Customer" },
  { key: "site_town", label: "Town" },
  { key: "status", label: "Status", fmt: v => STATUS_NAME[v] || v },
  { key: "source", label: "Source" },
  { key: "received_on", label: "Received", fmt: shortDate },
  { key: "quote_value", label: "Quote", fmt: money, num: true },
  { key: "probability", label: "Prob.", fmt: v => v ? v + "%" : "—", num: true },
  { key: "next_action_on", label: "Next action", fmt: shortDate },
  { key: "age_days", label: "Age", fmt: v => v + "d", num: true }
];

let sortKey = "received_on", sortDir = -1;

function renderTable(list) {
  const sorted = [...list].sort((a, b) => {
    const x = a[sortKey], y = b[sortKey];
    if (x === y) return 0;
    if (x === null || x === undefined) return 1;
    if (y === null || y === undefined) return -1;
    return (x > y ? 1 : -1) * sortDir;
  });

  $("tableHead").innerHTML = COLS.map(c =>
    `<th data-key="${c.key}" ${sortKey === c.key ? `aria-sort="${sortDir === 1 ? "ascending" : "descending"}"` : ""}
     >${esc(c.label)}</th>`).join("");

  $("tableBody").innerHTML = sorted.length ? sorted.map(r =>
    `<tr data-id="${r.id}">` + COLS.map(c =>
      `<td class="${c.num ? "num" : ""}">${esc(c.fmt ? c.fmt(r[c.key]) : (r[c.key] ?? "—"))}</td>`).join("") + "</tr>"
  ).join("") : `<tr><td colspan="${COLS.length}"><div class="empty-state">
      <h3>Nothing matches</h3><p>Clear the search, or add the enquiry with the button above.</p></div></td></tr>`;

  $("tableHead").querySelectorAll("th").forEach(th =>
    th.addEventListener("click", () => {
      if (sortKey === th.dataset.key) sortDir = -sortDir; else { sortKey = th.dataset.key; sortDir = 1; }
      render();
    }));
  $("tableBody").querySelectorAll("tr[data-id]").forEach(tr =>
    tr.addEventListener("click", () => openDrawer(tr.dataset.id)));
}

/* ------------------------------------------------------------- drawer */

function field(label, key, type = "text", value = "", hint = "", opts = null) {
  const v = value ?? "";
  let control;
  if (opts) {
    control = `<select data-key="${key}">
      <option value="">Please choose…</option>
      ${opts.map(o => `<option value="${esc(o)}" ${String(v) === String(o) ? "selected" : ""}>${esc(o)}</option>`).join("")}
    </select>`;
  } else if (type === "textarea") {
    control = `<textarea data-key="${key}">${esc(v)}</textarea>`;
  } else {
    control = `<input type="${type}" data-key="${key}" value="${esc(v)}">`;
  }
  return `<div class="field" data-field="${key}">
    <label>${esc(label)}</label>${control}
    ${hint ? `<p class="hint">${esc(hint)}</p>` : ""}</div>`;
}

async function openDrawer(id, opts = {}) {
  dirty = {};
  current = id ? await getEnquiry(id) : { status: "new", source: "website", billing_same: true, product_type: [] };
  const events = id ? await getEvents(id) : [];

  $("drawerTitle").textContent = id ? (current.customer_name || "Enquiry") : "New enquiry";
  $("drawerRef").textContent = current.ref || "";
  $("btnConvert").hidden = !(id && current.status === "won" && !current.job_id);

  $("drawerBody").innerHTML = `
    <div>
      <div class="fieldset"><h3>Who</h3>
        <div class="frow two">
          ${field("Customer name", "customer_name", "text", current.customer_name)}
          ${field("Contact name", "contact_name", "text", current.contact_name)}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Phone", "phone", "tel", current.phone)}
          ${field("Email", "email", "email", current.email)}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Source", "source", "text", current.source, "", SOURCES)}
          ${field("Received on", "received_on", "date", current.received_on)}
        </div>
      </div>

      <div class="fieldset"><h3>The property</h3>
        <div class="frow two">
          ${field("Town", "site_town", "text", current.site_town)}
          ${field("Postcode", "site_postcode", "text", current.site_postcode, "Tells us whether it is in reach")}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Property type", "property_type", "text", current.property_type, "", [
            "Listed building", "In a conservation area", "Period property, not listed",
            "Modern property", "Commercial or trade project", "Not sure"])}
          ${field("Product", "product_type_single", "text", (current.product_type || [])[0], "", PRODUCT_TYPES)}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Approx. units", "approx_units", "number", current.approx_units)}
          ${field("Material", "material", "text", current.material, "", ["Accoya", "Oak", "Sapele", "Idigbo", "Redwood"])}
        </div>
        <div style="margin-top:.7rem">${field("What they need", "job_description", "textarea", current.job_description)}</div>
      </div>

      <div class="fieldset"><h3>Survey</h3>
        <div class="frow two">
          ${field("Survey date", "survey_date", "date", current.survey_date)}
          ${field("Slot", "survey_slot", "text", current.survey_slot, "", ["am", "pm"])}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Surveyor", "surveyor", "text", current.surveyor, "", ["Harry", "David"])}
          ${field("Completed on", "survey_completed_on", "date", current.survey_completed_on)}
        </div>
      </div>

      <div class="fieldset"><h3>Quote</h3>
        <div class="frow two">
          ${field("Quote value (£)", "quote_value", "number", current.quote_value)}
          ${field("Sent on", "quote_sent_on", "date", current.quote_sent_on)}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Expires", "quote_expires_on", "date", current.quote_expires_on)}
          ${field("Probability (%)", "probability", "number", current.probability)}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("Install window from", "target_install_from", "date", current.target_install_from)}
          ${field("to", "target_install_to", "date", current.target_install_to)}
        </div>
      </div>

      <div class="fieldset"><h3>Next step</h3>
        <div class="frow two">
          ${field("Next action", "next_action", "text", current.next_action)}
          ${field("By", "next_action_on", "date", current.next_action_on)}
        </div>
        <div class="frow two" style="margin-top:.7rem">
          ${field("First contacted on", "first_contacted_on", "date", current.first_contacted_on)}
          ${field("Status", "status", "text", current.status, "", STATUSES.map(s => s.key))}
        </div>
        ${current.status === "lost" ? `<div class="frow two" style="margin-top:.7rem">
          ${field("Reason lost", "lost_reason", "text", current.lost_reason, "", [
            "Price", "Went elsewhere", "Project postponed", "No response", "Outside our area", "Timescale too long"])}
          ${field("Lost to", "lost_to", "text", current.lost_to)}
        </div>` : ""}
        <div style="margin-top:.7rem">${field("Notes", "notes", "textarea", current.notes)}</div>
      </div>
    </div>

    <div>
      <div class="fieldset"><h3>History</h3>
        ${events.length ? `<ul class="timeline">${events.map(e => `
          <li><b>${esc(STATUS_NAME[e.to_status] || e.to_status)}</b>
            <span>${e.from_status ? "from " + esc(STATUS_NAME[e.from_status]) + " · " : ""}${longDate(e.occurred_at)}</span>
          </li>`).join("")}</ul>`
        : `<p class="thin-note">No history yet. It starts the moment this is saved.</p>`}
      </div>
      ${current.job_id ? `<div class="fieldset"><h3>Job</h3>
        <p style="font-size:.85rem;margin:0">This enquiry became a job.
        <a href="/planner/">Open the schedule</a>.</p></div>` : ""}
    </div>`;

  $("drawerBody").querySelectorAll("[data-key]").forEach(el =>
    el.addEventListener("input", () => { dirty[el.dataset.key] = el.value; }));

  const msg = $("drawerMsg");
  msg.textContent = opts.message || "";
  msg.className = "msg" + (opts.message ? " err" : "");

  /* Highlight every field the move was short of, and put the cursor in
     the first. Naming two fields in the message but marking only one
     sends the person hunting for the other. */
  const needed = opts.missing && opts.missing.length ? opts.missing : (opts.focus ? [opts.focus] : []);
  needed.forEach((f, i) => {
    const el = $("drawerBody").querySelector(`[data-field="${f}"]`);
    if (!el) return;
    el.classList.add("needed");
    if (i === 0) el.querySelector("input,select,textarea")?.focus();
  });
  if (opts.status) dirty.status = opts.status;

  $("drawer").hidden = false;
  requestAnimationFrame(() => { $("drawer").classList.add("open"); $("scrim").classList.add("open"); });
}

function closeDrawer() {
  $("drawer").classList.remove("open");
  $("scrim").classList.remove("open");
  setTimeout(() => { $("drawer").hidden = true; }, 340);
  current = null; dirty = {};
}

async function save() {
  const msg = $("drawerMsg");
  const patch = { ...dirty };

  if ("product_type_single" in patch) {
    patch.product_type = patch.product_type_single ? [patch.product_type_single] : [];
    delete patch.product_type_single;
  }
  if ("billing_same" in patch) patch.billing_same = patch.billing_same === "true";

  try {
    $("btnSave").disabled = true;
    msg.textContent = "Saving…"; msg.className = "msg";
    if (current && current.id) await updateEnquiry(current.id, patch);
    else await createEnquiry(patch);
    await load();
    msg.textContent = "Saved."; msg.className = "msg ok";
    setTimeout(closeDrawer, 450);
  } catch (e) {
    msg.textContent = e.message;
    msg.className = "msg err";
    (e.missing || []).forEach(f => {
      const el = $("drawerBody").querySelector(`[data-field="${f}"]`);
      if (el) el.classList.add("needed");
    });
  } finally {
    $("btnSave").disabled = false;
  }
}

/* --------------------------------------------------------------- wire */

function wire() {
  document.querySelectorAll(".seg [data-view]").forEach(b =>
    b.addEventListener("click", () => {
      view = b.dataset.view;
      document.querySelectorAll(".seg [data-view]").forEach(x =>
        x.setAttribute("aria-pressed", String(x === b)));
      render();
    }));

  $("search").addEventListener("input", e => { term = e.target.value.trim(); render(); });
  $("btnNew").addEventListener("click", () => openDrawer(null));
  $("btnSave").addEventListener("click", save);
  $("drawerClose").addEventListener("click", closeDrawer);
  $("scrim").addEventListener("click", closeDrawer);

  $("btnConvert").addEventListener("click", async () => {
    if (!current) return;
    const msg = $("drawerMsg");
    try {
      $("btnConvert").disabled = true;
      msg.textContent = "Creating the job…"; msg.className = "msg";
      await convertToJob(current.id);
      await load();
      msg.textContent = "Job created. It is on the schedule now."; msg.className = "msg ok";
      $("btnConvert").hidden = true;
    } catch (e) {
      msg.textContent = e.message; msg.className = "msg err";
    } finally {
      $("btnConvert").disabled = false;
    }
  });

  $("btnCsv").addEventListener("click", () => {
    downloadCsv("enquiries-" + new Date().toISOString().slice(0, 10) + ".csv",
      toCsv(visible(), COLS));
  });

  document.addEventListener("keydown", e => {
    if (e.key === "Escape" && !$("drawer").hidden) closeDrawer();
  });

  /* Keyboard equivalent for drag: open the card and change the status
     field. Colour and position are never the only route to an action. */
  document.addEventListener("keydown", e => {
    if (e.key !== "Enter" && e.key !== " ") return;
    const c = e.target.closest?.(".card");
    if (c) { e.preventDefault(); openDrawer(c.dataset.id); }
  });
}
