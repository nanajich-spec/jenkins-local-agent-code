## ADDED Requirements

### Requirement: Supported language coverage baseline
The system SHALL define and enforce a minimum scan behavior for Python, Java, Node.js/React, C/C++, Kotlin, and HTML/static web projects.

#### Scenario: Supported language project is scanned
- **WHEN** a repository is detected as one of the supported language groups
- **THEN** the system executes the minimum required test, coverage, and security checks for that group

### Requirement: Multi-language repository handling
The system SHALL support repositories containing multiple language stacks and SHALL execute applicable adapters for each detected stack.

#### Scenario: Polyglot repository detected
- **WHEN** project contains more than one supported language ecosystem
- **THEN** the system runs all relevant adapters and aggregates results into one final report

### Requirement: Unsupported language fallback
The system SHALL handle unsupported languages with explicit non-silent reporting and actionable guidance.

#### Scenario: Unsupported language encountered
- **WHEN** no adapter matches a detected language or build ecosystem
- **THEN** the scan completes with degraded status and includes guidance for adding support or custom hooks

### Requirement: Extensible adapter contract
The system SHALL expose a documented adapter contract so additional language support can be added without reworking core orchestration.

#### Scenario: New language adapter is introduced
- **WHEN** maintainers add a new language adapter implementation
- **THEN** the adapter integrates through the contract and participates in standard reporting and gate evaluation
