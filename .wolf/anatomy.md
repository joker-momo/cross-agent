# anatomy.md

> Auto-maintained by OpenWolf. Last scanned: 2026-06-18T00:39:10.754Z
> Files: 17 tracked | Anatomy hits: 0 | Misses: 0

## ./

- `Package.swift` — SwiftPM package for the native Trinity macOS app (~104 tok)
- `README.md` — Project documentation (~750 tok)

## Scripts/

- `build_app.sh` (~1010 tok)

## Sources/Trinity/

- `AgentHealth.swift` — Class: AgentHealthService (~13104 tok)
- `AgentRunner.swift` — Struct: AgentCommandBuilder (~557 tok)
- `AppState.swift` — SwiftUI observable app state and UI actions (~668 tok)
- `ContentView.swift` — SwiftUI view: ContentView (~7910 tok)
- `GitService.swift` — Class: GitService (~1067 tok)
- `Models.swift` — Swift domain models for agents, roles, runs, status, verdict events (~603 tok)
- `ProjectStore.swift` — Swift ~/.trinity project registry persistence (~508 tok)
- `Prompts.swift` — Swift prompt templates for planner, implementer, reviewer (~905 tok)
- `RunManager.swift` — Swift async run lifecycle and event history (~1834 tok)
- `SelfTests.swift` — Declares SelfTests (~3534 tok)
- `Shell.swift` — Protocol: ShellRunning (~1502 tok)
- `TrinityApp.swift` — SwiftUI app entrypoint plus --self-test shortcut (~75 tok)
- `VerdictParser.swift` — Swift reviewer JSON extraction and decoding (~495 tok)

## docs/specs/

- `2026-06-17-trinity-orchestrator-design.md` — Trinity — Multi-Agent Orchestrator (Design Spec) (~2357 tok)
