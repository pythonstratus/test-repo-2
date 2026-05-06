-- =============================================================================
-- MV_AVIEW_MODERN — Validation harness
-- =============================================================================
-- Purpose: prove (or disprove) that mv_aview_modern returns the same rows as
--          the legacy modern_aview query for a representative set of bind
--          parameter combinations. Run this BEFORE switching any consumer
--          over to the MV.
--
-- Usage:
--   1. Pick representative bind values (org / elevel / levelValue /
--      daysUpperLimit). Use real values your application sends.
--   2. Replace &org &elevel &levelValue &daysUpperLimit substitution
--      variables. SQL*Plus will prompt; SQL Developer treats them as binds.
--   3. Run each section. Each comparison should return ZERO rows.
--   4. Repeat across at least: 3 distinct orgs, 2 elevel values, edge ACTDTs.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- SECTION 1: Row count parity
-- -----------------------------------------------------------------------------
-- Both counts MUST match exactly. A single-row delta indicates a join
-- semantics regression; large deltas indicate the seg_match logic differs.

PROMPT === Row count: legacy query ===
SELECT COUNT(*) AS legacy_rowcount
FROM (
    -- >>> PASTE THE LEGACY modern_aview QUERY HERE, with binds applied <<<
    -- It must use the same bind values as the MV-side query below.
    SELECT *
    FROM ( /* paste the original SELECT-FROM-WHERE here */ )
);

PROMPT === Row count: MV ===
SELECT COUNT(*) AS mv_rowcount
FROM mv_aview_modern
WHERE B_ORG = '&org'
  AND TRUNC(ROID / POWER(10, 8 - &elevel)) = &levelValue
  AND TRUNC(SYSDATE) - ACTDT <= &daysUpperLimit;


-- -----------------------------------------------------------------------------
-- SECTION 2: Symmetric difference (key columns only)
-- -----------------------------------------------------------------------------
-- Compares the natural key (TINSID, ROID, AROID, MFT, PERIOD) between the two.
-- Any row here means a join produced a different set of rows. MUST be empty.

PROMPT === Rows in legacy but not in MV (key-level) ===
SELECT TINSID, ROID, AROID, MFT, PERIOD FROM (
    /* legacy query, same as Section 1 */
) legacy
MINUS
SELECT TINSID, ROID, AROID, MFT, PERIOD FROM mv_aview_modern
 WHERE B_ORG = '&org'
   AND TRUNC(ROID / POWER(10, 8 - &elevel)) = &levelValue
   AND TRUNC(SYSDATE) - ACTDT <= &daysUpperLimit;

PROMPT === Rows in MV but not in legacy (key-level) ===
SELECT TINSID, ROID, AROID, MFT, PERIOD FROM mv_aview_modern
 WHERE B_ORG = '&org'
   AND TRUNC(ROID / POWER(10, 8 - &elevel)) = &levelValue
   AND TRUNC(SYSDATE) - ACTDT <= &daysUpperLimit
MINUS
SELECT TINSID, ROID, AROID, MFT, PERIOD FROM (
    /* legacy query */
) legacy;


-- -----------------------------------------------------------------------------
-- SECTION 3: Per-column value parity for the rewrites I'm least confident about
-- -----------------------------------------------------------------------------
-- For every shared key, compare the columns I rewrote (STATUS, ASSNRO) plus
-- a few that flow through derived joins (TDACNT, TDICNT, NAICSCD). Any row
-- here means values differ for the same logical record. MUST be empty.

PROMPT === STATUS / ASSNRO column-value diffs ===
WITH
legacy AS (
    /* legacy query */
    SELECT TINSID, ROID, AROID, MFT, PERIOD,
           STATUS, ASSNRO, TDACNT, TDICNT, NAICSCD
      FROM ( /* paste */ )
),
mv AS (
    SELECT TINSID, ROID, AROID, MFT, PERIOD,
           STATUS, ASSNRO, TDACNT, TDICNT, NAICSCD
      FROM mv_aview_modern
     WHERE B_ORG = '&org'
       AND TRUNC(ROID / POWER(10, 8 - &elevel)) = &levelValue
       AND TRUNC(SYSDATE) - ACTDT <= &daysUpperLimit
)
SELECT 'LEG' AS src, l.* FROM legacy l
JOIN mv m USING (TINSID, ROID, AROID, MFT, PERIOD)
WHERE LNNVL(l.STATUS  = m.STATUS)
   OR LNNVL(l.ASSNRO  = m.ASSNRO)
   OR LNNVL(l.TDACNT  = m.TDACNT)
   OR LNNVL(l.TDICNT  = m.TDICNT)
   OR LNNVL(l.NAICSCD = m.NAICSCD)
