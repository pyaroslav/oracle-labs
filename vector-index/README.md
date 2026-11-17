# Vector index lab — HNSW vs IVF and the vector memory pool on Oracle AI Database 26ai

Companion to the first post in the "26ai in practice" series:

- [Oracle 26ai Vector Search: The HNSW Index Fails Out of the Box. The Fix Takes a
  Restart.](https://uptimearchitect.com/blog/oracle-26ai-vector-search-hnsw-ivf/)

One container, the public `gvenzl/oracle-free` image (currently Oracle AI Database 26ai Free 23.26.3). Setup loads two
tables of 100,000 `VECTOR(128, FLOAT32)` rows with fixed random seeds, no embedding model and no download: `APP.DOCS`
in 100 clusters (what embeddings of similar documents look like) and `APP.RND`, uniform random (the hard case for an
approximate index), plus 20 query vectors for each. Every drill starts from the default memory settings, changes only
what it names, and asserts the result.

## What it proves

| drill | case | asserted |
| --- | --- | --- |
| `default` | the image as shipped | `VECTOR_MEMORY_SIZE` = 0; an HNSW index (`INMEMORY NEIGHBOR GRAPH`) fails with `ORA-51962`; raising the pool online fails (`ORA-51950` in the CDB, `ORA-51955` in the PDB); an IVF index (`NEIGHBOR PARTITIONS`) builds and `FETCH APPROX` uses it |
| `sizing` | `VECTOR_MEMORY_SIZE = 256M` in the spfile, restart | the buffer cache shrinks (the pool comes out of the SGA); PDB limit 64M (the docs' formula: 1.3 × 100,000 × 128 × 4 bytes = 63.5 MiB): `ORA-51962`; 90M: still `ORA-51962`; 128M: builds, and the finished index uses 80–90 MiB. `DBMS_VECTOR.INDEX_VECTOR_MEMORY_ADVISOR` says 96.7 MiB |
| | after that restart | the CDB pool can be raised online; lowering it below its startup size fails with `ORA-51953`; a second vector index on the same column fails with `ORA-01408` |
| `accuracy` | exact top 10 (`FETCH EXACT`, a full scan) vs the HNSW index | clustered data: `FETCH APPROX FIRST 10` finds ≥ 99% of the exact top 10. Uniform random data: below the default target accuracy of 90 (81.5–86.5% across builds) |
| | `FETCH FIRST 10` with neither `APPROX` nor `EXACT` | uses the HNSW index and gets exactly the same recall as `FETCH APPROX` |
| | `WITH TARGET ACCURACY 100` | more than the default, not 100% (95.5–97% in the runs so far) |
| | a `EUCLIDEAN` query on a `COSINE` index | full table scan |
| `restart` | insert, update, delete with the index in place | the next approximate search sees each change at once (the insert even uncommitted, in the same session); `V$VECTOR_INDEX.NUM_VECTORS` stays 100,000 |
| | instance restart | the index is reloaded; a query run before that does a full scan |
| | spfile pool lowered to 64M (smaller than the 81 MiB index), restart | the index stays `VALID`, `NUM_VECTORS` is 0, every approximate query runs as a full scan with correct results, nothing in the alert log |
| | then the CDB pool raised online to 256M | still not reloaded; `DBMS_VECTOR.REBUILD_INDEX` fails with `ORA-51962` and the index is gone; `CREATE` fails the same way until the PDB's `VECTOR_MEMORY_SIZE` is set again |
| `autogrow` | `VECTOR_MEMORY_SIZE = 1` (automatic growth), restart | the PDB can't set a limit (`ORA-51999`); HNSW fails with `ORA-51995` while the PDB's `SGA_TARGET` is 0; with PDB `SGA_TARGET = 512M` it builds, the pool grows, and after a restart the index is reloaded and used |

## Run it

```bash
./run.sh up          # start the database (first run pulls the image)
./run.sh all         # every drill, each from setup (about 6 minutes after the image is pulled)
```

```bash
./run.sh setup       # schema + default memory settings (resets the lab; safe to rerun)
./run.sh default     # out of the box: HNSW fails, the pool can't be raised online, IVF works
./run.sh sizing      # spfile + restart; formula vs advisor vs what the build needed
./run.sh accuracy    # recall of approximate search; FETCH FIRST without APPROX; metric mismatch
./run.sh restart     # DML, restart, and a pool that's too small after a restart
./run.sh autogrow    # VECTOR_MEMORY_SIZE = 1 and the PDB SGA_TARGET it needs
./run.sh sql         # SQL*Plus as SYSDBA
./run.sh down        # stop (keep data)   |   ./run.sh destroy  # stop and delete the volume
```

Set `LAB_PORT` to publish Oracle on a different host port (default 1521). Everything runs through `docker exec`.

## Notes

- The drills restart the instance and change memory parameters in the lab's own spfile only; `setup` puts them back.
- Recall numbers depend on the data. Synthetic vectors are not a benchmark: the point is the comparison between
  queries on the same index, and that the default target accuracy is not a guarantee on hard data.
- Not covered: IVF tuning, quantization, RAC, Exadata, Autonomous Database (where the pool is managed for you), and
  any embedding model.
