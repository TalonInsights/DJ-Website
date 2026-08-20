/* =====================================================================
   David Jackson & Son — Production Planning
   Supabase-backed workshop schedule.

   Persistence model
   -----------------
   `projects` in memory is what the board renders. Every change is
   written straight back to Postgres, one row per job, debounced so a
   flurry of drags collapses into a single write. Nothing is cached in
   localStorage: the board holds customer and staff names, and leaving
   copies of that on whatever browser was last used is exactly the
   thing UK GDPR asks you not to do.
   ===================================================================== */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { SUPABASE_URL, SUPABASE_ANON_KEY, ALLOWED_EMAILS } from "./config.js";

"use strict";

/* ================= supabase ================= */
const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    // Handled by hand in boot() so failures surface instead of being
    // swallowed — a silent redirect back to the login box is impossible
    // to diagnose from the outside.
    detectSessionInUrl: false,
    flowType: "pkce"
  }
});

/* ================= constants ================= */
const DAY = 86400000;

const PHASES = [
  {key:"timber",   name:"Timber Matching",   c:"var(--p1)", cr:"var(--p1r)", days:3},
  {key:"assembly", name:"Assembly",          c:"var(--p2)", cr:"var(--p2r)", days:5},
  {key:"sanding",  name:"Sanding",           c:"var(--p3)", cr:"var(--p3r)", days:2},
  {key:"hardware", name:"Fitting Hardware",  c:"var(--p4)", cr:"var(--p4r)", days:2},
  {key:"prep",     name:"Final Prep",        c:"var(--p5)", cr:"var(--p5r)", days:2},
  {key:"spray",    name:"Spray Finishing",   c:"var(--p6)", cr:"var(--p6r)", days:3},
  {key:"glazing",  name:"Glazing",           c:"var(--p7)", cr:"var(--p7r)", days:2},
  {key:"dispatch", name:"Dispatch",          c:"var(--p8)", cr:"var(--p8r)", days:1}
];
const PH = Object.fromEntries(PHASES.map(p=>[p.key,p]));
const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
const WD = ["S","M","T","W","T","F","S"];

/* ================= date helpers ================= */
const iso = d => d.toISOString().slice(0,10);
const parse = s => new Date(s+"T00:00:00Z");
const addD = (s,n) => iso(new Date(parse(s).getTime()+n*DAY));
const diffD = (a,b) => Math.round((parse(b)-parse(a))/DAY);
const dow = s => parse(s).getUTCDay();          // 0 Sun … 6 Sat
const isWE = s => dow(s)===0 || dow(s)===6;
const nextWork = s => { let d=s; while(isWE(d)) d=addD(d,1); return d; };
const pretty = s => { const d=parse(s); return d.getUTCDate()+" "+MONTHS[d.getUTCMonth()]; };

/* Local calendar date, not UTC — otherwise the board shows "yesterday"
   between midnight and 1am during British Summer Time. */
const TODAY = (()=>{
  const d = new Date();
  return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0");
})();

function workSpan(start, n){            // n working days from start → end date
  let d = nextWork(start), left = n-1;
  while(left>0){ d = addD(d,1); if(!isWE(d)) left--; }
  return d;
}

/* ================= state ================= */
let projects = [];
let dayW = 32;
let sortBy = "deadline";
let hidden = new Set();
let editingId = null;
let range = {start:TODAY, days:120};

const $ = id => document.getElementById(id);

/* ================= auth ================= */
const gateForm = $("gateForm"), gateEmail = $("gateEmail"), gateCode = $("gateCode"),
      gateBtn = $("gateBtn"), gateBack = $("gateBack"), gateMsg = $("gateMsg"),
      stepEmail = $("stepEmail"), stepCode = $("stepCode"),
      gateHead = $("gateHead"), gateIntro = $("gateIntro");

let stage = "email";     // "email" → "code"
let otpEmail = null;     // the address the code was sent to

function setGateMsg(text, kind){
  gateMsg.textContent = text;
  gateMsg.className = "gate-msg show " + (kind||"");
}
function setState(s){ document.body.dataset.state = s; }

