#!/usr/bin/env python3
"""Summarise Debezium change events read by kafka-console-consumer (print.key=true, key.separator='|').
One line per event:  op=<r|c|u|d> key=<message key ID> id=<after.ID> cust=<after.CUSTOMER> status=<after.STATUS>
                     amount=<raw after.AMOUNT> qty=<raw after.QTY> note=<null|PLACEHOLDER|len:N> bnote=<before.NOTE ...>"""
import json, sys

PH = "__debezium_unavailable_value"

def note(v):
    if v is None:
        return "null"
    if v == PH:
        return "PLACEHOLDER"
    return "len:%d" % len(v)

for line in sys.stdin:
    line = line.rstrip("\n")
    if "|" not in line:
        continue
    k, v = line.split("|", 1)
    if not k.startswith("{"):
        continue
    if v == "null":
        print("op=tombstone key=%s" % json.loads(k).get("ID"))
        continue
    try:
        e = json.loads(v)
    except ValueError:
        continue
    a = e.get("after") or {}
    b = e.get("before") or {}
    row = a or b
    print("op=%s key=%s id=%s cust=%s status=%s amount=%s qty=%s note=%s bnote=%s scn=%s" % (
        e.get("op"), json.loads(k).get("ID"), row.get("ID"), row.get("CUSTOMER"), row.get("STATUS"),
        json.dumps(row.get("AMOUNT"), separators=(",", ":")), json.dumps(row.get("QTY"), separators=(",", ":")),
        note(row.get("NOTE")) if "NOTE" in row else "absent",
        note(b.get("NOTE")) if "NOTE" in b else "absent", (e.get("source") or {}).get("scn")))
