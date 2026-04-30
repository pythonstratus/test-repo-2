Here's a detailed, step-by-step test plan to confirm whether the stale-localStorage theory is the actual cause.

---

## Phase 1: Capture the current state (before doing anything)

**Step 1 — Identify the test user.**
You need a SEID that has at least two roles in ENTEMP where one is now ELEVEL=-2 and another is ELEVEL ≥ 0. Either use the SEID from Thomas's screenshot (whichever user is showing Revenue Officer 23021715 + National Analyst 85906221) or pick a SEID you can manipulate in the test DB.

**Step 2 — Confirm the DB state.**
Run this in Oracle against ENTITYDEV:

```sql
SELECT SEID, ROID, ELEVEL, EACTIVE, PRIMARY_ROID, PODCD
FROM ENTEMP
WHERE TRIM(SEID) = TRIM('<the_seid>')
ORDER BY ROID;
```

Record what you see. You're looking to confirm:
- Revenue Officer row (ROID 23021715) has ELEVEL=-2
- National Analyst row (ROID 85906221) has ELEVEL ≥ 0
- Note the EACTIVE and PRIMARY_ROID values on both rows — these tell us whether the DB is in a clean state or whether someone manually flipped ELEVEL without going through the canonical reset/activate pattern.

**Step 3 — Have the user (or you, impersonating) log into the UI.**
Use whatever auth path your test environment uses for that SEID. Get to the home page where the header is visible.

**Step 4 — Capture the header state.**
Take a screenshot. Confirm the header shows REVENUE OFFICER - Grade 11 - 23021715 (the deactivated role). This reproduces the bug.

---

## Phase 2: Inspect localStorage (the smoking gun)

**Step 5 — Open Chrome DevTools.**
Right-click the page → Inspect → Application tab → Local Storage → expand the entry for your app's origin.

**Step 6 — Find the keys.**
Look for two keys specifically:
- `entity_original_role_<seid>` — for example `entity_original_role_ABC12`
- `Selected Profile` — the permanent identity key
- Any `entity_user_context_<seid>` keys

**Step 7 — Read the values.**
Click `entity_original_role_<seid>` and look at the JSON value. Note exactly what `roid`, `name`, `title`, and `displayText` say. **This is the critical observation.**

**Three possible outcomes:**

- **(A)** The value contains `roid: 23021715` (Revenue Officer). → Stale localStorage confirmed. The frontend is reading a now-deactivated role from a key that was set when the role was still active.
- **(B)** The value contains `roid: 85906221` (National Analyst, the now-active role) but the header still shows Revenue Officer. → localStorage is fine, the bug is elsewhere — most likely the backend's `getCurrentRole` or config endpoint is returning the deactivated role.
- **(C)** The key doesn't exist. → The header is reading from `currentRole` (Redux/backend) directly, so the bug is backend.

**Step 8 — Capture the network response too.**
With DevTools still open, go to the Network tab, refresh the page, and find the call to `/role/current/<seid>` (or whatever the config endpoint is — `/role/config/<seid>` or the change-access config endpoint). Look at the response body. Note what role/ROID it returns.

Now you have two data points: what localStorage holds and what the backend is sending. Whichever is wrong is where the fix lives.

---

## Phase 3: Confirm the diagnosis with a controlled test

**Step 9 — Clear the localStorage key.**
In DevTools → Application → Local Storage, right-click `entity_original_role_<seid>` and delete it. Leave `Selected Profile` alone.

**Step 10 — Hard refresh the page** (Ctrl+Shift+R / Cmd+Shift+R).

**Step 11 — Observe the header.**
- If it now correctly shows National Analyst → **stale localStorage is confirmed as the bug.** The fix is frontend validation logic.
- If it still shows Revenue Officer → the backend is also returning the wrong role. Both layers need fixing.

**Step 12 — Open the Change Role modal.**
Click whatever opens the dialog from screenshot 2. Confirm the "Current Role" line.
- If after step 9 the modal correctly shows National Analyst → modal is reading the same localStorage path and was equally broken.
- The dropdown should still show only National Analyst as a switch target (it always did, per the screenshot).

