/* =====================================================================
   Data access — one function per view, plus the mutations.

   THE RULE FOR THIS FILE
   ----------------------
   No metric is computed here. Every number the UI shows is already a
   column in a view (supabase/migrations/..._analytics_views.sql). If you
   find yourself summing, averaging or dividing in JavaScript, the number
   belongs in SQL instead — otherwise two screens will eventually
   disagree about what a win rate is.

   The only arithmetic permitted here is presentation: formatting money,
   turning a rate into a bar width.
   ===================================================================== */

import { sb } from "./client.js";

/* ---------- period helpers ---------- */

export const PERIODS = {
  "90d": { label: "90 days", days: 90 },
  "12m": { label: "12 months", days: 365 },
  "ytd": { label: "Year to date", days: null },
  "all": { label: "All time", days: 3650 }
};

export function periodRange(key) {
  const to = new Date();
  let from;
  if (key === "ytd") from = new Date(to.getFullYear(), 0, 1);
  else from = new Date(to.getTime() - (PERIODS[key] || PERIODS["90d"]).days * 86400000);
  return { from: iso(from), to: iso(to) };
}

export const iso = d => (d instanceof Date ? d : new Date(d)).toISOString().slice(0, 10);

/* ---------- formatting ---------- */

const gbp0 = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", maximumFractionDigits: 0 });

export const money = v => (v === null || v === undefined || v === "") ? "—" : gbp0.format(Number(v));
export const num = v => (v === null || v === undefined) ? "—" : Number(v).toLocaleString("en-GB");

export function shortDate(d) {
  if (!d) return "—";
  return new Date(d).toLocaleDateString("en-GB", { day: "numeric", month: "short" });
}
export function longDate(d) {
  if (!d) return "—";
  return new Date(d).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}
export function monthLabel(d) {
  return new Date(d).toLocaleDateString("en-GB", { month: "short", year: "2-digit" });
}

/* A rate computed on a handful of enquiries is noise wearing the costume
   of a trend. Below this many, the UI shows the number greyed with the
   denominator visible rather than pretending it means something. */
export const THIN_N = 10;
export const isThin = n => !n || Number(n) < THIN_N;

export function rate(value, n) {
  if (value === null || value === undefined) return { text: "—", thin: true, n: n || 0 };
  return { text: Number(value).toFixed(0) + "%", thin: isThin(n), n: Number(n || 0) };
}

/* ---------- the status model ---------- */

export const STATUSES = [
  { key: "new",           name: "New" },
  { key: "contacted",     name: "Contacted" },
  { key: "survey_booked", name: "Survey booked" },
  { key: "surveyed",      name: "Surveyed" },
  { key: "quoted",        name: "Quoted" },
  { key: "follow_up",     name: "Follow up" },
  { key: "won",           name: "Won" },
  { key: "lost",          name: "Lost" },
  { key: "on_hold",       name: "On hold" }
];

export const STATUS_NAME = Object.fromEntries(STATUSES.map(s => [s.key, s.name]));

export const SOURCES = ["website", "phone", "email", "referral", "repeat", "trade", "walk_in", "other"];

export const PRODUCT_TYPES = [
  "Sliding sash windows", "Casement windows", "Entrance doors",
  "French doors", "Bi-fold doors", "Bespoke joinery", "Staircase"
];

/* Mirrors the database trigger in _0005_transition_rules.sql. The
   database is the enforcement; this copy exists so the drawer can
   highlight the missing field before a round trip, and must be kept in
   step with it. */
export const REQUIRED_FOR = {
  contacted:     ["first_contacted_on"],
  survey_booked: ["survey_date", "surveyor"],
  surveyed:      ["survey_completed_on"],
  quoted:        ["quote_value", "quote_sent_on"],
  won:           ["quote_value"],
  lost:          ["lost_reason"]
};

export const FIELD_LABEL = {
  first_contacted_on: "First contacted on",
  survey_date: "Survey date",
  surveyor: "Surveyor",
  survey_completed_on: "Survey completed on",
  quote_value: "Quote value",
  quote_sent_on: "Quote sent on",
  lost_reason: "Reason lost"
};

/* What a status change needs that the enquiry does not yet have. */
export function missingFor(status, enquiry) {
  return (REQUIRED_FOR[status] || []).filter(f => {
    const v = enquiry ? enquiry[f] : null;
    return v === null || v === undefined || String(v).trim() === "";
  });
}

/* ---------- reads: one per view ---------- */

const fail = (what, error) => { throw new Error(what + ": " + (error.message || error)); };

export async function getPipelineOpen() {
  const { data, error } = await sb.from("v_pipeline_open").select("*").order("received_on", { ascending: false });
  if (error) fail("Could not load the pipeline", error);
  return data;
}

export async function getEnquiries({ from, to } = {}) {
  let q = sb.from("v_enquiry_flat").select("*").order("received_on", { ascending: false });
  if (from) q = q.gte("received_on", from);
  if (to) q = q.lte("received_on", to);
  const { data, error } = await q;
  if (error) fail("Could not load enquiries", error);
  return data;
}

export async function getEnquiry(id) {
  const { data, error } = await sb.from("enquiries").select("*").eq("id", id).single();
  if (error) fail("Could not load that enquiry", error);
  return data;
}

