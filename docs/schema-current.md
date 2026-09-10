# Current state — schema, auth and production model

Phase 0 audit for the Enquiry Pipeline & Analytics Dashboard plan.
Audited 10 September 2026 against `main` at `61f4d96` and the live Supabase
project `yxizdoziihvuuzmhofcs` (London, eu-west-2).

Companion document: [gaps.md](gaps.md).

---

## 1. The repository is not what the plan assumes

The plan's header reads *"Stack: Next.js (App Router) · TypeScript · Tailwind ·
Supabase · Vercel. Repo: existing DJS production scheduling tool."*

None of the front-end half of that is present. There is no second repository;
the production planner lives inside this one.

| Plan assumes | Actually here |
| --- | --- |
| Next.js App Router | No framework. Static HTML served by Vercel |
| TypeScript | None. Plain ES2015+ JavaScript |
| Tailwind | None. Hand-written CSS using custom properties |
| npm toolchain | No `package.json`, no `node_modules`, no dependencies |
| Server components / server actions | No server runtime at all |
| Shared UI primitives | None. Every control is bespoke CSS |

What exists:

```
src/index.html          the marketing site source (14 pages in one file)
build.js                prerenders one static .html per route + sitemap
*.html                  14 generated route documents, committed
planner/index.html      the production planner — its own document, 656 lines
planner/planner.js      the whole planner — one ES module, 893 lines, no build
planner/config.js       Supabase URL, publishable key, OTP length, allowlist
supabase/schema.sql     the entire database definition, 1 table
```

`build.js` is run by hand (`node build.js`) using the system Node. It has no
dependencies. Vercel serves the committed output; it does not run a build.

**Consequence.** Phases 4, 5 and 6 of the plan cannot be executed as written.
`supabase gen types typescript`, Zod schemas, server actions, React components
and Recharts all presuppose a toolchain that would have to be introduced first.
That is a decision for Talon, not an implementation detail — see
[gaps.md §6](gaps.md).

---

## 2. Database

One table. The whole schema is `supabase/schema.sql`, reproduced in summary.

### `public.jobs`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK, `default gen_random_uuid()` |
| `owner_id` | `uuid` | `not null default auth.uid()`, FK → `auth.users(id)` on delete cascade |
| `ref` | `text` | free text, **not unique, not generated** |
| `name` | `text` | `not null`, `check (length between 1 and 200)` |
| `client` | `text` | `check (length <= 200)`. Personal data |
| `deadline` | `date` | see §4 — meaning is ambiguous |
| `phases` | `jsonb` | `not null default '[]'`, `check (jsonb_typeof = 'array')` |
| `created_at` | `timestamptz` | `not null default now()` |
| `updated_at` | `timestamptz` | `not null default now()`, maintained by trigger |

**Indexes:** `(owner_id, deadline)` and `(owner_id, updated_at desc)`.

**Trigger:** `jobs_touch_updated_at` — `before update`, sets `updated_at = now()`.

**Function:** `purge_old_jobs(keep_months int default 24)` — `security definer`,
deletes jobs whose `deadline` passed more than `keep_months` ago. Execute is
revoked from `public`, `anon` and `authenticated`; nothing calls it
automatically. It exists to satisfy UK GDPR Art. 5(1)(e) once a retention
period is agreed.

There is no tasks table, no stages table, no customers table, no staff table
and no capacity table. There are no views and no materialised views.

### Verified against the live project

The live database agrees with `schema.sql`. Introspected 10 Sep 2026:

```
GET  /rest/v1/            → no table definitions exposed to anon
GET  /rest/v1/jobs        → 200 []          (RLS filters every row)
POST /rest/v1/jobs        → 42501 "new row violates row-level security policy"
```

Nothing was written by the probe. The empty `SELECT` on its own would prove
nothing; the rejected `INSERT` is what demonstrates the policy actually denies.

---

## 3. Auth and row-level security

**Identity.** Supabase email OTP. `signInWithOtp` then `verifyOtp` with
`type: "email"`, 8-digit codes, `shouldCreateUser: false`. Sign-ups are disabled
in the project, so an address only works if the user already exists. SMTP is
Gmail. `planner/config.js` carries a courtesy allowlist (`ALLOWED_EMAILS`) that
stops a typo becoming a pointless email; it is not a security control.

**Roles.** There are none. No `role` column, no claims, no `user_roles` table.
Every authenticated user is equivalent.

**The RLS pattern — and why it blocks the plan.** All four policies are scoped
to the row owner:

```sql
alter table public.jobs enable row level security;
alter table public.jobs force row level security;

create policy jobs_select_own on public.jobs
  for select to authenticated
  using (owner_id = (select auth.uid()));
-- insert / update / delete follow the same shape
```

