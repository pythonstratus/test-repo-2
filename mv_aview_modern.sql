-- =============================================================================
-- MATERIALIZED VIEW: MV_AVIEW_MODERN
-- =============================================================================
-- Strategy: COMPLETE refresh, ON DEMAND, scheduled twice daily (06:00 / 18:00).
--
-- Why COMPLETE (not FAST):
--   - Analytic ROW_NUMBER(), correlated subqueries, outer joins with (+),
--     pipelined TABLE(mft_ind_vals(...)), and PL/SQL functions (GETASSNQUE,
--     STATIND, ASSNPICKDT, ASSNQPICK, INTLQPICK, duedt) all violate FAST
--     refresh restrictions. COMPLETE rebuilds the full result each run, so
--     none of those rules apply.
--
-- Transformations from the original query:
--   1. Bind variables removed:
--        :org              -> partitioned into MV (b_org column); filter at query time
--                             OR build one MV per org (see Option B at bottom).
--        :elevel/:levelValue -> removed; apply TRUNC(a.roid / POWER(10, 8-N)) = M
--                               at query time against a.roid (kept as ROID column).
--        :daysUpperLimit   -> removed; filter on ACTDT at query time.
--   2. SYSDATE - a.actdt filter removed (non-deterministic). Query-time
--      predicate on ACTDT replaces it.
--   3. Inner b subquery now PARTITIONs BY (TINSID, ORG) instead of TINSID
--      alone, so we keep the "latest TRANTRAIL per TINSID" semantics for
--      every org rather than for one bound org.
--   4. b.ORG exposed as a column (B_ORG) for query-time filtering.
--   5. ROID and ACTDT exposed at the top level for partition pruning /
--      index-driven query-time filters.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Drop existing (run only when rebuilding from scratch)
-- -----------------------------------------------------------------------------
-- DROP MATERIALIZED VIEW mv_aview_modern;

-- -----------------------------------------------------------------------------
-- Materialized view definition
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_aview_modern
    PCTFREE 0
    NOLOGGING
    PARALLEL 8
    BUILD IMMEDIATE
    REFRESH COMPLETE
    ON DEMAND
    -- ENABLE QUERY REWRITE      -- uncomment if you want optimizer to auto-substitute
