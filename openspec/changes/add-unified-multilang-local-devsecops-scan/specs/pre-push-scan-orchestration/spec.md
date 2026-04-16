## ADDED Requirements

### Requirement: Unified pre-push command execution
The system SHALL provide a single developer-invoked scan command that executes the pre-push validation workflow for the current repository.

#### Scenario: Developer runs unified scan command
- **WHEN** a developer runs the supported scan command in a project directory
- **THEN** the system starts one end-to-end scan workflow with a generated scan identifier

### Requirement: Ordered scan phases
The system SHALL execute scan phases in deterministic order: project detection, test execution, coverage collection, security scans, and final aggregation.

#### Scenario: Standard workflow order is enforced
- **WHEN** a scan starts successfully
- **THEN** the workflow runs phases in the defined order and records phase status in the final report

### Requirement: Gate verdict for push readiness
The system SHALL produce a final gate verdict indicating pass, fail, or degraded, based on configured policy and observed scan outcomes.

#### Scenario: Gate verdict is computed from results
- **WHEN** all configured scan phases complete
- **THEN** the system emits a gate verdict with explicit reasons for failed or degraded outcomes

### Requirement: Local output persistence
The system SHALL store all scan outputs and the consolidated summary report in a local result directory on the developer machine.

#### Scenario: Reports are available locally after scan
- **WHEN** scan execution ends
- **THEN** the system writes a timestamped local output directory containing raw artifacts and consolidated summary
