# Data protection — Production Planning board and Enquiry pipeline

> [!important] Updated 10 September 2026
> The enquiry pipeline (`/pipeline`) holds **substantially more personal data**
> than the scheduling board ever did, and access to both was widened from the
> creating user to all signed-in staff on the same date. Section 9 covers what
> changed and what still needs doing. The rest of this document describes the
> scheduling board and remains accurate.

Internal record for **David Jackson & Son Joinery**, covering the
staff-only production planner at `/planner/`.

> This is an engineering and record-keeping document, written to make the
> technical position clear and auditable. It is **not legal advice**. Before
> relying on it, have it reviewed by someone qualified — particularly the
> lawful basis and retention sections.

---

## 1. What personal data the board holds

The planner is deliberately narrow. It holds only:

| Field | Example | Personal data? | Why it's held |
|---|---|---|---|
| `name` | "Sash Windows — Tomas House" | No | Identifies the job |
| `ref` | "012/2026" | No | Internal job number |
| `client` | "R. Davies" | **Yes**, where the customer is an individual rather than a company | Ties the job to the customer it's for |
| `deadline` | 2026-03-14 | No | Scheduling |
| `phases[].start` / `.end` | dates | No | Scheduling |
| `phases[].who` | "George Mac" | **Yes** — a member of staff | Shows who is on each stage |
| account email | the owner's address | **Yes** | Authentication |

**Two categories of data subject: customers and employees.**

No special category data (Art. 9). No addresses, phone numbers, payment details
or customer emails — those live in the quoting side of the business and must
**not** be added to this board. The database has a `check` constraint on field
lengths but nothing stops a free-text field being misused, so this is a
discipline point, not a technical guarantee.

---

## 2. Roles

- **Controller:** David Jackson & Son Joinery — decides what is
  recorded and why.
- **Processor:** Supabase — hosts the Postgres database and the auth service.
- **Processor:** Vercel — serves the website and the planner's HTML/JS.
  Vercel never sees the schedule contents: personal data travels directly
  from the owner's browser to Supabase, not through Vercel.

Both processors require an Art. 28 contract — see the checklist in §8.

---

## 3. Lawful basis (Art. 6)

- **Customer names — Art. 6(1)(b), performance of a contract.** Scheduling the
  work is how the order gets fulfilled.
- **Staff names — Art. 6(1)(f), legitimate interests.** Allocating workshop
  labour is a normal and expected part of employment; the processing is
  minimal, non-intrusive, and staff would reasonably expect it. Record a short
  legitimate interests assessment (LIA) alongside this document.

Staff must still be **told** this processing happens (Art. 13). A line in the
staff handbook or employment privacy notice is enough — it does not need to be
elaborate, but it does need to exist.

---

## 4. Where the data lives

| Concern | Position |
|---|---|
| Database region | Supabase project **must** be created in `London (eu-west-2)`. This keeps schedule data in the UK and avoids international transfer rules entirely. |
| Region is permanent | Supabase cannot move a project between regions after creation. Getting this wrong means rebuilding the project. |
| Backups | Supabase automated backups stay in the project's region. |
| Browser storage | **No schedule data is cached in the browser.** The board reads from and writes to Postgres directly. Only the Supabase session token sits in `localStorage`, and signing out clears it. |
| Transport | HTTPS throughout, enforced by both Vercel and Supabase. |

### Two residual transfers worth knowing about

Neither carries schedule data, but both send the visitor's **IP address** to a
third party outside the UK, which is technically a processing event:

1. **Google Fonts** (`fonts.googleapis.com`) — used by the main site and the
   planner. A German court has previously found embedding Google Fonts without
   consent to be a GDPR breach. Low risk here for a single-user internal page,
   more relevant for the public site.
2. **esm.sh** — serves the Supabase JavaScript client library to the planner.

**Fix for both:** download the font files and `supabase-js` into the repo and
serve them from your own domain. Worth doing for the public site; a judgement
call for the planner. Flagged rather than silently accepted.

---

## 5. Security measures (Art. 32)

Implemented:

- **Authentication required.** No page content, and no database row, is
  reachable without signing in.
- **Row-level security, default deny.** Every table has RLS enabled and
  `force`d. Policies are scoped to `owner_id = auth.uid()`. The public anon key
  shipped in the browser therefore grants **no** read access on its own —
  which is why it is safe to commit.
- **No self-signup.** `shouldCreateUser: false` on the client, and signups
  disabled in the Supabase dashboard. A stranger with the URL cannot create an
  account.
- **Passwordless.** Magic-link sign-in means there is no password to be reused,
  phished, or found in a breach dump.
- **`service_role` key is never in the repo.** It bypasses RLS; it belongs
  only in the Supabase dashboard.
- **Search engines excluded.** `noindex, nofollow, noarchive` on the planner.

Still recommended:

- **Turn on MFA** for the Supabase dashboard login. The dashboard is the
  keys-to-the-kingdom account.
- **Review the auth logs** occasionally (Supabase → Authentication → Logs) for
  sign-in attempts you don't recognise.

---

## 6. Retention (Art. 5(1)(e))

Jobs must not sit on the board forever. `supabase/schema.sql` ships a
`purge_old_jobs(keep_months)` function that deletes jobs whose deadline passed
more than N months ago.

**Nothing calls it automatically — that is deliberate.** Pick a retention
period that matches how long you genuinely need job history (warranty claims,
repeat orders, and accounting records all pull in different directions), then
schedule it. 24 months is a reasonable starting point but is a business
decision, not a technical one.

```sql
-- run once you've settled on a period
select cron.schedule('purge-old-jobs', '0 3 1 * *', $$select public.purge_old_jobs(24)$$);
```