AS
SELECT
    a.ROID                                                   AS ROID,
    a.TIN                                                    AS TIN,
    a.TINTT                                                  AS TINTT,
    a.TINFS                                                  AS TINFS,
    a.ACTSID                                                 AS TINSID,
    DECODE(e.TPCTRL, 'E3', ' ', 'E7', ' ', e.tpctrl)         AS TPCTRL,
    SUBSTR(e.TP,     1, 35)                                  AS TP,
    SUBSTR(e.TP2,    1, 35)                                  AS TP2,
    SUBSTR(e.STREET, 1, 35)                                  AS STREET,
    e.CITY                                                   AS CITY,
    e.STATE                                                  AS STATE,
    (CASE
        WHEN e.zipcde < 100000
            THEN TO_NUMBER(TO_CHAR(e.ZIPCDE, '09999'))
        WHEN e.zipcde BETWEEN 99999 AND 999999999
            THEN NVL(TO_NUMBER(SUBSTR(TO_CHAR(e.ZIPCDE, '099999999'),  -9, 5)), 0)
        ELSE
             NVL(TO_NUMBER(SUBSTR(TO_CHAR(e.ZIPCDE, '099999999999'), -12, 5)), 0)
    END)                                                     AS ZIPCDE,
    a.ACTDT                                                  AS ACTDT,
    a.CODE                                                   AS CASECODE,
    a.SUBCODE                                                AS SUBCODE,
    -- STATUS: correlated subquery with NVL default 'P' (LEGACY MATCH)
    NVL(
        (SELECT status
           FROM (SELECT c2.status,
                        ROW_NUMBER() OVER (ORDER BY c2.EXTRDT DESC, c2.ROWID) AS rn
                   FROM TRANTRAIL c2
                  WHERE c2.tinsid = a.actsid
                    AND c2.roid   = a.roid
                    AND c2.EXTRDT = (
                            SELECT /*+ index(d, trantrail_tinsid_ix) */
                                   NVL(MAX(d.EXTRDT),
                                       TO_DATE('01/01/1900', 'mm/dd/yyyy'))
                              FROM TRANTRAIL d
                             WHERE d.TINSID = c2.TINSID
                               AND d.ROID   = c2.ROID
                               AND DECODE(d.segind, 'A', 1, 'C', 1, 'I', 1, 0)
                                 = DECODE(mft, 0, 0, 1)
                        )
                )
          WHERE rn = 1),
        'P')                                                 AS STATUS,
    e.LDIND                                                  AS LDIND,
    e.RISK                                                   AS RISK,
    MFT                                                      AS MFT,
    a.PERIOD                                                 AS PERIOD,
    TYPCD                                                    AS M_TYPE,
    a.AROID                                                  AS AROID,
    -- ASSNRO: correlated subquery (LEGACY MATCH)
    (SELECT MAX(t2.ASSNRO)
       FROM TRANTRAIL t2
      WHERE (t2.roid = a.aroid OR t2.roid = a.roid)
        AND t2.tinsid = a.actsid
        AND DECODE(t2.segind, 'A', 1, 'C', 1, 'I', 1, 0)
          = DECODE(mft, 0, 0, 1))                            AS ASSNRO,
    e.ASSNCFF                                                AS ASSNCFF,
    BODCD                                                    AS BODCD,
    AMOUNT                                                   AS AMOUNT,
    RTNSEC                                                   AS RTNSEC,
    DISPCODE                                                 AS DISPCD,
    GRPIND                                                   AS GRPIND,
    FORM809                                                  AS FORM809,
    RPTCD                                                    AS RPTCD,
    a.CC                                                     AS CC,
    TC                                                       AS TC,
    a.EXTRDT                                                 AS EXTRDT,
    a.TYPEID                                                 AS TYPEID,
    a.TSACTCD                                                AS TSACTCD,
    TOTASSD                                                  AS TOTASSD,
    BAL_941_14                                               AS BAL_941_14,
    e.GRADE                                                  AS CASEGRADE,
    CASEIND                                                  AS CASEIND,
    NVL(b.NAICSCD, ' ')                                      AS NAICSCD,
    PRGNAME1                                                 AS PRGNAME1,
    PRGNAME2                                                 AS PRGNAME2,
    CCNIPSELECTCD                                            AS CCNIPSELECTCD,
    CNT_941_14                                               AS CNT_941_14,
    CNT_941                                                  AS CNT_941,
    TDI_CNT_941                                              AS TDI_CNT_941,
    NVL(b.TDAcnt, 0)                                         AS TDACNT,
    NVL(b.TDIcnt, 0)                                         AS TDICNT,
    NVL((b.TDAcnt + b.TDIcnt), 0)                            AS MODCNT,
    DECODE(NVL(b.STATUS, 'X'), 'O', STATIND(a.ACTSID), 0)    AS STATIND,
    b.ASSNFLD                                                AS ASSNFLD,
    (CASE
        WHEN NVL(b.segind, ' ') IN ('A','C','I')
            THEN GETASSNQUE(e.TIN, e.TINTT, e.TINFS, e.ASSNCFF, b.ASSNRO)
        ELSE b.ASSNRO
    END)                                                     AS ASSNQUE,
    NVL(
        DECODE(NVL(b.status, ' '),
               'C', b.CLOSEDT,
               'X', b.CLOSEDT,
               TO_DATE('01/01/1900', 'mm/dd/yyyy')),
        TO_DATE('01/01/1900', 'mm/dd/yyyy'))                 AS CLOSEDT,
    NVL(DT_DOD, TO_DATE('01/01/1900', 'mm/dd/yyyy'))         AS DT_DOD,
    b.XXDT                                                   AS XXDT,
    b.INITDT                                                 AS INITDT,
    DT_OA                                                    AS DT_OA,
    DT_POA                                                   AS DT_POA,
    TRUNC(ASSNPICKDT(e.TIN, e.TINFS, e.TINTT,
                     NVL(b.STATUS, 'P'),
                     NVL(b.PROID, 0),
                     a.ROID))                                AS PICKDT,
    DVICTCD                                                  AS DVICTCD,
    DECODE(DECODE(NVL(b.ZIPCDE, 0), 00000,
            ASSNQPICK(e.TIN, e.TINFS, e.TINTT,
                      INTLQPICK(e.TIN, e.TINFS, e.TINTT, NVL(b.STATUS, 'P'))),
            DECODE(e.CITY, 'APO',
                ASSNQPICK(e.TIN, e.TINFS, e.TINTT,
                          INTLQPICK(e.TIN, e.TINFS, e.TINTT, NVL(b.STATUS, 'P'))),
                'FPO',
                ASSNQPICK(e.TIN, e.TINFS, e.TINTT,
                          INTLQPICK(e.TIN, e.TINFS, e.TINTT, NVL(b.STATUS, 'P'))),
                ASSNQPICK(e.TIN, e.TINFS, e.TINTT, NVL(b.PROID, 0)))),
        '', 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, '?')
                                                             AS QPICKIND,
    NVL(b.FLDHRS, 0)                                         AS FLDHRS,
    NVL(b.EMPHRS, 0)                                         AS EMPHRS,
    NVL(b.HRS, 0)                                            AS HRS,
    (CASE
        WHEN NVL(b.ORG, ' ') = 'CP' THEN CCPHRS
        ELSE GREATEST(NVL(TOTHRS, 0), NVL(b.EMPHRS, 0))
    END)                                                     AS TOTHRS,
    c.IND_941                                                AS IND_941,
    (CASE WHEN c.ind_941 = 0 THEN 'No' ELSE 'Yes' END)       AS FORMATTED_IND_941,
    HINFIND                                                  AS HINFIND,
    DECODE(NVL(b.segind, ' '),
           'A', AGEIND, 'C', AGEIND, 'I', AGEIND, 'C')       AS AGEIND,
    TO_NUMBER(PDTIND)                                        AS CAUIND,
    DECODE(
        NVL(b.STATUS, 'X'),
        'O', (CASE
                WHEN DECODE(NVL(b.SEGIND, ' '), 'C', 1, 'A', 1, 'I', 1, 0) = 1
                 AND DECODE(e.casecode, '201', 1, '301', 1, '401', 1, '601', 1, 0) = 1
                 AND totassd >= 10000
                 AND EXISTS (
                        SELECT /*+ index(entmod, entmod_sid_ix) */ 1
                          FROM entmod em
                         WHERE em.emodsid = b.tinsid
                           AND em.status  = 'O'
                           AND em.mft IN (1, 9, 11, 12, 13, 14, 16, 64)
                           AND b.assnro + 150 < duedt(em.period, em.mft))
                  THEN 1 ELSE 0
              END),
        0)                                                   AS PYRENT,
    DECODE(NVL(b.segind, ' '),
           'A', PYRIND, 'C', PYRIND, 'I', PYRIND, 0)         AS PYRIND,
    FATCAIND                                                 AS FATCAIND,
    FEDCONIND                                                AS FEDCONIND,
    FEDEMPIND                                                AS FEDEMPIND,
    IRSEMPIND                                                AS IRSEMPIND,
    L903                                                     AS L903,
    TO_NUMBER(NVL(e.LFIIND, 0))                              AS LFIIND,
    LLCIND                                                   AS LLCIND,
    DECODE(NVL(b.segind, ' '),
           'A', RPTIND, 'C', RPTIND, 'I', RPTIND, 'F')       AS RPTIND,
    THEFTIND                                                 AS THEFTIND,
    INSPCIND                                                 AS INSPCIND,
    OICACCYR                                                 AS OICACCYR,
    LPAD(NVL(e.RISK, 399) || NVL(e.ARISK, 'e'), 4, ' ')      AS ARANK,
    0                                                        AS TOT_IRP_INC,
    b.EMPTOUCH                                               AS EMPTOUCH,
    b.LSTTOUCH                                               AS LSTTOUCH,
    (CASE
        WHEN NVL(b.ORG, ' ') = 'CP' THEN CCPTOUCH
        ELSE GREATEST(TOTTOUCH, b.EMPTOUCH)
    END)                                                     AS TOTTOUCH,
    NVL(e.STREET2, ' ')                                      AS STREET2,
    NVL(b.PROID, 0)                                          AS PROID,
    0                                                        AS TOT_INC_DELQ_YR,
    0                                                        AS PRIOR_YR_RET_AGI_AMT,
    0                                                        AS TXPER_TXPYR_AMT,
    0                                                        AS PRIOR_ASSGMNT_NUM,
    AGI_AMT                                                  AS AGI_AMT,
    TO_DATE('01/01/1900', 'mm/dd/yyyy')                      AS PRIOR_ASSGMNT_ACT_DT,
    BAL_941                                                  AS BAL_941,
    (SELECT MIN(selcode) FROM entmod
      WHERE emodsid = e.tinsid)                              AS SELCODE,
    -- -----------------------------------------------------------------------
    -- Extra columns exposed for query-time filtering (replaces bind variables)
    -- -----------------------------------------------------------------------
    b.ORG                                                    AS B_ORG