UNION ALL
SELECT 'MV', m.* FROM legacy l
JOIN mv m USING (TINSID, ROID, AROID, MFT, PERIOD)
WHERE LNNVL(l.STATUS  = m.STATUS)
   OR LNNVL(l.ASSNRO  = m.ASSNRO)
   OR LNNVL(l.TDACNT  = m.TDACNT)
   OR LNNVL(l.TDICNT  = m.TDICNT)
   OR LNNVL(l.NAICSCD = m.NAICSCD)
ORDER BY TINSID, ROID, AROID, MFT, PERIOD, src;
-- LNNVL handles NULL-safe comparison: LNNVL(x = y) is TRUE when they differ
-- including the case where one is NULL and the other is not.


-- -----------------------------------------------------------------------------
-- SECTION 4: Spot-check the legacy STATUS edge case
-- -----------------------------------------------------------------------------
-- Find (tinsid, roid) pairs where multiple TRANTRAIL rows share the max
-- EXTRDT but have different segind. This is the exact scenario where the
-- LEGACY behavior may differ from a naive segind-filter rewrite. If the
-- count is non-zero, the v2 STATUS rewrite (which preserves the legacy
-- behavior) is genuinely needed.

PROMPT === Legacy STATUS edge case incidence ===
WITH per_seg_max AS (
    SELECT TINSID, ROID,
           DECODE(segind, 'A',1,'C',1,'I',1,0) AS seg_match,
           MAX(EXTRDT) AS max_extrdt
      FROM TRANTRAIL
     GROUP BY TINSID, ROID, DECODE(segind, 'A',1,'C',1,'I',1,0)
)
SELECT COUNT(*) AS edge_case_rows
  FROM TRANTRAIL c2
  JOIN per_seg_max m
    ON m.TINSID = c2.TINSID AND m.ROID = c2.ROID
   AND m.max_extrdt = c2.EXTRDT
   AND DECODE(c2.segind, 'A',1,'C',1,'I',1,0) <> m.seg_match;
-- If 0: the simpler v1 STATUS rewrite would have been equivalent for your
--       data.
-- If >0: the v2 rewrite is necessary; v1 would have produced different
--        STATUS values for these rows.


-- -----------------------------------------------------------------------------
-- SECTION 5: Refresh-staleness simulation
-- -----------------------------------------------------------------------------
-- Confirms that querying the MV with a query-time TRUNC(SYSDATE) - ACTDT
-- predicate produces the same record set the legacy SYSDATE - a.actdt would
-- have at refresh time. Run this ~6 hours after refresh; expect identical
-- counts (the day-bucket should be stable across the day).

PROMPT === Same-day staleness sanity ===
SELECT TRUNC(SYSDATE) - ACTDT AS day_bucket, COUNT(*)
  FROM mv_aview_modern
 WHERE B_ORG = '&org'
   AND TRUNC(SYSDATE) - ACTDT <= &daysUpperLimit
 GROUP BY TRUNC(SYSDATE) - ACTDT
 ORDER BY day_bucket;


-- =============================================================================
-- Recommended pre-cutover checklist
-- =============================================================================
-- [ ] Section 1 row counts match for >= 5 representative bind sets
-- [ ] Section 2 returns 0 rows for every bind set
-- [ ] Section 3 returns 0 rows for every bind set
-- [ ] Section 4 documented (does the edge case exist in your data? how often?)
-- [ ] Refresh job runs end-to-end within the maintenance window
-- [ ] Application updated to push removed binds as query predicates
-- [ ] Index plan reviewed against EXPLAIN PLAN of representative queries
-- [ ] Stakeholders signed off on intra-day staleness (up to 12h)
-- =============================================================================
