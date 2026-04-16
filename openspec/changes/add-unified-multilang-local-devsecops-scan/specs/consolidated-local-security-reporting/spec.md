## ADDED Requirements

### Requirement: Consolidated local report bundle
The system SHALL generate one local report bundle per scan containing both aggregated summaries and raw tool artifacts.

#### Scenario: Scan completes and report bundle is generated
- **WHEN** scan execution reaches terminal state
- **THEN** the system creates a local report bundle directory with consolidated summary and referenced raw artifacts

### Requirement: Mandatory summary sections
The consolidated summary SHALL include at minimum: executive overview, gate verdict, vulnerability summary by severity, test summary, coverage summary, and tool execution status.

#### Scenario: User opens final summary
- **WHEN** the user views the final summary artifact
- **THEN** all mandatory sections are present with non-empty status fields

### Requirement: Issue traceability to source artifacts
The system SHALL include references from aggregated findings back to originating scanner outputs.

#### Scenario: Developer investigates a reported issue
- **WHEN** a finding is selected from the consolidated report
- **THEN** the report provides source artifact linkage sufficient for detailed investigation

### Requirement: Local-only accessibility
The system SHALL ensure final report outputs are accessible from the developer local machine without requiring direct Jenkins UI navigation.

#### Scenario: Developer runs scan from workstation
- **WHEN** the scan run ends
- **THEN** all final summary artifacts are present in the local output path
