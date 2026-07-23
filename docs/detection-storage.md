# Detection storage

Perch keeps a compact local SQLite record of accepted `caution` and `danger`
detections. This preserves the rolling posture across app restarts and provides
a stable source contract for a future Crowsnest adapter. It is not a detailed
history database or a tamper-evident compliance log.

## Location and retention

The database is:

```text
~/Library/Application Support/Perch/detections.sqlite3
```

The containing directory is mode `0700`; the database and its SQLite WAL/SHM
files are mode `0600`. Perch uses the SQLite library shipped with macOS, with
WAL journaling, full synchronous durability, foreign keys, and a bounded busy
timeout.

Rows are retained for 30 days and pruned without a foreground `VACUUM`.
Perch restores only risk levels from the previous hour to rebuild the posture
score. It does not replay old cards or notifications and does not expose a
local history browser.

## What is stored

Each event stores only:

- contract version, stable event ID, and UTC observation time;
- endpoint user and host;
- Perch version;
- agent, session ID, optional tool-use ID, and tool name;
- overall risk level;
- stable finding codes and finding levels.

Perch does **not** store commands, tool inputs or outputs, finding messages,
summaries, paths, working directories, repository names, URLs, prompts,
responses, patches, file contents, content hashes, approval decisions, or
execution outcomes.

A row means only that Perch observed a tool request and emitted the listed
findings. It does not claim that the request was approved, denied, executed, or
completed.

## Consumer contract

`detection_export_v1` is the supported read contract:

| Column | Meaning |
| --- | --- |
| `record_schema_version` | Export record contract, currently `1` |
| `event_id` | Idempotent Perch event ID |
| `observed_at_ms` | UTC Unix time in milliseconds |
| `endpoint_user`, `endpoint_host` | Origin endpoint identity |
| `producer`, `producer_version` | `perch` and the assessing Perch version |
| `agent`, `session_id`, `tool_use_id` | Agent/tool-call correlation |
| `tool_name`, `risk_level` | Tool dimension and overall classification |
| `finding_code`, `finding_level` | Stable finding identity and classification |

The view emits one row per finding. Consumers should read it in stable order:

```sql
SELECT *
FROM detection_export_v1
ORDER BY observed_at_ms, event_id, finding_code;
```

Internal tables may evolve while this view remains stable. A breaking contract
will use a new versioned view rather than changing version 1 in place.

## Future Crowsnest ingestion

[Crowsnest](https://github.com/theMobiusStrip/crowsnest) integration is not part
of Perch. A future Crowsnest adapter can open the database read-only, poll
`detection_export_v1`, keep its checkpoint in Crowsnest, re-read a small
overlap, and deduplicate by `event_id` plus
`perch:<finding_code>:<event_id>`.
Because the database is mode `0600`, that adapter must run as the same local
account or receive access through an explicit read-only mount.

Crowsnest owns its durable copy and retention. Once a row is ingested, Perch's
30-day TTL does not affect that copy. The TTL is the maximum recovery window
for rows not yet ingested: an adapter outage longer than 30 days can lose
unread rows. Perch deliberately has no acknowledgement state, delivery queue,
retry state, or pre-TTL archive.
