Here's the query with NVL applied to both columns on each side of the MINUS:

```sql
SELECT /*+ PARALLEL(32) */ EXTRDT,TIN,TINFS,TINTT,TP
,TP2,TPCTRL,STREET,CITY,STATE,ZIPCDE,CASECODE,SUBCODE,RWMS,TOTASSD,ASSNGRP,TOTTOUCH
,TOTHRS,CASEIND,AGEIND,LFIIND,LDIND,PDTIND,RPTIND,SELIND,PYRIND,FR1120,FR1065,ASSNCFF,DVICTCD
,INSPCIND,ERRFDIND,FMSLVIND,IA_REJDT,LGCORPCD,CEPCD,BODCD,BODCLCD,STATUS,CLOSEDT,RISK
,NVL(PREDCD,'X') AS PREDCD
,ASSNQUE,WIHRS,WITOUCH,L903,TSTOUCH,TSHRS,CCPTOUCH,CCPHRS,STREET2,FEDCONIND,THEFTIND,COUNTRY,OICACCYR
,LLCIND,CCNIPSELECTCD,FOREIGNPOSTALCD,FORPROVINCECNTRY
,NVL(PRED_UPDT_CYC,-1) AS PRED_UPDT_CYC
,COBRA,FRVLS,DT_OA,DT_POA,PRGNAME1
,PRGNAME2,MODELRANK,HINFIND,FEDEMPIND,IRSEMPIND,FATCAIND,DT_DOD,AGI_AMT,TPI_AMT,AGI_TPI_TX_YR
,PRVSUBCODE,AGI_TPI_IND
FROM ENT

MINUS

SELECT /*+ PARALLEL(32) */ EXTRDT,TIN,TINFS,TINTT,TP
,TP2,TPCTRL,STREET,CITY,STATE,ZIPCDE,CASECODE,SUBCODE,RWMS,TOTASSD,ASSNGRP,TOTTOUCH
,TOTHRS,CASEIND,AGEIND,LFIIND,LDIND,PDTIND,RPTIND,SELIND,PYRIND,FR1120,FR1065,ASSNCFF,DVICTCD
,INSPCIND,ERRFDIND,FMSLVIND,IA_REJDT,LGCORPCD,CEPCD,BODCD,BODCLCD,STATUS,CLOSEDT,RISK
,NVL(PREDCD,'X') AS PREDCD
,ASSNQUE,WIHRS,WITOUCH,L903,TSTOUCH,TSHRS,CCPTOUCH,CCPHRS,STREET2,FEDCONIND,THEFTIND,COUNTRY,OICACCYR
,LLCIND,CCNIPSELECTCD,FOREIGNPOSTALCD,FORPROVINCECNTRY
,NVL(PRED_UPDT_CYC,-1) AS PRED_UPDT_CYC
,COBRA,FRVLS,DT_OA,DT_POA,PRGNAME1
,PRGNAME2,MODELRANK,HINFIND,FEDEMPIND,IRSEMPIND,FATCAIND,DT_DOD,AGI_AMT,TPI_AMT,AGI_TPI_TX_YR
,PRVSUBCODE,AGI_TPI_IND
FROM ALS_LEGACY_REPLICA.ENT;
```

**A note on the sentinel values:** I used `'X'` for PREDCD (assuming string) and `-1` for PRED_UPDT_CYC (assuming numeric cycle). Adjust to data types that won't collide with real values — pick anything that can never legitimately appear. The defaults must be **identical on both sides** of the MINUS, or you'll generate spurious diffs.

**Why NVL here?**

Oracle's MINUS *does* treat `NULL = NULL` as equal in set comparison, so on paper NVL shouldn't be needed. The reason teams still wrap reconciliation columns in NVL is to defend against representation drift between environments:

- One env may store actual `NULL`, while the other stores a default like `' '`, `0`, or `'N'` after replication, ETL transforms, or schema-default changes — those rows would falsely show as differences.
- New columns (PREDCD and PRED_UPDT_CYC look like recent additions to the predictive model flow) often have inconsistent backfill — populated in one env, NULL in the other, even when the row is logically the same.
- Some Golden Gate / ETL paths convert NULL to empty string or `0` somewhere in the pipeline. NVL normalizes both sides to a known sentinel so the MINUS only flags *real* data divergence.

In short: NVL strips out NULL-vs-default noise so you can trust that what comes back is genuinely different data, not a representation artifact.
