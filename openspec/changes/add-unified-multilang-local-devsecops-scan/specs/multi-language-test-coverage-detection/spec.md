## ADDED Requirements

### Requirement: Language and build-system detection
The system SHALL detect the project language stack and associated build/test ecosystem using repository signals (for example manifest files, build files, and directory conventions).

#### Scenario: Project language is auto-detected
- **WHEN** scan initialization begins
- **THEN** the system identifies one or more applicable language adapters and records the detection basis

### Requirement: Python test framework selection
The system SHALL detect Python test framework usage and run tests with `pytest` when configured, otherwise run `unittest` discovery when Python tests are present.

#### Scenario: Python project with pytest configuration
- **WHEN** Python files and pytest configuration are detected
- **THEN** the system runs tests with pytest and captures test and coverage outputs

#### Scenario: Python project without pytest configuration
- **WHEN** Python files and test directories are detected but pytest configuration is absent
- **THEN** the system runs unittest discovery and captures test and coverage outputs when available

### Requirement: Test directory discovery
The system SHALL detect test directories and files per language conventions before executing tests.

#### Scenario: Standard test folder exists
- **WHEN** repository contains standard test paths (for example `tests/`, `test/`, `src/test`)
- **THEN** the system includes those paths in test execution planning and reports which paths were used

### Requirement: Coverage normalization
The system SHALL normalize coverage results from supported language tools into a common summary model for the final report.

#### Scenario: Coverage collected from language-native tools
- **WHEN** language-specific coverage outputs are generated
- **THEN** the system converts them to a normalized coverage summary including overall percentage and missing coverage indicators

### Requirement: Missing coverage visibility
The system SHALL not silently ignore missing coverage and SHALL report unavailable coverage as an explicit warning state.

#### Scenario: Coverage tooling unavailable
- **WHEN** tests run but no compatible coverage artifact can be produced
- **THEN** the final report marks coverage as unavailable with remediation guidance