---

## Phase 4: Test the reverse direction (regression check)

This matters because the original fix (the localStorage one) was protecting against a real bug — the Change Access flow overwriting the header with a "view as" role. We need to make sure clearing localStorage doesn't reintroduce that.

**Step 13 — With the user still logged in as National Analyst, exercise Change Access.**
Use the Change Access UI to "view as" some other territory or group. Confirm the view changes appropriately.

**Step 14 — Return to the home page and look at the header.**
- The header should still show National Analyst (the user's actual role), not the territory they were viewing.
- If it shows the territory's role, the original bug has come back — meaning the fix needs to do *both*: store an `originalRole` AND validate it on read.

**Step 15 — Reload the page after Change Access.**
Confirm the header still shows National Analyst even after a reload (the cross-remount persistence the original fix solved).

---

## Phase 5: Backend sanity check (in parallel)

While testing, also have someone hit the backend endpoint directly via Swagger or curl:

```
GET /entity/api/rbac/role/current/<seid>
GET /entity/api/rbac/role/config/<seid>
```

Confirm the response. The "current role" payload should reflect the DB's now-active row (National Analyst, ELEVEL ≥ 0), not the deactivated one. If it's wrong, that's a separate fix in `ChangeRoleService.getCurrentRole` — likely the query is missing a `elevel > -2` filter or `findCurrentActiveAssignment` is falling through to a fallback that returns the wrong row.

---

## What you'll know at the end

After Step 11 you'll know definitively whether this is:
- A frontend localStorage staleness bug (most likely),
- A backend default-role bug (Thomas's hypothesis),
- Or both.

I'd suggest running through Phases 1–3 first and pinging me with the localStorage value from Step 7 and the network response from Step 8. That'll narrow it down to one fix instead of guessing at two.

One thing to double-check before starting — for Step 2, is the DB row in a canonical state, or did someone set ELEVEL=-2 directly without resetting EACTIVE/PRIMARY_ROID? That matters because if the deactivated row still has `EACTIVE='A' AND PRIMARY_ROID='Y'`, the backend's `findCurrentActiveAssignment` query will happily return it, and we have a backend bug regardless of what localStorage says.


Here's the query to find SEIDs that match the exact test condition — at least one role at ELEVEL=-2 and at least one role at ELEVEL ≥ 0 within the same SEID.

```sql
SELECT
    TRIM(SEID) AS SEID,
    COUNT(*) AS TOTAL_ROLES,
    SUM(CASE WHEN ELEVEL = -2 THEN 1 ELSE 0 END) AS DEACTIVATED_COUNT,
    SUM(CASE WHEN ELEVEL >= 0 THEN 1 ELSE 0 END) AS ACTIVE_COUNT,
    LISTAGG(ROID || ' (ELEVEL=' || ELEVEL || ', EACTIVE=' || EACTIVE || ', PRIMARY=' || PRIMARY_ROID || ')', '; ')
        WITHIN GROUP (ORDER BY ELEVEL) AS ROLE_DETAILS
FROM ENTITYDEV.ENTEMP
WHERE TRIM(SEID) NOT IN ('88888', '99999')
GROUP BY TRIM(SEID)
HAVING SUM(CASE WHEN ELEVEL = -2 THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN ELEVEL >= 0 THEN 1 ELSE 0 END) >= 1
ORDER BY TOTAL_ROLES DESC, SEID;
```

The `LISTAGG` column is the most useful part — it lets you eyeball each candidate SEID and immediately see the EACTIVE/PRIMARY_ROID state of each role, so you can pick the cleanest test case.

**What to look for in the results:**

For the *most reproducible* test of the stale-localStorage theory, pick a SEID where:
- The ELEVEL=-2 row has `EACTIVE='Y'` and `PRIMARY_ROID='N'` (properly deactivated), AND
- The ELEVEL ≥ 0 row has `EACTIVE='A'` and `PRIMARY_ROID='Y'` (properly active).

That's the canonical state. If the user's localStorage still shows the deactivated role, the bug is purely frontend.

For testing the *messier* case (Thomas's exact screenshot scenario), pick a SEID where the ELEVEL=-2 row still has `EACTIVE='A'` or `PRIMARY_ROID='Y'`. That non-canonical state will likely also expose a backend bug, because `findCurrentActiveAssignment` doesn't filter on ELEVEL > -2 in some code paths.

**One refinement to consider:** if you specifically want SEIDs that match the screenshot pattern (a non-staff role + a staff role 859062xxxxx), add this filter to the HAVING clause:

```sql
   AND SUM(CASE WHEN TO_CHAR(ROID) LIKE '859062%' THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN TO_CHAR(ROID) NOT LIKE '859062%' THEN 1 ELSE 0 END) >= 1
```

That'll narrow you down to users like the one Thomas showed — staff users who also have a non-staff assignment. Probably your best bet for matching the exact bug report.

Want me to also draft a quick `UPDATE` script to put a test SEID into the exact non-canonical state if your dev DB doesn't have a natural example? I'd want you to confirm before running it in any shared environment.


# 3
That's `ORA-01489` — `LISTAGG` is overflowing the 4000-byte VARCHAR2 limit because some SEIDs have too many roles to concatenate into one string.

Two ways to fix it. I'd go with option 1 — it gets you the candidate list cleanly, and you can run a follow-up query to inspect role details for any specific SEID.

**Option 1 — Drop LISTAGG, then drill into a chosen SEID separately**

```sql
SELECT
    TRIM(SEID) AS SEID,
    COUNT(*) AS TOTAL_ROLES,
    SUM(CASE WHEN ELEVEL = -2 THEN 1 ELSE 0 END) AS DEACTIVATED_COUNT,
    SUM(CASE WHEN ELEVEL >= 0 THEN 1 ELSE 0 END) AS ACTIVE_COUNT
FROM ENTITY.ENTEMP
WHERE TRIM(SEID) NOT IN ('88888', '99999')
GROUP BY TRIM(SEID)
HAVING SUM(CASE WHEN ELEVEL = -2 THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN ELEVEL >= 0 THEN 1 ELSE 0 END) >= 1
ORDER BY TOTAL_ROLES DESC, SEID;
```

Then once you've picked a candidate SEID from the results, run this to see the role details:

```sql
SELECT SEID, ROID, ELEVEL, EACTIVE, PRIMARY_ROID, PODCD
FROM ENTITY.ENTEMP
WHERE TRIM(SEID) = TRIM('<paste_seid_here>')
ORDER BY ELEVEL, ROID;
```

**Option 2 — Truncate LISTAGG with `ON OVERFLOW TRUNCATE` (Oracle 12.2+)**

If you really want it all in one query:

```sql
LISTAGG(ROID || ' (E=' || ELEVEL || ',A=' || EACTIVE || ',P=' || PRIMARY_ROID || ')', '; '
        ON OVERFLOW TRUNCATE '...' WITH COUNT)
    WITHIN GROUP (ORDER BY ELEVEL) AS ROLE_DETAILS
```

This won't error — it'll truncate long strings and append `...(N more)` so you still know there are more rows.

**Also — I noticed your screenshot shows `FROM ENTITY.ENTEMP`** but the schema we've been using is `ENTITYDEV`. Worth double-checking that's the right schema for your environment, or it might be returning data you don't expect.

To narrow further to staff + non-staff combos like Thomas's screenshot:

```sql
HAVING SUM(CASE WHEN ELEVEL = -2 THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN ELEVEL >= 0 THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN TO_CHAR(ROID) LIKE '859062%' THEN 1 ELSE 0 END) >= 1
   AND SUM(CASE WHEN TO_CHAR(ROID) NOT LIKE '859062%' THEN 1 ELSE 0 END) >= 1
```
