This is the DIALMOD query Christina flagged in the 10:34 AM incident — and Randall is now showing you that it's generating **a lot of blocking sessions** on DIALMOD. Let me break down what's happening and how to handle it.

## The query

```sql
SELECT SUM(CASE WHEN RECTYPE = 5 THEN 1 ELSE 0 END),
       SUM(CASE WHEN RECTYPE = 5 THEN ROUND(BALDUE) ELSE 0 END),
       SUM(CASE WHEN RECTYPE = 5 AND MONTHS_BETWEEN(DTPER, :B2) > 0 THEN 1 ELSE 0 END),
       SUM(CASE WHEN RECTYPE = 5 AND MONTHS_BETWEEN(DTPER, :B2) > 0 THEN ROUND(BALDUE) ELSE 0 END),
       SUM(CASE WHEN RECTYPE = 0 THEN 1 ELSE 0 END)
FROM   DIALMOD
WHERE  MODSID = :B1 AND MFT = 1
```

## What's happening

This is the exact scenario flagged in the morning meeting:

1. **Missing composite index on `(MODSID, MFT)`** — DIALMOD is ~16M rows. Without a matching index, every execution does a full table scan.
2. **High concurrency** — the query runs from per-request pathways (likely per-module rollup calculations). With ~40–50 concurrent sessions, each firing a full scan, you get the row explosion Christina described (16M → 245M in the hash plan).
3. **Blocking sessions** — the blocking Randall is showing isn't classic row-lock blocking; it's **resource contention** (CPU, buffer cache, I/O latches). Oracle serializes access when too many sessions hammer the same blocks. That's why "blocking sessions" shoots up even though this is a read-only query.
4. **Likely called in a loop** — this query pattern (aggregate for one MODSID at a time) strongly suggests it's being called per-module from a parent query or Java loop. That's a classic N+1 problem.

## How to handle it

### Immediate (today, coordinate with Christina and Sam)

**1. Add the composite index — fastest win**
```sql
CREATE INDEX dialmod_modsid_mft_ix ON DIAL.DIALMOD (MODSID, MFT) ONLINE;
```
Christina already offered to create this in the morning meeting. `ONLINE` avoids locking the table during creation. This alone should drop the query from full-scan to index range scan and eliminate the blocking.

**Even better — a covering index** that also includes the columns the aggregates touch:
```sql
CREATE INDEX dialmod_modsid_mft_cov_ix 
  ON DIAL.DIALMOD (MODSID, MFT, RECTYPE, DTPER, BALDUE) ONLINE;
```
This lets Oracle answer the entire query from the index without touching the table. For a query that runs thousands of times under load, this is the highest-impact option. Discuss size impact with Christina — DIALMOD at 16M rows, a 5-column index will be significant but justified.

**2. Kill current blocking sessions and stop concurrent testing**
Per the morning decision — no further testing until the index is in place and changes are validated.

### Short-term (this week)

**3. Find where this query is being called from**
Grep the entity-service codebase for `DIALMOD` and `RECTYPE = 5` or `MONTHS_BETWEEN(DTPER`. It's likely in one of the view SQL files (MView, TView, or a per-module helper). The 5-column aggregate shape looks like a "module status summary" rollup.

**4. Check if it's being called in a loop**
If this query runs once per module from Java code (`for module in modules: query(module.id)`), the fix is structural — replace with a single set-based query that aggregates across all MODSIDs in one pass:

```sql
SELECT MODSID,
       SUM(CASE WHEN RECTYPE = 5 THEN 1 ELSE 0 END)             as cnt_rt5,
       SUM(CASE WHEN RECTYPE = 5 THEN ROUND(BALDUE) ELSE 0 END) as bal_rt5,
       SUM(CASE WHEN RECTYPE = 5 AND MONTHS_BETWEEN(DTPER, :B2) > 0 
                THEN 1 ELSE 0 END)                              as cnt_rt5_gt0,
       SUM(CASE WHEN RECTYPE = 5 AND MONTHS_BETWEEN(DTPER, :B2) > 0 
                THEN ROUND(BALDUE) ELSE 0 END)                  as bal_rt5_gt0,
       SUM(CASE WHEN RECTYPE = 0 THEN 1 ELSE 0 END)             as cnt_rt0
FROM   DIAL.DIALMOD
WHERE  MFT = 1
  AND  MODSID IN (:modsid_list)  -- or joined to parent modules
GROUP BY MODSID
```
One query, one scan, answers for all modules at once.

### Phase 2 (aligned with broader EView/MView work)

**5. If this rollup is part of view materialization**, roll it into the nightly materialized view refresh you and Ganga are planning. Pre-compute these aggregates at refresh time so runtime queries never touch 16M rows.

## Answer to "how to handle this"

**Immediate:** Ask Christina to create `DIALMOD(MODSID, MFT, RECTYPE, DTPER, BALDUE)` as an online covering index. This should resolve the blocking and CPU contention for this specific query without any code change.

**This week:** Locate the caller, confirm whether it's running in a per-module loop, and rewrite as a set-based query if so.

**Longer-term:** Fold this aggregate into the materialized view strategy you're proposing for EView.

Want me to draft the index-creation request to Christina/Sam, or help locate where this query is firing from in the entity-service repo? If you can share the Java class names that access DIAL.DIALMOD, I can help trace the call path.
