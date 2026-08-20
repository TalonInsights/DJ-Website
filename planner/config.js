/* ---------------------------------------------------------------------
   Supabase connection details.

   Both values below are PUBLIC and safe to commit. The anon key is
   designed to be shipped in a browser — it grants no access on its own,
   because every table has row-level security enabled and default-deny
   policies (see supabase/schema.sql).

   NEVER put the `service_role` key in this file, or anywhere in this
   repository. It bypasses row-level security entirely.

   Fill these in from: Supabase dashboard → Project Settings → Data API
--------------------------------------------------------------------- */

export const SUPABASE_URL      = "https://yxizdoziihvuuzmhofcs.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_3yEdmjD7lk8L0Tj6MaxfqQ_O8XZICrt";

/* Addresses allowed to reach the sign-in step.

   This is a courtesy check only — it stops a typo turning into a
   pointless email. The real enforcement is in Supabase: sign-ups are
   disabled, so an address only works if the account already exists,
   and RLS scopes every row to its owner regardless.

   An address listed here still cannot sign in until a matching user
   exists under Authentication → Users. */
/* How many digits the sign-in code has.

   Supabase lets this be 6 to 10 (Authentication → Sign In / Providers →
   Email → OTP length). This MUST match that setting: the field caps
   input at this many digits and submits automatically on the last one,
   so a mismatch silently sends a truncated code that can never verify. */
export const OTP_LENGTH = 8;

export const ALLOWED_EMAILS = [
  "talon.insights@gmail.com",      // Talon Insights — testing. Dotted form
                                   // is deliberate: Gmail ignores dots but
                                   // Resend matches literally, and its test
                                   // sender only delivers to the exact
                                   // address that owns the account.
  "info@davidjacksonandson.com"    // workshop owner — create the user before this works
];
