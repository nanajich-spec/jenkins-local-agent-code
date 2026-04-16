## Context

The repository already contains substantial DevSecOps functionality across Jenkins pipelines, shared library modules, a FastAPI API layer, and report generation scripts. Existing documentation confirms support for many scanners and multiple language stacks, but the user experience is fragmented between different entry points and inconsistent pre-push behavior.

Current gaps addressed by this design:
- No single normative pre-push command that enforces tests, coverage, and security scans together for all supported stacks.
- Inconsistent test-framework detection and coverage normalization across languages.
- Consolidated reporting exists in parts, but one canonical local final report contract is not defined for all scan modes.
- Tool integration pathways (SonarQube, Trivy, SBOM, optional scanners) exist, but orchestration policy and fallback behavior are not standardized.

Stakeholders:
- Developers running scans before pushing code.
- DevSecOps owners maintaining Jenkins and scanner integrations.
- Security/compliance reviewers consuming one final report.

Constraints:
- Preserve existing zero-setup scan usage where possible.
- Work across Python, Java, Node/React, C/C++, Kotlin, HTML/static projects.
- Keep reports local for developer consumption while using centralized scanner infrastructure.

## Goals / Non-Goals

**Goals:**
- Define one unified pre-push scan orchestration model with deterministic phases.
- Standardize language and test detection, including Python `pytest`/`unittest` test folder handling.
- Standardize coverage collection and quality/security result normalization.
- Define final local consolidated report structure and minimum required sections.
- Ensure scalable integration with SonarQube, Trivy, and SBOM generation.

**Non-Goals:**
- Replacing Jenkins with another orchestrator.
- Introducing mandatory SaaS dependencies.
- Building a new web UI for report consumption in this change.
- Solving every language-specific edge case in one iteration (extension hooks are defined instead).

## Decisions

1. Unified orchestration contract via a single developer command
- Decision: Introduce a canonical scan command flow (existing CLI script/API path can remain implementation vehicle) with fixed phases: detect → test → coverage → security scans → aggregate report.
- Rationale: Reduces ambiguity and ensures every run produces comparable output.
- Alternatives considered:
  - Keep per-language commands only: rejected due to inconsistency.
  - Only central Jenkins-triggered scans: rejected because requirement includes pre-push developer checks and local final report.

2. Pluggable language adapter model
- Decision: Define adapters by language family (Python, JVM, Node, Native C/C++, Kotlin, Static HTML) with explicit detection signals, test commands, and coverage extractors.
- Rationale: Scales better than hardcoded branching and aligns with existing shared-library modularity.
- Alternatives considered:
  - One monolithic script with heuristics: simpler initially but harder to maintain.
  - Separate pipeline per language: high operational overhead.

3. Test and coverage detection policy
- Decision: Enforce test auto-discovery with framework precedence rules. For Python: detect `tests/` or configured test paths; prefer `pytest` when configured, otherwise run `unittest` discovery; always attempt coverage output when tooling available.
- Rationale: Satisfies explicit requirement and avoids silent test omission.
- Alternatives considered:
  - Require explicit per-project config: rejected as too heavy for onboarding.

4. Security tooling orchestration policy
- Decision: Use SonarQube, Trivy filesystem/image/config scans, and SBOM (CycloneDX + SPDX) as baseline mandatory integrations; optional scanners can enrich but not replace baseline outputs.
- Rationale: Baseline ensures predictable minimum security depth while preserving extensibility.
- Alternatives considered:
  - Optional everything: rejected because outcome quality becomes non-deterministic.

5. Normalized local report schema
- Decision: Define one final local report bundle containing: executive summary, per-tool findings, severity matrix, test summary, coverage summary, gate verdict, and remediation hints.
- Rationale: Gives developers and reviewers one source of truth independent of language.
- Alternatives considered:
  - Keep separate raw files only: rejected due to fragmented UX.

6. Fail policy and degraded mode
- Decision: Differentiate hard failures (critical command failures, missing required scanners in strict mode) from degraded warnings (optional tools unavailable). Always emit final report with clear gate status and missing-data annotations.
- Rationale: Avoids silent passes and improves operational reliability.
- Alternatives considered:
  - Fail on any missing tool: rejected as too brittle in heterogeneous environments.

## Risks / Trade-offs

- [Risk] Cross-language command execution complexity can cause false negatives in test discovery. → Mitigation: adapter contract tests + explicit detection logs in final report.
- [Risk] Coverage format variance can break normalization. → Mitigation: per-language coverage parser contracts and fallback “coverage unavailable” state.
- [Risk] SonarQube/trivy connectivity failures can block scans. → Mitigation: preflight checks, retry/backoff, and degraded-mode reporting.
- [Risk] Increased scan time from full toolchain execution. → Mitigation: stage parallelization where safe, cache warm-up, and optional quick profile.
- [Risk] Report aggregation drift as tools evolve. → Mitigation: versioned internal report schema and compatibility checks.

## Migration Plan

1. Define and document the unified pre-push command contract and adapter interfaces.
2. Implement or refactor language adapters and detection logic in shared library/scripts.
3. Add/align Jenkins pipeline stages and parameters for standardized scan phases and outputs.
4. Add normalized report aggregation updates in report parser/generator scripts.
5. Add compatibility validation on representative repositories (Python, Java, Node/React, C/C++, Kotlin, static web).
6. Roll out in non-blocking mode first (warn on gaps), then enforce quality/security gates by policy.

Rollback strategy:
- Keep legacy pipeline entry points and existing script paths available behind feature flags.
- Revert to legacy report path and gate evaluation logic if major regressions occur.

## Open Questions

- Which scanner is authoritative when duplicate findings exist across tools (dedupe precedence)?
- What default coverage threshold should be enforced globally vs per-language overrides?
- Should C/C++ and Kotlin rely only on build-system native tooling initially (CMake/Gradle), or include additional mandatory scanners in phase one?
- What is the desired default strictness mode for local pre-push runs (advisory vs blocking)?
