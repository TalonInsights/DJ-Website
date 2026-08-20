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

export const SUPABASE_URL      = "https://YOUR-PROJECT-REF.supabase.co";
export const SUPABASE_ANON_KEY = "YOUR-PUBLISHABLE-ANON-KEY";

/* The single address allowed to sign in. The real enforcement is in
   Supabase (signups disabled + RLS), this just gives a clearer message
   at the login box before a pointless email is sent. */
export const ALLOWED_EMAIL = "info@davidjacksonandson.com";
