-- =============================================================================
-- MV_AVIEW_MODERN — v2 (faithful semantic preservation)
-- =============================================================================
-- Changes vs v1:
--   1. STATUS rewrite is now faithful to the legacy "c2 not filtered by segind"
--      semantic. Uses a two-step CTE: pre-aggregate MAX(EXTRDT) per (tinsid,
--      roid, seg_match), then ROW_NUMBER over c2 rows whose EXTRDT matches.
--   2. ASSNRO combine is bulletproof for any value range (no assumption that
--      ASSNRO >= 0). Explicit CASE handles NULL pairs.
--   3. Bind variables converted to query-time predicates documented at bottom.
--
-- IMPORTANT: This MV is functionally equivalent to the original modern_aview
-- query under the assumption that ASSNRO and EXTRDT semantics match what the
-- legacy code intended. Validate with the diff script before cutting over.
-- =============================================================================

CREATE MATERIALIZED VIEW mv_aview_modern
    PCTFREE 0
    NOLOGGING
    PARALLEL 8
    BUILD IMMEDIATE
    REFRESH COMPLETE
    ON DEMAND
AS
WITH
-- -----------------------------------------------------------------------------
-- max_extrdt_by_seg: helper for STATUS rewrite.
--   For each (tinsid, roid, seg_match) combination, the max EXTRDT.
--   This replaces the inner correlated subquery in the legacy STATUS scalar.
-- -----------------------------------------------------------------------------
max_extrdt_by_seg AS (
    SELECT /*+ materialize */
           d.TINSID,
           d.ROID,
           DECODE(d.segind, 'A', 1, 'C', 1, 'I', 1, 0) AS seg_match,
           NVL(MAX(d.EXTRDT), TO_DATE('01/01/1900','mm/dd/yyyy')) AS max_extrdt
      FROM TRANTRAIL d
     GROUP BY d.TINSID, d.ROID, DECODE(d.segind, 'A', 1, 'C', 1, 'I', 1, 0)
),
-- -----------------------------------------------------------------------------
-- v_status: latest c2 row by EXTRDT/ROWID where c2.EXTRDT = max_extrdt_by_seg.
--   c2 is NOT filtered by segind — this matches the legacy behavior where
--   ANY c2 row whose EXTRDT equals the segind-filtered max can win the
--   ROW_NUMBER tiebreak.
-- -----------------------------------------------------------------------------
v_status AS (
    SELECT tinsid, roid, seg_match, status
      FROM (
          SELECT c2.tinsid,
                 c2.roid,
                 m.seg_match,
                 c2.status,
                 ROW_NUMBER() OVER (
                     PARTITION BY c2.tinsid, c2.roid, m.seg_match
                     ORDER BY c2.EXTRDT DESC, c2.ROWID
                 ) AS rn
            FROM TRANTRAIL c2
            JOIN max_extrdt_by_seg m
              ON m.TINSID     = c2.TINSID
             AND m.ROID       = c2.ROID
             AND m.max_extrdt = c2.EXTRDT
      )
     WHERE rn = 1
),
-- -----------------------------------------------------------------------------
-- v_assnro_by_seg: MAX(ASSNRO) per (tinsid, roid, seg_match).
--   Used twice in the join — once on a.aroid, once on a.roid — to handle the
--   legacy `t2.roid = a.aroid OR t2.roid = a.roid` predicate.
-- -----------------------------------------------------------------------------
v_assnro_by_seg AS (
    SELECT /*+ materialize */
           t2.tinsid,
           t2.roid,
           DECODE(t2.segind, 'A', 1, 'C', 1, 'I', 1, 0) AS seg_match,
           MAX(t2.ASSNRO) AS max_assnro
      FROM TRANTRAIL t2
     GROUP BY t2.tinsid, t2.roid,
              DECODE(t2.segind, 'A', 1, 'C', 1, 'I', 1, 0)
)
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

    -- STATUS — faithful to legacy "c2 not filtered by segind" semantic
    NVL(vs.status, 'P')                                      AS STATUS,

    e.LDIND                                                  AS LDIND,
    e.RISK                                                   AS RISK,
    MFT                                                      AS MFT,
    a.PERIOD                                                 AS PERIOD,
    TYPCD                                                    AS M_TYPE,
    a.AROID                                                  AS AROID,

    -- ASSNRO — bulletproof null/value combine, no non-negativity assumption
    CASE
        WHEN va_aro.max_assnro IS NULL AND va_roi.max_assnro IS NULL THEN NULL
        WHEN va_aro.max_assnro IS NULL THEN va_roi.max_assnro
        WHEN va_roi.max_assnro IS NULL THEN va_aro.max_assnro
        ELSE GREATEST(va_aro.max_assnro, va_roi.max_assnro)
    END                                                      AS ASSNRO,

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
     ) b,
     v_status         vs,
     v_assnro_by_seg  va_aro,
     v_assnro_by_seg  va_roi
WHERE e.TINSID  = a.ACTSID
  AND a.ACTSID  = b.TINSID  (+)
  AND b.trail_rn (+) = 1
  -- v_status outer join
  AND vs.tinsid    (+) = a.actsid
  AND vs.roid      (+) = a.roid
  AND vs.seg_match (+) = DECODE(c.mft, 0, 0, 1)
  -- v_assnro_by_seg, aroid branch
  AND va_aro.tinsid    (+) = a.actsid
  AND va_aro.roid      (+) = a.aroid
  AND va_aro.seg_match (+) = DECODE(c.mft, 0, 0, 1)
  -- v_assnro_by_seg, roid branch
  AND va_roi.tinsid    (+) = a.actsid
  AND va_roi.roid      (+) = a.roid
  AND va_roi.seg_match (+) = DECODE(c.mft, 0, 0, 1)
  AND ( (   a.aroid BETWEEN 21011000 AND 35165899
        AND MOD(a.aroid, 1000000) BETWEEN 10000 AND 169999
        AND MOD(a.aroid,   10000) BETWEEN  1000 AND   5899)
     OR (   a.roid  BETWEEN 21011000 AND 35165899
        AND MOD(a.roid,  1000000) BETWEEN 10000 AND 169999
        AND MOD(a.roid,    10000) BETWEEN  1000 AND   5899) )
;

-- =============================================================================
-- KNOWN BEHAVIORAL DELTAS the application layer must absorb
-- =============================================================================
-- 1. Bind variables removed from the MV — push them to query-time predicates:
--      OLD: tb.org = :org  inside b subquery
--      NEW: WHERE B_ORG = :org   (against MV)
--
--      OLD: AND TRUNC(a.roid / POWER(10, 8 - :elevel)) = :levelValue
--      NEW: AND TRUNC(ROID / POWER(10, 8 - :elevel)) = :levelValue
--
--      OLD: AND SYSDATE - a.actdt <= :daysUpperLimit
--      NEW: AND TRUNC(SYSDATE) - ACTDT <= :daysUpperLimit
--           (uses TRUNC for stability; original used raw SYSDATE — sub-day
--           differences vanish since the MV refreshes every 12 hours anyway.)
--
-- 2. Data freshness: results lag by up to 12 hours. If the legacy query was
--    used for any "real-time" decision, this is a behavioral change. Confirm
--    no consumers depend on intra-day freshness.
--
-- 3. SYSDATE-based filtering moved from refresh-time to query-time. The MV
--    stores ACTDT raw, queries compute the day delta. Net effect: queries see
--    the same data they would have at refresh time + their own SYSDATE.
-- =============================================================================
