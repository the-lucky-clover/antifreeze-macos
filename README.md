# AntiFreeze — Predictive macOS Stability Platform

> **Phase 1 only.** This repo currently implements the system telemetry
> foundation: real, on-device sampling of CPU, memory, thermal, disk, power,
> process, and GPU signals into a common `TelemetryEvent` schema, stored
> locally in SQLite with retention + downsampling, adaptive sampling, a
> permissions-onboarding scaffold, privacy tiers (local-only by default),
> and a menu-bar dashboard proving it runs.

**Isolation note:** AntiFreeze is a stability product — crash prediction,
kernel panic analysis, system health, performance reliability. It is a
completely separate project from any security tooling. No antivirus, malware
detection, privacy-invasive, or endpoint-security features belong here.

## Honest scope

- A macOS app **cannot prevent every kernel panic** — many originate in Apple
  kernel code, hardware, drivers, or firmware outside userspace reach. The
  product loop is: **Predict → Warn → Mitigate → Diagnose → Prevent recurrence.**
- GPU utilization and disk I/O latency are **best-effort**: where the hardware
  doesn't expose them, the metric is disabled with a log line — never a
  fabricated number.
- This source has **not been compiled here** (built on Linux; Xcode is
  macOS-only). Build it in Xcode per `BUILD_GUIDE.md` and send back any
  compiler errors verbatim.

## Architecture (Phase 1)

```
AntiFreeze/
├── AntiFreezeApp.swift          # menu-bar-only entry (LSUIElement)
├── Models/
│   └── TelemetryEvent.swift     # common schema + unit/threshold table
├── MonitoringEngine/
│   ├── Collectors.swift         # CPU/Memory/Thermal/Disk/Power/Process/GPU
│   └── SystemTelemetryEngine.swift  # timers, adaptive sampling, ingestion
├── Storage/
│   └── TelemetryStore.swift     # SQLite: raw events + hourly aggregates
├── Permissions/
│   └── PermissionsOnboarding.swift  # Phase 12 scaffold
├── Privacy/
│   └── PrivacySettings.swift    # Phase 15: tiers + export allowlist
├── Dashboard/
│   └── MenuBarView.swift        # Phase 9 (Phase-1 scope): live metrics
└── Info.plist                   # reference values (LSUIElement etc.)
```

**Data-flow contract:** every collector emits `TelemetryEvent`. Later phases
(crash analysis, panic parsing, ML) read this schema — they never special-case
a collector's output format.

## What's next (per the build orchestration)

1. Phase 12 — permissions onboarding against real collection calls *(scaffolded)*
2. Phase 15 — privacy/consent enforcement at export boundaries *(foundation in)*
3. Phase 2 — crash collection (MetricKit + DiagnosticReports parsing)
4. Phase 3 — kernel panic analyzer (rule-based classifier, honest Unknown)
5. Phases 4–5 — WindowServer + memory fast-path warnings
6. Phases 6–7, 13 — ML pipeline, prediction engine, model registry
7. Phases 8–11 — remediation, dashboard, feedback loop, reports
8. Phase 14 — Safari extension (separate target, decoupled)

Do not start later phases until this foundation builds and runs cleanly.