function showEmailStep(){
  stage = "email"; otpEmail = null;
  stepEmail.hidden = false; stepCode.hidden = true; gateBack.hidden = true;
  gateHead.textContent = "Staff sign in";
  gateIntro.textContent = "This board is private. Enter the workshop email address and "+
                          "we'll send a six-digit code — there is no password to remember or lose.";
  gateBtn.textContent = "Email me a code";
  gateCode.value = "";
  gateEmail.focus();
}

function showCodeStep(email){
  stage = "code"; otpEmail = email;
  stepEmail.hidden = true; stepCode.hidden = false; gateBack.hidden = false;
  gateHead.textContent = "Enter your code";
  gateIntro.textContent = "We've emailed a six-digit code to "+email+
                          ". It expires in an hour. Type it here — you don't need to leave this page.";
  gateBtn.textContent = "Sign in";
  gateCode.value = "";
  gateCode.focus();
}

gateBack.addEventListener("click", ()=>{ showEmailStep(); setGateMsg("", ""); gateMsg.classList.remove("show"); });

/* Typing the sixth digit submits — saves reaching for the mouse. */
gateCode.addEventListener("input", ()=>{
  gateCode.value = gateCode.value.replace(/\D/g,"").slice(0,6);
  if(gateCode.value.length === 6) gateForm.requestSubmit();
});

async function sendCode(email){
  gateBtn.disabled = true;
  setGateMsg("Sending…", "");

  const { error } = await sb.auth.signInWithOtp({
    email,
    options: { shouldCreateUser: false }     // no self-signup, ever
  });

  gateBtn.disabled = false;

  if(error){
    setGateMsg(
      /not.*(allowed|found)|signups? not allowed/i.test(error.message)
        ? "That address doesn't have access to this board."
        : "Couldn't send the code: " + error.message,
      "err"
    );
    return;
  }
  showCodeStep(email);
  setGateMsg("Code sent. Check your inbox.", "ok");
}

async function verifyCode(code){
  gateBtn.disabled = true;
  setGateMsg("Checking…", "");

  const { error } = await sb.auth.verifyOtp({ email: otpEmail, token: code, type: "email" });

  gateBtn.disabled = false;

  if(error){
    setGateMsg(authError(error.code || "", error.message), "err");
    gateCode.value = ""; gateCode.focus();
    return;
  }
  // onAuthStateChange picks it up from here.
}

gateForm.addEventListener("submit", async e=>{
  e.preventDefault();

  if(stage === "code"){
    const code = gateCode.value.trim();
    if(code.length !== 6){ setGateMsg("The code is six digits.", "err"); return; }
    await verifyCode(code);
    return;
  }

  const email = gateEmail.value.trim().toLowerCase();
  if(!email || !/^\S+@\S+\.\S+$/.test(email)){
    setGateMsg("That doesn't look like an email address.", "err");
    return;
  }
  const allowed = (ALLOWED_EMAILS || []).map(a => a.trim().toLowerCase());
  if(allowed.length && !allowed.includes(email)){
    setGateMsg("That address doesn't have access to this board.", "err");
    return;
  }
  await sendCode(email);
});

$("btnSignOut").addEventListener("click", async ()=>{
  if(savePending() && !confirm("Some changes are still saving. Sign out anyway?")) return;
  await sb.auth.signOut();
  projects = [];
  started = false;
  setState("anon");
  showEmailStep();
  setGateMsg("You've been signed out.", "ok");
});

sb.auth.onAuthStateChange((event, session)=>{
  if(session) start();
  else if(event === "SIGNED_OUT") setState("anon");
});

/* Turn Supabase's auth errors into something a joiner can act on. */
function authError(code, description){
  const d = (description||"").toLowerCase();

  // PKCE first — its message contains "invalid" and "code", so a looser
  // rule below would swallow it and report the wrong cause. Only reachable
  // if someone clicks the link in the email rather than typing the code.
  if(/verifier/.test(d))
    return "Open that link in the same browser you asked for it from — or ignore it "+
           "and type the six-digit code from the same email instead.";

  if(/expired/.test(code+d))
    return "That code has expired. Codes last an hour — go back and request a new one.";

  if(/rate limit|too many/.test(d))
    return "Too many attempts. Wait a minute, then try again.";

  if(/already|used|invalid/.test(code+d) && /token|otp|code/.test(code+d))
    return "That code isn't right. Check the latest email — an older code stops working "+
           "once a new one is sent.";

  if(/access_denied/.test(code))
    return "That code is no longer valid. Go back and request a new one.";

  return "Sign-in failed: " + (description || code || "unknown error");
}

