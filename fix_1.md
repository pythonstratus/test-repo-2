SELECT /*+ INDEX(trantrail trantrail_tinsid_ix) */
       ROWID,
       CASE WHEN ROID = :B2 THEN 1 ELSE 2 END,
       DECODE(STATUS,'O',1,'C',2,'T',2,'R',3,4),
       STATUS, ROID,
       NVL(ASSNFLD,  TO_DATE('01/01/1900','mm/dd/yyyy')),
       NVL(ASSNRO,   TO_DATE('01/01/1900','mm/dd/yyyy')),
       NVL(CLOSEDT,  TO_DATE('01/01/1900','mm/dd/yyyy')),
       EXTRDT
FROM   TRANTRAIL
WHERE  TINSID = :B1
  AND  ORG IN ('CF','CP','AD')
  AND  STATUS = :B3   -- whatever the intended predicate is
