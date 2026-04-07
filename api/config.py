"""
DevSecOps Security Scan API — Configuration
Centralises all environment-driven settings.
"""
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # ── API server ─────────────────────────────────────────
    api_host: str = "0.0.0.0"
    api_port: int = 9091
    api_version: str = "2.0.0"
    log_level: str = "info"

    # ── Jenkins ────────────────────────────────────────────
    jenkins_url: str = "http://132.186.17.25:32000"
    jenkins_user: str = "admin"
    jenkins_token: str = ""          # Jenkins API token (set via env)

    # ── Storage ────────────────────────────────────────────
    upload_dir: str = "/opt/scan-uploads"
    reports_dir: str = "/opt/scan-reports"
    serve_dir: str = "/opt/scan-client-server"

    # ── Dynamic agent script ───────────────────────────────
    dynamic_agent_script: str = (
        "/tmp/jenkins-local-agent-code/jenkins/scripts/dynamic-agent-manager.sh"
    )
    max_dynamic_agents: int = 10
    agent_creation_timeout: int = 120  # seconds

    # ── Registry / other services ──────────────────────────
    registry: str = "132.186.17.22:5000"
    sonarqube_url: str = "http://132.186.17.22:32001"

    # ── Pipelines ──────────────────────────────────────────
    default_pipeline: str = "security-scan-pipeline"
    known_pipelines: list[str] = [
        "security-scan-pipeline",
        "devsecops-pipeline",
        "ci-cd-pipeline",
    ]

    # ── Upload limits ──────────────────────────────────────
    max_upload_bytes: int = 1024 * 1024 * 1024  # 1 GB


settings = Settings()