export async function getEvents(enquiryId) {
  const { data, error } = await sb.from("enquiry_events")
    .select("*").eq("enquiry_id", enquiryId).order("occurred_at", { ascending: false });
  if (error) fail("Could not load the history", error);
  return data;
}

export async function getSurveyDiary() {
  const { data, error } = await sb.from("v_survey_diary").select("*").order("survey_date");
  if (error) fail("Could not load the survey diary", error);
  return data;
}

export async function getOverdue() {
  const { data, error } = await sb.from("v_overdue_actions")
    .select("*").order("days_overdue", { ascending: false });
  if (error) fail("Could not load overdue follow-ups", error);
  return data;
}

export async function getSummary() {
  const { data, error } = await sb.from("mv_dashboard_summary").select("*").limit(1).maybeSingle();
  if (error) fail("Could not load the dashboard summary", error);
  return data;
}

export async function getFunnel({ from, to }) {
  const { data, error } = await sb.from("v_enquiry_funnel")
    .select("*").gte("period", from).lte("period", to).order("period");
  if (error) fail("Could not load the funnel", error);
  return data;
}

export async function getCycleTimes({ from, to }) {
  const { data, error } = await sb.from("v_enquiry_cycle_times")
    .select("*").gte("period", from).lte("period", to).order("period");
  if (error) fail("Could not load cycle times", error);
  return data;
}

export async function getLostAnalysis({ from, to }) {
  const { data, error } = await sb.from("v_lost_analysis")
    .select("*").gte("period", from).lte("period", to);
  if (error) fail("Could not load lost analysis", error);
  return data;
}

export async function getCapacity() {
  const { data, error } = await sb.from("v_weekly_capacity").select("*").order("week_start");
  if (error) fail("Could not load capacity", error);
  return data;
}

export async function getJobPerformance() {
  const { data, error } = await sb.from("v_job_performance").select("*").order("baseline_start", { ascending: false });
  if (error) fail("Could not load job performance", error);
  return data;
}

export async function getPromiseVsDelivery({ from, to }) {
  const { data, error } = await sb.from("v_promise_vs_delivery")
    .select("*").gte("actual_end", from).lte("actual_end", to);
  if (error) fail("Could not load delivery performance", error);
  return data;
}

export async function getEstimateAccuracy({ from, to }) {
  const { data, error } = await sb.from("v_estimate_accuracy")
    .select("*").gte("period", from).lte("period", to);
  if (error) fail("Could not load estimate accuracy", error);
  return data;
}

export async function getSourcePerformance({ from, to }) {
  const { data, error } = await sb.from("v_source_performance")
    .select("*").gte("period", from).lte("period", to);
  if (error) fail("Could not load source performance", error);
  return data;
}

/* ---------- writes ---------- */

const CLEAN = v => (v === "" || v === undefined) ? null : v;

export async function createEnquiry(patch) {
  const row = {};
  for (const [k, v] of Object.entries(patch)) row[k] = CLEAN(v);
  if (!row.customer_name || !String(row.customer_name).trim()) {
    throw new Error("An enquiry needs a customer name.");
  }
  const { data, error } = await sb.from("enquiries").insert(row).select().single();
  if (error) fail("Could not save the enquiry", error);
  return data;
}

export async function updateEnquiry(id, patch) {
  const row = {};
  for (const [k, v] of Object.entries(patch)) row[k] = CLEAN(v);
  const { data, error } = await sb.from("enquiries").update(row).eq("id", id).select().single();
  if (error) fail("Could not save", error);
  return data;
}

/* The database refuses an incomplete transition and names the field, so
   a failure here is readable rather than "invalid". `extra` carries the
   fields the new status needs, when the caller already has them. */
export async function transitionStatus(id, toStatus, extra = {}) {
  const patch = { status: toStatus };
  for (const [k, v] of Object.entries(extra)) patch[k] = CLEAN(v);

  const { data, error } = await sb.from("enquiries").update(patch).eq("id", id).select().single();
  if (error) {
    const e = new Error(readableTransitionError(error, toStatus));
    e.missing = (error.hint || "").split(",").filter(Boolean);
    throw e;
  }
  return data;
}

function readableTransitionError(error, toStatus) {
  const m = error.message || "";
  if (m.includes("missing")) {
    const fields = (error.hint || "").split(",").filter(Boolean).map(f => FIELD_LABEL[f] || f);
    return "Needs " + fields.join(" and ") + " before it can move to " + (STATUS_NAME[toStatus] || toStatus) + ".";
  }
  return m || "Could not change the status.";
}

export async function convertToJob(enquiryId, name) {
  const { data, error } = await sb.rpc("convert_enquiry_to_job", {
    p_enquiry_id: enquiryId,
    p_name: name || null,
    p_start: null
  });
  if (error) fail("Could not create the job", error);
  return data;
}

export async function refreshDashboard() {
  const { data, error } = await sb.rpc("refresh_dashboard");
  if (error) fail("Could not refresh", error);
  return data;
}

/* ---------- CSV ---------- */

export function toCsv(rows, columns) {
  const esc = v => {
    if (v === null || v === undefined) return "";
    const s = Array.isArray(v) ? v.join("; ") : String(v);
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  };
  const head = columns.map(c => esc(c.label)).join(",");
  const body = rows.map(r => columns.map(c => esc(r[c.key])).join(",")).join("\n");
  return head + "\n" + body;
}

export function downloadCsv(filename, csv) {
  const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = filename;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
