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



Looking at this carefully, Randall is pointing out something important and the evidence is worth reading precisely before jumping to BOE.

## What the screenshot actually tells us

**Key observations:**

1. **All sessions share username `ENTITY`** — that's your Java service account, not BOE. If these were BOE, the username would be `BOADM` or similar (per the 10:34 morning discussion about Sancho's OS user query).

2. **~28+ unique Session IDs, all on the same SQL_ID `5m47gcucxjfz3`** — same query, fired from many distinct connections simultaneously.

3. **Wait Class = "Idle"** for almost every session — this is crucial. Idle means the session is **not actively executing** right now. It's holding a connection open, waiting. This is a classic connection-pool-saturation signature, not an active CPU burn.

4. **Only one session (1424, SQL_ID `atvmmwtah7zgc`) shows User I/O** — that's the actively running query. The others are queued behind it.

5. **Randall's note:** "all those session IDs are unique and they are locking one another — something is dumping in a ton of connections."

## So where are the connections coming from?

### Almost certainly NOT BOE

- BOE sessions connect under a different OS user (`BOADM`/Business Objects service account), not `ENTITY`
- `ENTITY` is the username the Java entity-service uses via its JDBC connection pool
- The morning meeting explicitly noted: *"from the application's perspective, it's just the container user"* — meaning this is entity-service/container traffic

### Most likely sources (in order of probability)

**1. The Java entity-service connection pool itself**

Per your notes, the entity-service uses HikariCP (or similar) with NamedParameterJdbcTemplate. If a high-latency query backs up, requests queue, the pool opens more connections up to `maximumPoolSize`, and each connection ends up holding a session. DevOps's proposed pool size increase (flagged in your memory as a band-aid) would make this worse, not better, under a bad query.

**2. A loop in the Java code firing per-module queries**

SQL_ID `5m47gcucxjfz3` appearing across 28+ sessions at once strongly suggests a parallel batch job or a request fan-out where each thread picks its own connection. Candidates:
- EView/MView count reconciliation running from multiple pods
- A scheduled job doing per-module rollups
- UI requests that each kick off the same backend query

**3. Multiple pods all hitting the DB simultaneously**

Morning notes: *"about a thousand of these queries running from one pod."* If multiple entity-service pods are live, each with its own pool, you multiply that.

**4. UAT traffic from Eric or automated test runs**

The 2:32 PM notes mentioned Eric running queries on the business side and other layout query tests overlapping in the same area.

### Could it still be BOE?

Only if BOE is configured to connect using the `ENTITY` service account credentials rather than its own — which would be a configuration misalignment worth checking but is unusual. Easy way to rule out: ask Christina for **`MACHINE`, `PROGRAM`, and `OSUSER`** from `v$session` for those SIDs:

```sql
SELECT sid, serial#, username, osuser, machine, program, 
       module, client_identifier, logon_time, status
FROM   v$session
WHERE  sid IN (1075, 525, 954, 829, 628, 945, 548, 942, 963, 1444);
```

- If `PROGRAM = 'JDBC Thin Client'` and `MACHINE` = an entity-service pod hostname → it's Java, not BOE
- If `PROGRAM` contains `BusinessObjects` or `boe` → BOE
- `CLIENT_IDENTIFIER` may be null (which is itself the problem — Java isn't setting it)

## How to pinpoint the exact source

**Immediate (ask Christina):**

Run the `v$session` query above. `MACHINE` will give you the pod/host, `PROGRAM` will tell you Java vs BOE vs Toad, and `LOGON_TIME` will show whether these are all fresh connections dumping in at once (suggests a burst from one caller) or gradually accumulated (suggests a slow leak).

**Short-term:**

The real operational gap here is what I flagged in the 10:34 AM technical summary — **the Java service isn't setting `CLIENT_IDENTIFIER` or `MODULE` via `DBMS_APPLICATION_INFO`**. If it did, every session would be tagged with the endpoint that initiated it, and Randall could see "these 21 sessions all came from `EViewQueueByLevelController.getByAssignment`" at a glance.

A one-line addition to the JDBC connection init or a Spring `@PostConstruct` hook:

```java
try (CallableStatement cs = conn.prepareCall(
    "{call DBMS_APPLICATION_INFO.SET_MODULE(?, ?)}")) {
    cs.setString(1, "entity-service:" + endpointName);
    cs.setString(2, requestId);
    cs.execute();
}
```

That alone would change every future incident response.

## Direct answer to your question

**Where from:** Almost certainly the entity-service Java connection pool, not BOE. The `ENTITY` username is the Java service account. 28+ sessions all running the same SQL_ID with Idle waits means a connection-pool fan-out backing up behind a slow query.

**Is it BOE:** Very unlikely, because BOE would connect as `BOADM` not `ENTITY`. But confirm by asking Christina for `PROGRAM` and `MACHINE` from `v$session` — that's the definitive check and takes her 10 seconds.

Want me to draft the `v$session` diagnostic query as a Teams message to Christina, or put together a short proposal for adding `DBMS_APPLICATION_INFO` tagging to the entity-service so this is traceable next time?
