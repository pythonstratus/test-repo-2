Short answer: **yes, you can keep PARALLEL, but only if you fix the syntax and understand it won't help much on a TINSID lookup.** Let me give you both versions so you and Manoj can decide.

## Why the current hint is broken

```
/*+ PARALLEL(16) /*+ index(trantrail, trantrail_tinsid_ix) */
```

Oracle doesn't allow nested comment blocks. The parser sees `/*+ PARALLEL(16) /*+ index(...)` as **one** comment that closes at the first `*/`. Result: at best only PARALLEL is honored; at worst **both hints are dropped silently** and the optimizer picks its own plan. Also, `INDEX(trantrail, trantrail_tinsid_ix)` with a comma is wrong syntax — INDEX hint takes table and index separated by space, not comma.

## Option A — Keep PARALLEL (fixed syntax)

```sql
SELECT /*+ PARALLEL(trantrail 16) INDEX(trantrail trantrail_tinsid_ix) */
       ROWID,
       CASE WHEN ROID = :B2 THEN 1 ELSE 2 END,
       DECODE(STATUS, 'O', 1, 'C', 2, 'T', 2, 'R', 3, 4),
       STATUS,
       ROID,
       NVL(ASSNFLD, TO_DATE('01/01/1900', 'mm/dd/yyyy')),
       NVL(ASSNRO,  TO_DATE('01/01/1900', 'mm/dd/yyyy')),
       NVL(CLOSEDT, TO_DATE('01/01/1900', 'mm/dd/yyyy')),
       EXTRDT
FROM   TRANTRAIL
WHERE  TINSID = :B1
  AND  ORG IN ('CF', 'CP', 'AD')
  AND  STATUS = :B3;
```

**Caveats if you keep PARALLEL:**

1. **PARALLEL and INDEX hints conflict.** The optimizer usually discards one when both are present. On Exadata, PARALLEL strongly biases toward full table scan with smart scan offload. You may find the INDEX hint is ignored even with correct syntax.

2. **For `TINSID = :B1`, PARALLEL is the wrong tool.** TINSID is an equality predicate on an indexed column — this should return a small rowset via index range scan in milliseconds, serially. Spinning up 16 parallel slaves adds coordination overhead that exceeds the work itself. This is likely *why* the DBA sees 99% CPU.

3. **PARALLEL(16) on TRANTRAIL will trigger a full scan** if the optimizer picks the parallel path. TRANTRAIL is a large table. A parallel full scan under concurrent load from a Java connection pool is how you melt Exadata.

## Option B — Drop PARALLEL (what I'd actually recommend)

```sql
SELECT /*+ INDEX(trantrail trantrail_tinsid_ix) */
       ROWID,
       CASE WHEN ROID = :B2 THEN 1 ELSE 2 END,
       DECODE(STATUS, 'O', 1, 'C', 2, 'T', 2, 'R', 3, 4),
       STATUS,
       ROID,
       NVL(ASSNFLD, TO_DATE('01/01/1900', 'mm/dd/yyyy')),
       NVL(ASSNRO,  TO_DATE('01/01/1900', 'mm/dd/yyyy')),
       NVL(CLOSEDT, TO_DATE('01/01/1900', 'mm/dd/yyyy')),
       EXTRDT
FROM   TRANTRAIL
WHERE  TINSID = :B1
  AND  ORG IN ('CF', 'CP', 'AD')
  AND  STATUS = :B3;
```

This is the shape the legacy blue screen effectively runs — narrow index lookup on TINSID, filter in-memory on ORG and STATUS. On Exadata with `trantrail_tinsid_ix` it should be sub-second per execution.

## When PARALLEL *is* appropriate here

Per your own notes on this codebase: **"only apply parallel hints on confirmed full-scan branches after reviewing EXPLAIN PLAN."** PARALLEL earns its keep when:

- The predicate is non-selective (e.g., scanning all ORG='CF' across the table)
- You've confirmed via `EXPLAIN PLAN` that a full scan is unavoidable
- The query runs from a batch/reporting context, not a per-request web service call

None of those apply to a `TINSID = :B1` lookup from a Java service pool.

## My recommendation for the immediate crisis

1. Deploy **Option B** (no PARALLEL) — this will drop CPU immediately.
2. Have Ganga pull the execution plan from `v$sql` for the current SQL_ID to confirm the parallel full scan theory.
3. If there's a legitimate reporting-style caller that *does* need PARALLEL, fork it into a separate query path rather than hinting the hot-path lookup.

Want me to put together the before/after `EXPLAIN PLAN` commands so Ganga can confirm the plan change before Manoj deploys?

```
Subject: Query Performance — Summary of Approach

Hi all,

Following today's discussions, here is a short summary of the approach Ganga and I are aligning on to address the recent query performance concerns.

Immediate fixes
- Correct the index hint syntax across queries where commas are used inside INDEX() hints — these were carried over from the legacy LS scripts and are not being honored as intended.
- Remove PARALLEL hints from per-request queries where they are not appropriate.
- Add the missing composite index on DIALMOD (MODSID) to eliminate the full-scan behavior observed under load.
- Audit the EView / MView / AView / TView SQL files for the same hint and index patterns, since the issues appear in more than one place.

Short-term approach
- EView is currently returning matching counts and performing well. The proposal is to convert EView into a materialized view, refreshed nightly, and use it as the foundation for level-based queries.
- MView requires additional work before it can follow the same path; we will continue reconciling counts first.
- AView and TView are performing well in their current form.

Next steps
- Ganga and I will take the lead on the EView materialized view conversion and the index/hint cleanup.
- We will share one or two working examples before expanding the approach more broadly.
- Manoj will handle deployment once the changes are validated.

Happy to discuss further in tomorrow's sync.

Thanks,
Santosh

```
