# Setting up the Production Planning board

One-off setup. Roughly 15 minutes. Everything here happens in the Supabase and
Vercel dashboards — the code side is already done.

---

## 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com) and sign in (GitHub sign-in works).
2. **New project**, then:
   - **Name:** `dj-production-planner`
   - **Region:** **London (eu-west-2)** ← this matters, see [GDPR.md §4](GDPR.md#4-where-the-data-lives)
   - **Database password:** generate a strong one and put it in your password
     manager. You will rarely need it, but it cannot be recovered — only reset.

> ⚠️ **The region cannot be changed after creation.** Getting this wrong means
> deleting the project and starting again.

Wait a couple of minutes for it to provision.

---

## 2. Create the tables

1. Left sidebar → **SQL Editor** → **New query**.
2. Open `supabase/schema.sql` from this repo, copy the whole file, paste it in.
3. **Run**.

You should see `Success. No rows returned`. Check **Table Editor** → the `jobs`
table should exist with a green **RLS enabled** badge. If that badge is missing,
stop and re-run the script — without it the data would be publicly readable.

---

## 3. Lock down sign-ups

**Authentication → Sign In / Providers → Email:**

- **Allow new users to sign up** → **OFF**
- **Confirm email** → ON

This is what stops anyone who finds the URL from creating themselves an account.

---

## 4. Create the one account

Because signups are now off, create the account manually:

**Authentication → Users → Add user → Create new user**

- Email: the workshop address (whatever you set as `ALLOWED_EMAIL`)
- **Auto Confirm User:** ✅ on
- Password: set anything — it is never used, sign-in is by emailed link

---

## 5. Tell the app where to find the project

**Project Settings → Data API**, copy:

- **Project URL** → e.g. `https://abcdefgh.supabase.co`
- **anon / public key** → the long `eyJ...` string

Paste both into `planner/config.js`, and set the email you just created:

```js
export const SUPABASE_URL      = "https://abcdefgh.supabase.co";
export const SUPABASE_ANON_KEY = "eyJhbGciOi...";
export const ALLOWED_EMAIL     = "info@davidjacksonandson.com";
```

Both values are **public and safe to commit** — row-level security is what
protects the data, not the key. The `service_role` key is the dangerous one;
never put that in this file.

---

## 6. Set the redirect URLs

The sign-in link has to know where to send you back to.

**Authentication → URL Configuration:**

- **Site URL:** `https://your-domain.co.uk`
- **Redirect URLs** — add each on its own line:
  ```
  https://your-domain.co.uk/planner/
  https://your-vercel-preview-domain.vercel.app/planner/
  http://localhost:3000/planner/
  ```

A sign-in link that isn't on this list will be rejected. This is the single
most common reason for "it says the link is invalid".

---

## 7. Email delivery

Supabase's built-in email sender is rate-limited (a handful per hour) and is
explicitly not intended for production. For one person signing in occasionally
that is usually fine.

If links start failing to arrive, connect a proper SMTP sender under
**Project Settings → Authentication → SMTP Settings** — Resend, Postmark and
Brevo all have free tiers that comfortably cover this.

---

## 8. Deploy

Push to `main` and, if the Vercel project is connected to the repo, it will
deploy automatically. The planner will be at:

```
https://your-domain.co.uk/planner/
```

---

## Checking it works

1. Open `/planner/` → you should see the sign-in card, **not** the board.
2. Enter the workshop email → "Check your inbox".
3. Click the link → the board loads, empty.
4. **+ Add job**, fill it in, save → the status pill flicks to *Saving…* then *Saved*.
5. **Hard-refresh** → the job is still there. It is now coming from Postgres, not the browser.
6. Open in a private window without signing in → you get the gate, no data.

Worth confirming #6 explicitly: it is the test that RLS is actually doing its job.

---

## If something goes wrong

| Symptom | Cause |
|---|---|
| "Email link is invalid or has expired" | The redirect URL isn't in the allow-list (§6). Links are also single-use — a mail scanner that pre-fetches links can burn one. |
| Sign-in link never arrives | Rate limit on the built-in sender, or it's in spam. See §7. |
| Board loads but stays empty, pill reads *Not saved* | Schema not run, or RLS policies missing. Re-run §2. |
| "That address doesn't have access" | The typed email doesn't match `ALLOWED_EMAIL` in `config.js`. |
| Console: `Failed to resolve module specifier` | `config.js` still has the placeholder values from §5. |
