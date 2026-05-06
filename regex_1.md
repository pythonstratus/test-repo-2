Use `mvindex` with negative indices to grab just the last two elements of the multi-valued `message` field:

```spl
index=kubernetes_system_devtest cluster_name="ecpdevtest-tcc" namespace="sbse-entity-dev" container_name="ics-etl-batch" pod="ics-etl-batch-daily*" "dailyLogger" earliest=@d
| transaction startswith="Clean File" endswith="FINISHED LOADING ON"
| rex field=_raw max_match=0 "dailyLogger\s*-\s*(?<message>[^\r\n]+)"
| eval clean_output = mvjoin(mvindex(message, -2, -1), "
")
| table clean_output
```

`mvindex(message, -2, -1)` returns the last two values from the multi-value `message` field (second-to-last and last). Since `max_match=0` already produced a multi-value list in extraction order, the last entry will be the `FINISHED LOADING ON` line and the one before it will be whatever preceded it (often the ERROR you mentioned).

If you also want to make sure you only keep the pair when the preceding line is an ERROR (and otherwise just show the final line), tack this on instead:

```spl
| eval last_two = mvindex(message, -2, -1)
| eval clean_output = if(match(mvindex(last_two,0), "(?i)ERROR"), mvjoin(last_two,"
"), mvindex(last_two,-1))
| table clean_output
```