FROM ENT      e,
     ENTACT   a,
     TABLE(mft_ind_vals(a.ACTSID, e.tinfs)) c,
     (SELECT tb.*,
             ROW_NUMBER() OVER (
                 PARTITION BY tb.TINSID, tb.org
                 ORDER BY tb.EXTRDT DESC, tb.ROWID DESC
             ) AS trail_rn
        FROM TRANTRAIL tb
       -- WHERE tb.org = :org    -- REMOVED: org is now an MV column
     ) b
WHERE e.TINSID  = a.ACTSID
  -- OUTER JOIN: TRANTRAIL is optional, records survive without it
  AND a.ACTSID  = b.TINSID  (+)
  AND b.trail_rn (+) = 1
  -- Standard ENTACT filters (kept verbatim — these are not bind-driven)
  AND ( (   a.aroid BETWEEN 21011000 AND 35165899
        AND MOD(a.aroid, 1000000) BETWEEN 10000 AND 169999
        AND MOD(a.aroid,   10000) BETWEEN  1000 AND   5899)
     OR (   a.roid  BETWEEN 21011000 AND 35165899
        AND MOD(a.roid,  1000000) BETWEEN 10000 AND 169999
        AND MOD(a.roid,    10000) BETWEEN  1000 AND   5899) )
  -- REMOVED: AND TRUNC(a.roid / POWER(10, 8 - :elevel)) = :levelValue
  -- REMOVED: AND SYSDATE - a.actdt <= :daysUpperLimit