Note that the JSON backups produced by the **↓ Backup** button are outside all
of this. A backup file on a desktop is a copy of personal data with no
retention rule and no access control — delete old ones, and don't email them
around.

---

## 7. Handling data subject requests

| Right | How to action it |
|---|---|
| **Access** (Art. 15) | Use **↓ Backup** to export the full board as JSON, then extract the rows relating to that person. |
| **Erasure** (Art. 17) | Delete the job (🗑 on the row). This is a hard `DELETE` from Postgres, not a soft flag. It will persist in Supabase's point-in-time backups until those roll off. |
| **Rectification** (Art. 16) | Edit the job and correct the field. |
| **Objection** (Art. 21) | Relevant to staff names, since those rely on legitimate interests. Clear the `who` field to stop the processing. |

**Breaches** must be reported to the ICO within **72 hours** where there is a
risk to individuals. `ico.org.uk` — or 0303 123 1113.

---

## 8. Setup checklist

Technical work is done; these are the things only you can do:

- [ ] Create the Supabase project in the **London (eu-west-2)** region — this cannot be changed later
- [ ] Accept the **Supabase DPA** — supabase.com/legal/dpa
- [ ] Accept the **Vercel DPA** — vercel.com/legal/dpa
- [ ] Disable public signups (Authentication → Sign In / Providers → Email → *Allow new users to sign up* **off**)
- [ ] Enable **MFA** on the Supabase dashboard account
- [ ] Agree a **retention period** and schedule `purge_old_jobs`
- [ ] Add a line to the **staff privacy notice** covering scheduling data, and write a short LIA
- [ ] Publish a real **privacy policy page** on the public site — the footer currently says "Privacy Policy" as plain text with nothing behind it
- [ ] Consider **self-hosting Google Fonts** on the public site (see §4)
- [ ] Check whether the business needs to pay the **ICO data protection fee** — most businesses processing personal data electronically do; £52/year for small organisations. ico.org.uk/registration

---

## 9. The enquiry pipeline (added 10 September 2026)

### What it holds

The scheduling board holds two name fields. The enquiry pipeline holds a
customer file:

| Data | Where |
| --- | --- |
| Customer and contact name | `enquiries.customer_name`, `contact_name` |
| Phone and email | `enquiries.phone`, `email` |
| Site address and postcode | `enquiries.site_address_1/2`, `site_town`, `site_postcode` |
| Billing address | `enquiries.billing_*` |
| Property details, access notes | `enquiries.property_type`, `access_notes` |
| Quote values and outcomes | `enquiries.quote_value`, `lost_reason`, `lost_to` |
| Who did what, and when | `enquiry_events.actor`, `job_events.actor` |

`enquiry_events` and `job_events` are append-only audit logs. They record which
staff account made each change. That is staff personal data as well as an audit
trail, and it is covered by the same staff privacy notice as the board.

### Two deliberate changes that need recording

**1. Access widened from owner to workshop.** Until this date every policy on
`jobs` was scoped to `owner_id = auth.uid()`: a job belonged to one account and
was invisible to everyone else. Enquiries are workshop-wide, and `jobs` was
brought into line, because a per-user pipeline cannot produce a shared board or
a shared dashboard.

The consequence is that **any signed-in member of staff can read every
customer's name, address and phone number.** There are no roles. With two people
that is proportionate. Before a third account is created, decide whether it
should be, and if not, build the roles table.

**2. Personal data and access widened in the same change.** Both happened on the
same day. That is worth a written note in the record of processing activities
rather than leaving it to be reconstructed from commit messages.

### Lawful basis

Enquiries are handled to respond to a request from the person themselves and to
prepare a quotation, so **Art. 6(1)(b), steps prior to entering a contract**,
covers the live pipeline. Keeping lost enquiries afterwards for analysis is
**Art. 6(1)(f), legitimate interests**, and needs the short balancing note the
board's own basis already has.

### Retention

`purge_old_enquiries(keep_months)` deletes won and lost enquiries whose outcome
date is older than the period given. It defaults to 36 months and, like
`purge_old_jobs`, **nothing calls it**. Agree a period and schedule both
together:

```sql
select cron.schedule('purge-enquiries', '30 3 1 * *',
                     $$select public.purge_old_enquiries(36)$$);
```

Deleting an enquiry cascades its history away with it, so a deletion is complete.

### Subject access and erasure

An enquiry is one row plus its events. Both are reachable by reference:

```sql
select * from public.enquiries      where ref = 'DJS-2026-0042';
select * from public.enquiry_events where enquiry_id =
       (select id from public.enquiries where ref = 'DJS-2026-0042');
delete from public.enquiries        where ref = 'DJS-2026-0042';
```

Note that erasing an enquiry that became a job leaves the job, which still holds
the customer's name in `jobs.client`. Handle both.

### If the website form is ever connected

The enquiry form on the public site is currently a demo stub that sends nothing.
When it is wired up:

- it must post through a **server route holding the service key**, never an
  anonymous insert, because an anon insert policy would let anyone on the
  internet write rows;
- the form needs a **lawful-basis line beside the submit button**, not buried in
  a policy page;
- the **privacy policy page must actually exist** — the footer still links to
  one that is plain text with nothing behind it.

### Additions to the setup checklist

- [ ] Agree a **retention period for enquiries** and schedule `purge_old_enquiries`
- [ ] Decide whether a **third staff account** should see quote values, and build roles if not
- [ ] Record the **access widening of 10 Sep 2026** in the record of processing activities
- [ ] Confirm **point-in-time recovery** is available on the Supabase plan in use — not verified either way
- [ ] Extend the **staff privacy notice** to cover the audit logs

---

*Last reviewed: 10 September 2026*