/* ================= persistence ================= */
const timers = new Map();        // job id → debounce timer
const inflight = new Set();      // job ids currently being written
let syncError = null;

const savePending = () => timers.size > 0 || inflight.size > 0;

function setSync(){
  const el = $("sync"), txt = $("syncTxt");
  if(syncError){ el.dataset.sync="error"; txt.textContent="Not saved"; el.title = syncError; return; }
  if(savePending()){ el.dataset.sync="saving"; txt.textContent="Saving…"; el.title="Writing changes to the workshop database"; return; }
  el.dataset.sync="saved"; txt.textContent="Saved"; el.title="All changes saved";
}

function rowFor(p){
  return {
    id:       p.id,
    ref:      p.ref      || null,
    name:     p.name,
    client:   p.client   || null,
    deadline: p.deadline || null,
    phases:   p.phases
  };
}

function queueSave(p, delay=350){
  clearTimeout(timers.get(p.id));
  timers.set(p.id, setTimeout(()=>{ timers.delete(p.id); flush(p); }, delay));
  setSync();
}

async function flush(p){
  inflight.add(p.id);
  setSync();
  const { error } = await sb.from("jobs").upsert(rowFor(p));
  inflight.delete(p.id);
  syncError = error ? error.message : null;
  setSync();
}

async function removeJob(id){
  projects = projects.filter(x=>x.id!==id);
  clearTimeout(timers.get(id)); timers.delete(id);
  const { error } = await sb.from("jobs").delete().eq("id", id);
  syncError = error ? error.message : null;
  setSync();
}

async function loadJobs(){
  const { data, error } = await sb
    .from("jobs")
    .select("id,ref,name,client,deadline,phases")
    .order("deadline", {ascending:true, nullsFirst:false});

  if(error){ syncError = error.message; setSync(); return false; }

  projects = (data||[]).map(r=>({
    id: r.id,
    ref: r.ref || "",
    name: r.name || "",
    client: r.client || "",
    deadline: r.deadline || "",
    phases: Array.isArray(r.phases) ? r.phases : []
  }));
  syncError = null; setSync();
  return true;
}

window.addEventListener("beforeunload", e=>{
  if(savePending()){ e.preventDefault(); e.returnValue = ""; }
});

function uid(){
  return (crypto.randomUUID) ? crypto.randomUUID()
       : "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g,c=>{
           const r = Math.random()*16|0, v = c==="x" ? r : (r&0x3|0x8);
           return v.toString(16);
         });
}

/* ================= derived ================= */
function projStart(p){
  return p.phases.length ? p.phases.reduce((a,x)=> x.start<a?x.start:a, p.phases[0].start) : p.deadline;
}
function projEnd(p){
  return p.phases.length ? p.phases.reduce((a,x)=> x.end>a?x.end:a, p.phases[0].end) : p.deadline;
}
function breached(p){ return p.phases.length>0 && !!p.deadline && projEnd(p) > p.deadline; }

function computeRange(){
  let min = TODAY, max = TODAY;
  projects.forEach(p=>{
    p.phases.forEach(ph=>{ if(ph.start<min) min=ph.start; if(ph.end>max) max=ph.end; });
    if(p.deadline){ if(p.deadline<min) min=p.deadline; if(p.deadline>max) max=p.deadline; }
  });
  let start = addD(min,-9);
  while(dow(start)!==1) start = addD(start,-1);   // always begin on a Monday
  let days = diffD(start,max) + 18;
  if(days < 84) days = 84;
  range = {start, days};
}
function sorted(){
  const list = projects.slice();
  const cmp = {
    deadline:(a,b)=> (a.deadline||"9").localeCompare(b.deadline||"9"),
    start:(a,b)=> String(projStart(a)||"9").localeCompare(String(projStart(b)||"9")),
    ref:(a,b)=> (a.ref||"").localeCompare(b.ref||"", undefined, {numeric:true}),
    name:(a,b)=> (a.name||"").localeCompare(b.name||"")
  }[sortBy];
  return list.sort(cmp);
}

