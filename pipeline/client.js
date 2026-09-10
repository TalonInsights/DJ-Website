/* =====================================================================
   Shared Supabase client and sign-in gate.

   The same OTP flow as the production planner, and the same account.
   This is one product with one sign-in, not a second system: a member of
   staff who can open the schedule can open the pipeline.

   Nothing is cached in localStorage beyond the Supabase session itself.
   Enquiries hold names, addresses and phone numbers, and leaving copies
   of that on whatever browser was last used is exactly what UK GDPR asks
   you not to do.
   ===================================================================== */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { SUPABASE_URL, SUPABASE_ANON_KEY, ALLOWED_EMAILS, OTP_LENGTH } from "../planner/config.js";

const CODE_LEN = (Number(OTP_LENGTH) >= 6 && Number(OTP_LENGTH) <= 10) ? Number(OTP_LENGTH) : 6;

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
    flowType: "pkce"
  }
});

export const $ = id => document.getElementById(id);

/* Specific rules first. The PKCE message contains both "invalid" and
   "code", so a looser rule placed above it swallows the case that
   actually needs explaining. */
function authError(code, message) {
  const m = (message || "").toLowerCase();
  if (m.includes("code verifier") || m.includes("pkce")) {
    return "That code was requested on a different device or browser. Ask for a new one here.";
  }
  if (code === "otp_expired" || m.includes("expired")) {
    return "That code has expired. Ask for a new one.";
  }
  if (m.includes("invalid") && m.includes("token")) {
    return "That code is not right. Check the digits and try again.";
  }
  if (m.includes("rate limit")) {
    return "Too many attempts just now. Wait a minute and try again.";
  }
  return message || "Could not sign you in.";
}

/* Wires the gate markup and resolves once there is a session.
   `onReady` is called with the session every time one appears. */
export function mountGate(onReady) {
  const gate = $("gate"), app = $("app");
  const form = $("gateForm"), emailStep = $("stepEmail"), codeStep = $("stepCode");
  const email = $("gateEmail"), codeIn = $("gateCode"), btn = $("gateBtn"), back = $("gateBack");
  const head = $("gateHead"), intro = $("gateIntro"), msg = $("gateMsg");

  let stage = "email", otpEmail = "";

  const say = (text, kind) => {
    msg.textContent = text;
    msg.className = "gmsg show " + (kind || "");
    if (!text) msg.className = "gmsg";
  };

  function emailStage() {
    stage = "email";
    emailStep.hidden = false; codeStep.hidden = true; back.hidden = true;
    head.textContent = "Staff sign in";
    intro.textContent = "We will email you a " + CODE_LEN + "-digit code.";
    btn.textContent = "Email me a code";
    email.focus();
  }

  function codeStage(addr) {
    stage = "code"; otpEmail = addr;
    emailStep.hidden = true; codeStep.hidden = false; back.hidden = false;
    head.textContent = "Enter your code";
    intro.textContent = "We have emailed a " + CODE_LEN + "-digit code to " + addr +
      ". It expires in an hour. Type it here, you do not need to leave this page.";
    btn.textContent = "Sign in";
    codeIn.value = "";
    codeIn.focus();
  }

  back.addEventListener("click", () => { emailStage(); say(""); });

  /* Typing the last digit submits — saves reaching for the mouse. */
  codeIn.addEventListener("input", () => {
    codeIn.value = codeIn.value.replace(/\D/g, "").slice(0, CODE_LEN);
    if (codeIn.value.length === CODE_LEN) form.requestSubmit();
  });

  form.addEventListener("submit", async e => {
    e.preventDefault();

    if (stage === "code") {
      const code = codeIn.value.trim();
      if (code.length !== CODE_LEN) { say("The code is " + CODE_LEN + " digits.", "err"); return; }
      btn.disabled = true; say("Checking…");
      const { error } = await sb.auth.verifyOtp({ email: otpEmail, token: code, type: "email" });
      btn.disabled = false;
      if (error) { say(authError(error.code || "", error.message), "err"); codeIn.value = ""; codeIn.focus(); }
      return;
    }

    const addr = email.value.trim().toLowerCase();
    if (!addr || !/^\S+@\S+\.\S+$/.test(addr)) { say("That does not look like an email address.", "err"); return; }

    const allowed = (ALLOWED_EMAILS || []).map(a => a.trim().toLowerCase());
    if (allowed.length && !allowed.includes(addr)) {
      say("That address does not have access.", "err"); return;
    }

    btn.disabled = true; say("Sending…");
    const { error } = await sb.auth.signInWithOtp({ email: addr, options: { shouldCreateUser: false } });
    btn.disabled = false;

    if (error) {
      say(/not.*(allowed|found)|signups? not allowed/i.test(error.message)
        ? "That address does not have access."
        : "Could not send the code: " + error.message, "err");
      return;
    }
    codeStage(addr);
    say("Code sent. Check your inbox.", "ok");
  });

  const signOut = $("btnSignOut");
  if (signOut) signOut.addEventListener("click", async () => {
    await sb.auth.signOut();
    app.hidden = true; gate.hidden = false;
    emailStage(); say("You have been signed out.", "ok");
  });

  sb.auth.onAuthStateChange((_e, session) => {
    if (session) {
      gate.hidden = true; app.hidden = false;
      onReady(session);
    } else {
      gate.hidden = false; app.hidden = true;
    }
  });

  sb.auth.getSession().then(({ data: { session } }) => {
    if (session) { gate.hidden = true; app.hidden = false; onReady(session); }
    else { emailStage(); }
  });
}
