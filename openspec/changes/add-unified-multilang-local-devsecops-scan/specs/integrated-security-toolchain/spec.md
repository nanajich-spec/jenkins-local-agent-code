## ADDED Requirements

### Requirement: Baseline security integrations
The system SHALL integrate SonarQube analysis, Trivy scans (filesystem, image, configuration), and SBOM generation (CycloneDX and SPDX) as baseline security capabilities.

#### Scenario: Baseline toolchain executes in scan run
- **WHEN** a full scan workflow is triggered
- **THEN** the system executes baseline toolchain stages and stores each stage result

### Requirement: Scan mode aware tool execution
The system SHALL execute tools according to selected scan mode (code-only, image-only, full, or config-focused) without skipping required checks for that mode.

#### Scenario: Code-only mode requested
- **WHEN** scan mode is set to code-only
- **THEN** the system runs code-relevant security and quality scans and excludes image-only stages

### Requirement: Tool preflight and degraded handling
The system SHALL perform preflight checks for required tool availability and connectivity, and SHALL report degraded mode when optional tools are unavailable.

#### Scenario: Optional scanner unavailable
- **WHEN** baseline-required tools are reachable but an optional scanner is unavailable
- **THEN** the scan continues in degraded mode and records the missing scanner impact in the final report

### Requirement: Consistent severity model
The system SHALL map findings from all integrated security tools to a consistent severity model in the consolidated report.

#### Scenario: Multi-tool findings are aggregated
- **WHEN** findings are collected from multiple scanners
- **THEN** the report presents normalized counts by severity and source tool