;

-- -----------------------------------------------------------------------------
-- Indexes for typical query-time filters
-- -----------------------------------------------------------------------------
CREATE INDEX mv_aview_modern_org_ix       ON mv_aview_modern (B_ORG);
CREATE INDEX mv_aview_modern_actdt_ix     ON mv_aview_modern (ACTDT);
CREATE INDEX mv_aview_modern_roid_ix      ON mv_aview_modern (ROID);
CREATE INDEX mv_aview_modern_tinsid_ix    ON mv_aview_modern (TINSID);
CREATE INDEX mv_aview_modern_org_actdt_ix ON mv_aview_modern (B_ORG, ACTDT);

-- Optional: gather stats so the optimizer plans queries against the MV well.
BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(
        ownname          => USER,
        tabname          => 'MV_AVIEW_MODERN',
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
        method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
        cascade          => TRUE
    );
END;
/

-- -----------------------------------------------------------------------------
-- Refresh schedule: twice daily (06:00 and 18:00 server time)
-- -----------------------------------------------------------------------------
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'MV_AVIEW_MODERN_REFRESH',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
            BEGIN
                DBMS_MVIEW.REFRESH(
                    list           => 'MV_AVIEW_MODERN',
                    method         => 'C',           -- Complete
                    atomic_refresh => FALSE,         -- TRUNCATE+INSERT, faster
                    parallelism    => 8
                );
                DBMS_STATS.GATHER_TABLE_STATS(
                    ownname => USER,
                    tabname => 'MV_AVIEW_MODERN',
                    estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE
                );
            END;
        ]',
        repeat_interval => 'FREQ=DAILY; BYHOUR=6,18; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => 'Twice-daily complete refresh of MV_AVIEW_MODERN'
    );
END;
/

-- -----------------------------------------------------------------------------
-- Example: how the application now queries the MV
-- -----------------------------------------------------------------------------
-- Old (parameterized query against base tables):
--     SELECT * FROM (modern_aview_query)
--      WHERE -- :org, :elevel, :levelValue, :daysUpperLimit applied inside
--
-- New (against MV):
--     SELECT *
--       FROM mv_aview_modern
--      WHERE B_ORG = :org
--        AND TRUNC(ROID / POWER(10, 8 - :elevel)) = :levelValue
--        AND TRUNC(SYSDATE) - ACTDT <= :daysUpperLimit;

-- =============================================================================
-- OPTION B: One MV per org (alternative)
-- =============================================================================
-- If you only ever query a small fixed set of orgs and want smaller, faster
-- MVs, build one MV per org. Drop B_ORG, drop the (TINSID, ORG) partitioning,
-- and add `WHERE tb.org = '<ORG>'` back into the b subquery — substituting a
-- literal for what used to be :org.
--
--   CREATE MATERIALIZED VIEW mv_aview_modern_cp ... WHERE tb.org = 'CP' ...
--   CREATE MATERIALIZED VIEW mv_aview_modern_si ... WHERE tb.org = 'SI' ...
--
-- Pros: smaller per-MV footprint, simpler query plans, parallel refreshes.
-- Cons: more objects to maintain; app needs to pick the right MV.
-- =============================================================================