/* ================= rendering ================= */
const gridEl=$("grid"), rowsEl=$("rows"), daysEl=$("days"), monthsEl=$("months"),
      headTime=$("headTime"), todayLine=$("todayLine"), readout=$("readout");

function trackBg(){
  const line = "linear-gradient(90deg, rgba(255,255,255,.045) 0 1px, transparent 1px 100%)";
  const we = "linear-gradient(90deg, transparent 0 "+(dayW*5)+"px, rgba(255,255,255,.024) "+(dayW*5)+"px "+(dayW*7)+"px)";
  return {
    backgroundImage: line+", "+we,
    backgroundSize: dayW+"px 100%, "+(dayW*7)+"px 100%"
  };
}

function renderHeader(){
  const total = range.days*dayW;
  headTime.style.width = total+"px";
  daysEl.innerHTML = ""; monthsEl.innerHTML = "";

  // month band
  let i=0;
  while(i<range.days){
    const d = parse(addD(range.start,i));
    const m = d.getUTCMonth(), y = d.getUTCFullYear();
    let n=0;
    while(i+n<range.days){
      const dd = parse(addD(range.start,i+n));
      if(dd.getUTCMonth()!==m) break;
      n++;
    }
    const el = document.createElement("div");
    el.className="month"; el.style.width=(n*dayW)+"px";
    el.textContent = MONTHS[m]+" "+String(y).slice(2);
    monthsEl.appendChild(el);
    i+=n;
  }

  // day cells
  const frag = document.createDocumentFragment();
  for(let k=0;k<range.days;k++){
    const s = addD(range.start,k), d = parse(s);
    const el = document.createElement("div");
    el.className = "day"+(isWE(s)?" we":"")+(s===TODAY?" today":"");
    el.style.width = dayW+"px";
    el.innerHTML = '<span class="dn">'+d.getUTCDate()+'</span><span class="dw">'+WD[d.getUTCDay()]+'</span>';
    el.title = pretty(s);
    frag.appendChild(el);
  }
  daysEl.appendChild(frag);

  // today marker
  const tx = diffD(range.start, TODAY);
  if(tx>=0 && tx<range.days){
    todayLine.style.display="block";
    todayLine.style.left = "calc(var(--leftw) + "+(tx*dayW+dayW/2)+"px)";
  } else todayLine.style.display="none";
}

function renderRows(){
  const total = range.days*dayW;
  const bg = trackBg();
  rowsEl.innerHTML = "";
  const list = sorted();

  if(!list.length){
    const e = document.createElement("div");
    e.className="empty";
    e.innerHTML = '<div><h2>The board is clear</h2><p>Add your first job to start scheduling stages.</p>'+
                  '<button class="btn primary" id="emptyAdd">+ Add job</button></div>';
    rowsEl.appendChild(e);
    e.querySelector("#emptyAdd").addEventListener("click",()=>openModal(null));
    return;
  }

  const frag = document.createDocumentFragment();
  list.forEach(p=>{
    const row = document.createElement("div");
    row.className="row"; row.dataset.pid=p.id;

    // ---- left cell ----
    const cell = document.createElement("div");
    cell.className="rcell";
    const over = breached(p);
    cell.innerHTML =
      '<span class="c-ref">'+esc(p.ref||"—")+'</span>'+
      '<span class="c-name"><span class="nm">'+esc(p.name||"Untitled job")+'</span>'+
        '<span class="cl">'+(over?'<span class="flag">LATE</span>':'')+'<span class="txt">'+esc(p.client||"")+'</span></span></span>'+
      '<span class="c-due">'+(p.deadline?pretty(p.deadline):"—")+'</span>'+
      '<span class="c-acts">'+
        '<button class="edit" title="Edit job">✎</button>'+
        '<button class="del" title="Delete job">🗑</button>'+
      '</span>';
    cell.querySelector(".edit").addEventListener("click", e=>{e.stopPropagation();openModal(p.id);});
    cell.querySelector(".del").addEventListener("click", async e=>{
      e.stopPropagation();
      if(confirm('Delete "'+(p.name||"this job")+'"? This removes it from the database and cannot be undone.')){
        await removeJob(p.id); renderAll();
      }
    });
    row.appendChild(cell);

    // ---- track ----
    const track = document.createElement("div");
    track.className="track"; track.style.width = total+"px";
    track.style.backgroundImage = bg.backgroundImage;
    track.style.backgroundSize = bg.backgroundSize;

    p.phases.forEach(ph=>{
      const def = PH[ph.key]; if(!def) return;
      const x = diffD(range.start, ph.start);
      const w = (diffD(ph.start, ph.end)+1)*dayW;
      const bar = document.createElement("div");
      bar.className = "bar"+(hidden.has(ph.key)?" muted":"");
      bar.style.cssText += "--c:"+def.c+";--cr:"+def.cr+";left:"+(x*dayW+2)+"px;width:"+(w-4)+"px";
      bar.dataset.pid=p.id; bar.dataset.key=ph.key;
      bar.title = def.name+" · "+pretty(ph.start)+" → "+pretty(ph.end);
      const nd = diffD(ph.start,ph.end)+1;
      bar.innerHTML =
        '<span class="bt">'+def.name+'</span>'+
        '<span class="bm">'+nd+(nd===1?" day":" days")+(ph.who?' · <em>'+esc(ph.who)+'</em>':'')+'</span>'+
        '<span class="grip l"></span><span class="grip r"></span>';
      track.appendChild(bar);
    });

    if(p.deadline){
      const dx = diffD(range.start, p.deadline);
      const dl = document.createElement("div");
      dl.className = "dl"+(breached(p)?" breached":"");
      dl.style.left = (dx*dayW+2)+"px";
      dl.style.width = Math.max(dayW-4, 26)+"px";
      dl.dataset.pid = p.id;
      dl.title = "Deadline — "+pretty(p.deadline)+(breached(p)?" · work runs past this date":"");
      dl.innerHTML = "<span>DL</span>";
      track.appendChild(dl);
    }

    row.appendChild(track);
    frag.appendChild(row);
  });
  rowsEl.appendChild(frag);
}

