Filter out the successful runs by only keeping events where the second-to-last line contains `ERROR`. Add a `where` clause after extracting `last_two`:

```spl
index=kubernetes_system_devtest cluster_name="ecpdevtest-tcc" namespace="sbse-entity-dev" container_name="ics-etl-batch" pod="ics-etl-batch-daily*" "dailyLogger" earliest=-1d@d
| transaction startswith="Clean File" endswith="FINISHED LOADING ON"
| rex field=_raw max_match=0 "dailyLogger\s*-\s*(?<message>[^\r\n]+)"
| eval last_two = mvindex(message, -2, -1)
| where match(mvindex(last_two, 0), "(?i)ERROR")
| eval clean_output = mvjoin(last_two, "
")
| table clean_output
```

The `where match(...)` line drops any transaction whose second-to-last line isn't an ERROR, so only the failing run survives. The `(?i)` makes it case-insensitive in case it's ever lowercase.

If you'd rather match `ERROR` anywhere in the captured message (not strictly the second-to-last line), swap the `where` for:

```spl
| where mvfind(message, "(?i)ERROR") >= 0
```
