# Governance

DeepFinder uses a **BDFL (Benevolent Dictator for Life)** governance model.

## BDFL

Nadav (nadav.com.cn) is the BDFL and final arbiter for all project decisions, including but not limited to technical direction, roadmap, release schedule, and community disputes. The BDFL delegates day-to-day decisions to the maintainer team.

## Maintainer Team

Maintainers are domain experts responsible for their respective subsystems. Each maintainer has merge permissions and is trusted to review and accept contributions in their area.

| Role | Area |
|------|------|
| **architect** | Technical decisions, spec maintenance, cross-cutting concerns, code review |
| **algo-dev** | Data structures, search engine, indexing algorithms, performance |
| **macos-dev** | FSEvents, daemon lifecycle, IPC, SQLite persistence, LaunchAgent, permissions |
| **cli-dev** | CLI argument parsing, REPL, terminal formatting, IPC client |
| **ui-dev** | SwiftUI GUI, Liquid Glass, hotkey, accessibility, settings panel |
| **ai-dev** | CoreML, Vision, LLM API, vector index, RAG pipeline, semantic search |
| **qa-dev** | Unit tests, benchmarks, integration tests, regression tests, test fixtures |

New maintainers are nominated by existing maintainers and approved by the BDFL.

## Decision Making

- **Non-controversial PRs**: Any maintainer may review and merge a pull request that falls within their domain and is clearly non-controversial. A single approval is sufficient.
- **Major changes**: PRs that alter public API, introduce new dependencies, change architecture, or modify the spec require at least **two maintainer approvals**, one of which must be from the **architect**.
- **Spec changes**: Any change to `docs/superpowers/specs/` requires architect review and BDFL awareness. Spec-first development: the spec is the source of truth.
- **Releases**: Tagged releases are cut by the architect or BDFL. Version numbers follow semver (`MAJOR.MINOR.PATCH`).

## Roadmap

The project roadmap lives in `docs/superpowers/specs/` and is tracked via **GitHub Projects**. Issue labels guide community contributions:

- **`help wanted`** — Issues suitable for external contributors with moderate context requirements.
- **`good first issue`** — Issues scoped for first-time contributors, with clear acceptance criteria and mentor guidance available.

Community members are encouraged to comment on roadmap issues with feedback and use cases before volunteering to implement.

## Conflict Resolution

1. **Discussion**: Disagreements are discussed openly on the relevant GitHub issue or PR. Maintainers are expected to argue from evidence, not authority.
2. **Mediation**: If consensus stalls, the architect facilitates a decision. The architect's role is to weigh technical merit, project consistency, and long-term maintainability.
3. **Escalation**: If the architect cannot resolve the dispute, or if the dispute involves the architect, it escalates to the **BDFL**. The BDFL's decision is final.

All participants are expected to remain respectful and assume good faith. The goal is the best outcome for the project and its users, not winning an argument.

## Code of Conduct

This project adheres to the [Contributor Covenant Code of Conduct](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Instances of abusive, harassing, or otherwise unacceptable behavior may be reported to the BDFL.