function renderStats(){
  $("stProjects").textContent = projects.length;
  $("stPhases").textContent = projects.reduce((n,p)=>n+p.phases.length,0);
  $("stRisk").textContent = projects.filter(breached).length;
}

function renderChips(){
  const box = $("chips"); box.innerHTML="";
  PHASES.forEach(p=>{
    const b = document.createElement("button");
    b.className="chip"; b.style.setProperty("--c",p.c);
    b.setAttribute("aria-pressed", hidden.has(p.key)?"false":"true");
    b.innerHTML = '<span class="dot"></span>'+p.name;
    b.addEventListener("click",()=>{
      hidden.has(p.key) ? hidden.delete(p.key) : hidden.add(p.key);
      renderChips(); renderRows();
    });
    box.appendChild(b);
  });
}

function renderAll(){
  computeRange(); renderHeader(); renderRows(); renderStats();
}
function esc(s){ return String(s??"").replace(/[&<>"]/g, c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

/* ================= drag & drop ================= */
let drag = null;

gridEl.addEventListener("pointerdown", e=>{
  const grip = e.target.closest(".grip");
  const bar  = e.target.closest(".bar");
  const dl   = e.target.closest(".dl");
  if(!bar && !dl) return;

  const el = bar || dl;
  const p = projects.find(x=>x.id===el.dataset.pid);
  if(!p) return;

  drag = {
    el, p,
    mode: dl ? "dl" : (grip ? (grip.classList.contains("l")?"resl":"resr") : "move"),
    ph: bar ? p.phases.find(z=>z.key===bar.dataset.key) : null,
    x0: e.clientX,
    left0: parseFloat(el.style.left),
    w0: el.offsetWidth,
    moved: false, snap: 0
  };
  el.setPointerCapture(e.pointerId);
  el.classList.add("dragging");
  e.preventDefault();
});

gridEl.addEventListener("pointermove", e=>{
  if(!drag) return;
  const dx = e.clientX - drag.x0;
  if(Math.abs(dx) > 3) drag.moved = true;
  let snap = Math.round(dx/dayW);

  if(drag.mode==="move" || drag.mode==="dl"){
    drag.el.style.left = (drag.left0 + snap*dayW)+"px";
  } else if(drag.mode==="resr"){
    const min = dayW-4;
    const w = Math.max(min, drag.w0 + snap*dayW);
    snap = Math.round((w-drag.w0)/dayW);
    drag.el.style.width = w+"px";
  } else {
    const maxSnap = Math.round(drag.w0/dayW)-1;
    if(snap>maxSnap) snap = maxSnap;
    drag.el.style.left = (drag.left0 + snap*dayW)+"px";
    drag.el.style.width = (drag.w0 - snap*dayW)+"px";
  }
  drag.snap = snap;
  showReadout(e, snap);
});

function showReadout(e, snap){
  const d = drag;
  let text;
  if(d.mode==="dl"){
    text = "Deadline <b>"+pretty(addD(d.p.deadline, snap))+"</b>";
  } else {
    const s = d.mode==="resr" ? d.ph.start : addD(d.ph.start, snap);
    const en = d.mode==="move" ? addD(d.ph.end, snap) : (d.mode==="resr" ? addD(d.ph.end,snap) : d.ph.end);
    const n = diffD(s,en)+1;
    text = PH[d.ph.key].name+" &nbsp;<b>"+pretty(s)+" → "+pretty(en)+"</b> &nbsp;· "+n+(n===1?" day":" days");
  }
  readout.innerHTML = text;
  readout.style.display = "block";
  readout.style.left = Math.min(e.clientX+14, window.innerWidth-readout.offsetWidth-10)+"px";
  readout.style.top  = (e.clientY-40)+"px";
}

gridEl.addEventListener("pointerup", e=>{
  if(!drag) return;
  const d = drag; drag = null;
  d.el.classList.remove("dragging");
  readout.style.display="none";

  if(!d.moved){
    openModal(d.p.id);            // a click, not a drag
    renderRows();
    return;
  }
  if(d.snap!==0){
    if(d.mode==="dl"){
      d.p.deadline = addD(d.p.deadline, d.snap);
    } else if(d.mode==="move"){
      d.ph.start = addD(d.ph.start, d.snap);
      d.ph.end   = addD(d.ph.end,   d.snap);
    } else if(d.mode==="resr"){
      d.ph.end = addD(d.ph.end, d.snap);
    } else {
      d.ph.start = addD(d.ph.start, d.snap);
    }
    queueSave(d.p);
  }
  renderAll();
});
gridEl.addEventListener("pointercancel", ()=>{
  if(!drag) return;
  drag.el.classList.remove("dragging");
  drag=null; readout.style.display="none"; renderRows();
});

/* ================= modal ================= */
const scrim=$("scrim");

function buildPhaseRows(){
  const box = $("plist"); box.innerHTML="";
  PHASES.forEach((p,i)=>{
    const r = document.createElement("div");
    r.className="prow"; r.dataset.key=p.key;
    r.style.setProperty("--c",p.c); r.style.setProperty("--cr",p.cr);
    r.innerHTML =
      '<input type="checkbox" data-role="on">'+
      '<span class="pname"><i>'+(i+1)+'</i>'+p.name+'</span>'+
      '<input type="date" data-role="start" disabled>'+
      '<input type="date" data-role="end" disabled>'+
      '<input type="text" data-role="who" placeholder="Who’s on it" list="people" disabled>';
    const cb = r.querySelector('[data-role="on"]');
    cb.addEventListener("change",()=>togglePhaseRow(r));
    box.appendChild(r);
  });
  const dl = document.createElement("datalist"); dl.id="people";
  const names = new Set();
  projects.forEach(p=>p.phases.forEach(x=>{ if(x.who) names.add(x.who); }));
  names.forEach(n=>{ const o=document.createElement("option"); o.value=n; dl.appendChild(o); });
  box.appendChild(dl);
}
function togglePhaseRow(r){
  const on = r.querySelector('[data-role="on"]').checked;
  r.classList.toggle("on", on);
  r.querySelectorAll('[data-role="start"],[data-role="end"],[data-role="who"]').forEach(i=>i.disabled=!on);
  if(on && !r.querySelector('[data-role="start"]').value){
    const base = $("fStart").value || TODAY;
    const s = nextWork(base), e = workSpan(s, PH[r.dataset.key].days);
    r.querySelector('[data-role="start"]').value = s;
    r.querySelector('[data-role="end"]').value = e;
  }
}

function openModal(id){
  editingId = id;
  const p = id ? projects.find(x=>x.id===id) : null;
  $("mTitle").textContent = p ? "Edit job" : "Add job";
  $("mDelete").style.display = p ? "inline-flex" : "none";
  $("mErr").textContent = "";

  buildPhaseRows();

  $("fName").value    = p ? (p.name||"")   : "";
  $("fClient").value  = p ? (p.client||"") : "";
  $("fRef").value     = p ? (p.ref||"")    : nextRef();
  $("fStart").value   = p && p.phases.length ? projStart(p) : nextWork(TODAY);
  $("fDeadline").value= p ? (p.deadline||"") : "";

  if(p){
    p.phases.forEach(ph=>{
      const r = $("plist").querySelector('.prow[data-key="'+ph.key+'"]'); if(!r) return;
      r.querySelector('[data-role="on"]').checked = true;
      togglePhaseRow(r);
      r.querySelector('[data-role="start"]').value = ph.start;
      r.querySelector('[data-role="end"]').value   = ph.end;
      r.querySelector('[data-role="who"]').value   = ph.who||"";
    });
  }
  scrim.classList.add("open");
  setTimeout(()=>$("fName").focus(),40);
}
function closeModal(){ scrim.classList.remove("open"); editingId=null; }

function nextRef(){
  const y = new Date().getFullYear();
  let max = 0;
  projects.forEach(p=>{ const m=/^(\d+)/.exec(p.ref||""); if(m) max=Math.max(max,+m[1]); });
  return String(max+1).padStart(3,"0")+"/"+y;
}

$("btnAuto").addEventListener("click",()=>{
  let cur = nextWork($("fStart").value || TODAY);
  let any = false;
  $("plist").querySelectorAll(".prow").forEach(r=>{
    if(!r.querySelector('[data-role="on"]').checked) return;
    any = true;
    const end = workSpan(cur, PH[r.dataset.key].days);
    r.querySelector('[data-role="start"]').value = cur;
    r.querySelector('[data-role="end"]').value = end;
    cur = nextWork(addD(end,1));
  });
  if(!any){ $("mErr").textContent = "Tick at least one stage first."; return; }
  $("mErr").textContent = "";
  if(!$("fDeadline").value) $("fDeadline").value = workSpan(cur,3);
});

$("mSave").addEventListener("click",()=>{
  const err = $("mErr"); err.textContent="";
  $("plist").querySelectorAll(".prow").forEach(r=>r.classList.remove("err"));

  const name = $("fName").value.trim();
  if(!name){ err.textContent="Give the job a name."; $("fName").focus(); return; }

  const phases = [];
  let bad = false;
  $("plist").querySelectorAll(".prow").forEach(r=>{
    if(!r.querySelector('[data-role="on"]').checked) return;
    const s = r.querySelector('[data-role="start"]').value;
    const e = r.querySelector('[data-role="end"]').value;
    if(!s || !e || e < s){ r.classList.add("err"); bad = true; return; }
    phases.push({key:r.dataset.key, start:s, end:e, who:r.querySelector('[data-role="who"]').value.trim()});
  });
  if(bad){ err.textContent="Check the highlighted stages — each needs a start and an end date, and the end can't come first."; return; }
  if(!phases.length){ err.textContent="Tick at least one stage."; return; }

  let deadline = $("fDeadline").value;
  if(!deadline){
    deadline = phases.reduce((a,x)=> x.end>a?x.end:a, phases[0].end);
    deadline = workSpan(nextWork(addD(deadline,1)),1);
  }

  const data = {name, client:$("fClient").value.trim(), ref:$("fRef").value.trim(), deadline, phases};
  let target;
  if(editingId){
    target = projects.find(x=>x.id===editingId);
    Object.assign(target, data);
  } else {
    target = Object.assign({id:uid()}, data);
    projects.push(target);
  }
  queueSave(target, 0);
  closeModal(); renderAll();
});

$("mDelete").addEventListener("click", async ()=>{
  const p = projects.find(x=>x.id===editingId); if(!p) return;
  if(confirm('Delete "'+(p.name||"this job")+'"? This removes it from the database and cannot be undone.')){
    await removeJob(editingId);
    closeModal(); renderAll();
  }
});
$("mCancel").addEventListener("click",closeModal);
$("mClose").addEventListener("click",closeModal);
scrim.addEventListener("mousedown", e=>{ if(e.target===scrim) closeModal(); });
document.addEventListener("keydown", e=>{
  if(e.key==="Escape" && scrim.classList.contains("open")) closeModal();
});

/* ================= toolbar wiring ================= */
$("btnAdd").addEventListener("click",()=>openModal(null));
$("sortSel").addEventListener("change",e=>{ sortBy=e.target.value; renderRows(); });

$("zoomSeg").addEventListener("click",e=>{
  const b = e.target.closest("button"); if(!b) return;
  [...e.currentTarget.children].forEach(x=>x.setAttribute("aria-pressed", x===b ? "true":"false"));
  dayW = +b.dataset.w;
  renderAll(); scrollToToday(false);
});

function scrollToToday(smooth){
  const x = diffD(range.start, TODAY)*dayW;
  gridEl.scrollTo({left: Math.max(0, x - 160), behavior: smooth?"smooth":"auto"});
}
$("btnToday").addEventListener("click",()=>scrollToToday(true));

$("btnExport").addEventListener("click",()=>{
  const blob = new Blob([JSON.stringify(projects,null,2)],{type:"application/json"});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "production-schedule-"+TODAY+".json";
  a.click(); URL.revokeObjectURL(a.href);
});
$("btnImport").addEventListener("click",()=>$("fileImport").click());
$("fileImport").addEventListener("change", e=>{
  const f = e.target.files[0]; if(!f) return;
  const r = new FileReader();
  r.onload = async ()=>{
    try{
      const data = JSON.parse(r.result);
      if(!Array.isArray(data)) throw 0;
      if(!confirm("Restore "+data.length+" job(s)? This replaces everything currently on the board, in the database as well as on screen."))
        return;

      const rows = data
        .filter(p => p && p.name)
        .map(p => ({
          id:       uid(),
          ref:      p.ref      || null,
          name:     String(p.name).slice(0,200),
          client:   p.client   || null,
          deadline: p.deadline || null,
          phases:   Array.isArray(p.phases) ? p.phases : []
        }));

      const del = await sb.from("jobs").delete().neq("id","00000000-0000-0000-0000-000000000000");
      if(del.error) throw del.error;

      if(rows.length){
        const ins = await sb.from("jobs").insert(rows);
        if(ins.error) throw ins.error;
      }
      await loadJobs();
      renderAll();
    }catch(err){
      alert(err && err.message ? "Restore failed: "+err.message : "That file isn't a schedule backup.");
    }
  };
  r.readAsText(f);
  e.target.value = "";
});

/* ================= go ================= */
let started = false;
async function start(){
  if(started) return;
  started = true;
  await loadJobs();
  setState("ready");
  renderChips();
  renderAll();
  scrollToToday(false);
}

async function boot(){
  const url   = new URL(window.location.href);
  const hash  = new URLSearchParams(url.hash.replace(/^#/, ""));
  const clean = () => history.replaceState(null, "", url.pathname);
  const pick  = k => url.searchParams.get(k) || hash.get(k);

  // 1. Did Supabase send us back an error?
  const errCode = pick("error_code") || pick("error");
  if(errCode){
    clean();
    setState("anon");
    setGateMsg(authError(errCode, pick("error_description")), "err");
    return;
  }

  // 2. PKCE code from the magic link — exchange it for a session.
  const code = pick("code");
  if(code){
    const { error } = await sb.auth.exchangeCodeForSession(code);
    clean();
    if(error){
      setState("anon");
      setGateMsg(authError(error.code || "", error.message), "err");
      console.error("[planner] code exchange failed:", error);
      return;
    }
    await start();
    return;
  }

  // 3. Implicit flow — tokens arrive in the hash instead of a code.
  if(hash.get("access_token")){
    const { error } = await sb.auth.setSession({
      access_token:  hash.get("access_token"),
      refresh_token: hash.get("refresh_token")
    });
    clean();
    if(error){
      setState("anon");
      setGateMsg(authError("", error.message), "err");
      return;
    }
    await start();
    return;
  }

  // 4. Nothing in the URL — restore any existing session.
  const { data:{ session } } = await sb.auth.getSession();
  if(session) await start();
  else setState("anon");
}

boot();