This is a **single-tenant, per-user** model. A job belongs to exactly one user
and is invisible to every other account. It was written on the assumption,
correct at the time, that only Harry would ever sign in.

The plan says, of RLS: *"Match the pattern found in Phase 0. Baseline:
authenticated staff can select and modify all rows."*

Those two sentences contradict each other here. The pattern found is
owner-scoped; the baseline requested is shared-visibility. Matching the existing
pattern would give each member of staff their own private pipeline and their own
private dashboard, which is not a dashboard. This needs resolving before
Phase 1 — see [gaps.md §5](gaps.md).

---

## 4. How the Gantt actually models work

**Unit of work: whole calendar days.** Not hours, not benches, not units. Every
stage is a `start` date and an `end` date. Nothing anywhere in the system is
expressed in hours.

**Stages are JSONB inside the job**, not rows. `phases` is an array of:

```json
{ "key": "assembly", "start": "2026-09-14", "end": "2026-09-18", "who": "Harry" }
```

Eight fixed stage keys, defined as a JavaScript constant in `planner.js`
(lines 39–48), not in the database:

| key | Name | Default days |
| --- | --- | --- |
| `timber` | Timber Matching | 3 |
| `assembly` | Assembly | 5 |
| `sanding` | Sanding | 2 |
| `hardware` | Fitting Hardware | 2 |
| `prep` | Final Prep | 2 |
| `spray` | Spray Finishing | 3 |
| `glazing` | Glazing | 2 |
| `dispatch` | Dispatch | 1 |

Those default durations are the closest thing to an estimate the system holds,
and they are hard-coded per stage rather than per product, per job or per unit.

**`who` is free text.** A text input backed by a `<datalist>` assembled from
names already used on other jobs. There is no staff table, no identity link, no
availability and no cost. Two spellings of the same person are two people.

**Planned dates are mutated in place.** Dragging or resizing a bar rewrites
`phases[].start` / `phases[].end` and the whole job is upserted after a debounce
(`sb.from("jobs").upsert(...)`). The previous values are overwritten and are not
recorded anywhere.

**Derived values** (`planner.js` lines 326–333):

```js
projStart(p)  = min(phases[].start)
projEnd(p)    = max(phases[].end)
breached(p)   = phases.length > 0 && deadline && projEnd(p) > deadline
```

`breached` drives the "Past deadline" counter in the header.

### `deadline` means two different things

When the deadline field is left blank on save, the planner fills it in
(lines 733–736):

```js
if (!deadline) {
  deadline = max(phases[].end);
  deadline = workSpan(nextWork(addD(deadline, 1)), 1);   // one working day later
}
```

So `deadline` is sometimes a real customer promise and sometimes an artefact
derived from the plan itself, with no flag distinguishing the two. For an
auto-filled job, `breached()` is false by construction at the moment of saving,
because the deadline was computed from the plan it is being compared against.

Any "delivered late" metric built on today's `deadline` column would be
measuring a mixture of a promise and an echo of the plan. This matters directly
to the plan's `v_promise_vs_delivery` view.

---

## 5. What is captured about a job, in full

Everything the database knows about a job today:

- who owns it (`owner_id`)
- a free-text reference, a name, a client name
- one date called `deadline`, of ambiguous provenance
- for each of up to eight stages: a start date, an end date, a staff name
- when the row was created and last touched

That is the complete list.

---

## 6. Front-end conventions to match, if building inside the planner

Should the enquiry UI be built as part of the existing planner rather than a new
app, these are the conventions in place:

- **Design tokens** as CSS custom properties on `:root`. The planner shares the
  marketing site's palette: `--ink #171A18`, `--slate #59635D`, `--green #2F4739`,
  `--brass #A9803B`, `--paper #FCFBF9`, `--sage #EAEDE6`, plus `--p1`–`--p8`
  for the eight stage colours.
- **Type:** Newsreader (display, weight 300) and Archivo (body).
- **Controls:** pill buttons at `border-radius: 100px`, 44px minimum touch target.
- **No component library, no framework, no build step.** One ES module,
  `<script type="module" src="/planner/planner.js">`, root-absolute.
- **Security headers** for `/planner` are set in `vercel.json`: `X-Frame-Options:
  DENY`, `X-Robots-Tag: noindex`, `Cache-Control: no-store`, and a CSP whose
  `script-src` is `'self' https://esm.sh` — any new dependency must come from
  `esm.sh` or the CSP has to change.
- `robots.txt` disallows `/planner/`.

---

## 7. Files consulted

`supabase/schema.sql` · `planner/planner.js` · `planner/config.js` ·
`planner/index.html` · `vercel.json` · `robots.txt` · `docs/GDPR.md` ·
`docs/SETUP.md` · live REST introspection of project `yxizdoziihvuuzmhofcs`.
