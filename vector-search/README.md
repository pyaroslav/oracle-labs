# Oracle AI Vector Search Lab (zero-login)

> 📖 **Companion post:** [Your First Oracle Autonomous Database on OCI Always Free](https://uptimearchitect.com/blog/oracle-autonomous-database-oci-always-free/)

Run the **23ai AI Vector Search** demo from the post on your own machine — **no OCI account, no signup.**
The `VECTOR` datatype and `VECTOR_DISTANCE` are a core Oracle Database 23ai feature and ship in the
community **Oracle Database Free** image, so you can create a vector column and run a similarity search
in a couple of minutes with nothing but Docker.

> ✅ **Verified end-to-end in CI** with `./run.sh all`: creates a `VECTOR(3, FLOAT32)` column, inserts a
> handful of hand-built embeddings, and runs a `VECTOR_DISTANCE` cosine similarity search — the run
> **fails** if the vector operations error or return nothing, so a green check means it really ran.
> "kitten" and "dog" come back as the nearest neighbors to "cat"; "airplane" and "rocket" are far away.

## Prerequisites
- Docker + Docker Compose, ~2 GB free in the Docker engine.

## Quick start
```bash
./run.sh up      # start Oracle Database Free (first run pulls the image + creates the DB)
./run.sh demo    # create a VECTOR table + run a VECTOR_DISTANCE similarity search
# ...or just:
./run.sh all     # same as demo
```
If port 1521 is busy: `LAB_PORT=1530 ./run.sh up`. Everything runs *inside* the container via
`docker exec`, so you don't need a local Oracle client.

## What it shows
Semantic search in three SQL statements: a `VECTOR` column holds each row's embedding, and
`VECTOR_DISTANCE(a, b, COSINE)` ranks rows by *similarity* instead of exact match. The demo uses tiny
3-dimensional vectors so the ordering is intuitive — swap in real embeddings from a model (hundreds of
dimensions) and it's the same operation behind production semantic search and RAG.

> **Note on indexes.** This demo does *exact* (brute-force) similarity search, which needs no index and
> works out of the box. Building an **HNSW** or **IVF** vector index additionally requires a vector
> memory pool (`vector_memory_size`), which the base Free image doesn't allocate by default — a good
> next experiment once you've seen the basics.

## Other commands
```bash
./run.sh sql      # SYSDBA SQL*Plus session inside the container
./run.sh down     # stop & remove the container (keeps the data volume)
./run.sh destroy  # stop & remove the container AND the data volume
```

## Connection details
| | |
| --- | --- |
| Host / port | `localhost:${LAB_PORT:-1521}` |
| Pluggable DB | `FREEPDB1` |
| App user | `labuser` / `Lab_Passw0rd1` |
| SYS password | `Lab_Passw0rd1` |

Throwaway lab credentials — never reuse them anywhere real.

## Licensing
Pulls the community `gvenzl/oracle-free` image (Oracle Database Free, under Oracle's Free license for
development). AI Vector Search is included in Oracle Database Free at no extra cost. Oracle® is a
registered trademark of Oracle Corporation; this project is independent and not affiliated with or
endorsed by Oracle.
