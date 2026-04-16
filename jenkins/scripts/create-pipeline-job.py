#!/usr/bin/env python3
"""Create all pipeline jobs in Jenkins via REST API.

Creates 3 pipeline jobs:
  1. security-scan-pipeline  — Security scans (Trivy, SAST, SCA, secrets)
  2. ci-cd-pipeline          — Full CI/CD (build, test, lint, security, deploy)
  3. devsecops-pipeline      — Full DevSecOps (test, SBOM, SonarQube, security)
"""

import json
import os
import urllib.request
import urllib.parse
import http.cookiejar
import base64
import sys

jenkins_url = "http://132.186.17.22:32000"
user, password = "admin", "admin"

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
auth = base64.b64encode(f"{user}:{password}".encode()).decode()
headers = {"Authorization": f"Basic {auth}"}

# Get crumb
req = urllib.request.Request(f"{jenkins_url}/crumbIssuer/api/json", headers=headers)
resp = opener.open(req)
crumb_data = json.loads(resp.read().decode())
headers[crumb_data["crumbRequestField"]] = crumb_data["crumb"]

script_dir = os.path.dirname(os.path.abspath(__file__))


def _param_xml(params):
    """Build the <hudson.model.ParametersDefinitionProperty> XML block from a list of param dicts.

    Each dict must have: type (string|choice|boolean), name, default, description.
    Choice params additionally need: choices (list of strings, first = default).
    """
    lines = [
        "  <properties>",
        "    <hudson.model.ParametersDefinitionProperty>",
        "      <parameterDefinitions>",
    ]
    for p in params:
        desc = p.get("description", "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        name = p["name"]
        if p["type"] == "string":
            default = str(p.get("default", "")).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            lines += [
                "        <hudson.model.StringParameterDefinition>",
                f"          <name>{name}</name>",
                f"          <defaultValue>{default}</defaultValue>",
                f"          <description>{desc}</description>",
                "          <trim>false</trim>",
                "        </hudson.model.StringParameterDefinition>",
            ]
        elif p["type"] == "boolean":
            default = "true" if p.get("default", False) else "false"
            lines += [
                "        <hudson.model.BooleanParameterDefinition>",
                f"          <name>{name}</name>",
                f"          <defaultValue>{default}</defaultValue>",
                f"          <description>{desc}</description>",
                "        </hudson.model.BooleanParameterDefinition>",
            ]
        elif p["type"] == "choice":
            choices_xml = "".join(f"<string>{c}</string>" for c in p["choices"])
            lines += [
                "        <hudson.model.ChoiceParameterDefinition>",
                f"          <name>{name}</name>",
                f"          <choices>{choices_xml}</choices>",
                f"          <description>{desc}</description>",
                "        </hudson.model.ChoiceParameterDefinition>",
            ]
    lines += [
        "      </parameterDefinitions>",
        "    </hudson.model.ParametersDefinitionProperty>",
        "  </properties>",
    ]
    return "\n".join(lines)


# ── Parameter definitions per pipeline ──
# These MUST match the declarative parameters{} block in each Groovy script so
# Jenkins always has them registered (enables /buildWithParameters from day 0).

PARAMS_SECURITY = [
    {"type": "string",  "name": "IMAGE_NAME",           "default": "",                   "description": "Image name to scan"},
    {"type": "string",  "name": "IMAGE_TAG",            "default": "latest",             "description": "Image tag"},
    {"type": "choice",  "name": "SCAN_TYPE",            "choices": ["code-only", "image-only", "full", "k8s-manifests"], "description": "Scan type"},
    {"type": "boolean", "name": "FAIL_ON_CRITICAL",     "default": True,                 "description": "Fail on CRITICAL vulns"},
    {"type": "boolean", "name": "SCAN_REGISTRY_IMAGES", "default": False,                "description": "Scan all registry images"},
    {"type": "boolean", "name": "GENERATE_SBOM",        "default": True,                 "description": "Generate SBOM (CycloneDX + SPDX)"},
    {"type": "string",  "name": "SCAN_ID",              "default": "",                   "description": "Unique scan ID"},
    {"type": "string",  "name": "SOURCE_UPLOAD_PATH",   "default": "",                   "description": "Uploaded source path"},
    {"type": "string",  "name": "AGENT_LABEL",          "default": "local-security-agent","description": "Agent label"},
    {"type": "string",  "name": "REGISTRY_URL",         "default": "",                   "description": "Override registry URL"},
]

PARAMS_CICD = [
    {"type": "string",  "name": "GIT_REPO",             "default": "",                    "description": "Git repo URL (leave blank for workspace/SCM)"},
    {"type": "string",  "name": "GIT_BRANCH",           "default": "main",                "description": "Branch to build"},
    {"type": "choice",  "name": "LANGUAGE",             "choices": ["auto", "python", "java-maven", "java-gradle", "nodejs", "react", "angular", "vue", "go", "dotnet"], "description": "Project language"},
    {"type": "string",  "name": "IMAGE_NAME",           "default": "",                    "description": "Docker image name (leave blank to skip Docker build)"},
    {"type": "string",  "name": "IMAGE_TAG",            "default": "latest",              "description": "Docker image tag"},
    {"type": "string",  "name": "REGISTRY",             "default": "132.186.17.22:5000",  "description": "Container registry URL"},
    {"type": "string",  "name": "DOCKERFILE_PATH",      "default": "Dockerfile",          "description": "Dockerfile path"},
    {"type": "boolean", "name": "RUN_UNIT_TESTS",       "default": True,                  "description": "Run unit tests"},
    {"type": "boolean", "name": "RUN_INTEGRATION_TESTS","default": False,                 "description": "Run integration tests"},
    {"type": "boolean", "name": "RUN_E2E_TESTS",        "default": False,                 "description": "Run end-to-end tests"},
    {"type": "string",  "name": "COVERAGE_THRESHOLD",   "default": "70",                  "description": "Minimum code coverage %"},
    {"type": "boolean", "name": "RUN_LINT",             "default": True,                  "description": "Run linting/code quality"},
    {"type": "boolean", "name": "RUN_SECURITY_SCAN",    "default": True,                  "description": "Run security scanning (Trivy)"},
    {"type": "boolean", "name": "RUN_SONARQUBE",        "default": False,                 "description": "Run SonarQube analysis"},
    {"type": "boolean", "name": "FAIL_ON_CRITICAL",     "default": True,                  "description": "Fail on CRITICAL vulnerabilities"},
    {"type": "boolean", "name": "DEPLOY_TO_K8S",        "default": False,                 "description": "Deploy to Kubernetes"},
    {"type": "choice",  "name": "DEPLOY_ENV",           "choices": ["staging", "production"], "description": "Deployment environment"},
    {"type": "string",  "name": "K8S_NAMESPACE",        "default": "",                    "description": "Kubernetes namespace for deployment"},
    {"type": "string",  "name": "AGENT_LABEL",          "default": "local-security-agent","description": "Jenkins agent label"},
    {"type": "string",  "name": "TIMEOUT_MINUTES",      "default": "60",                  "description": "Pipeline timeout (minutes)"},
    {"type": "string",  "name": "SCAN_ID",              "default": "",                    "description": "Unique scan identifier"},
    {"type": "string",  "name": "SOURCE_UPLOAD_PATH",   "default": "",                    "description": "Path to uploaded source on server"},
]

PARAMS_DEVSECOPS = [
    {"type": "string",  "name": "GIT_REPO",               "default": "file:///tmp/jenkins-local-agent-code", "description": "Git repo URL (leave blank for workspace SCM)"},
    {"type": "string",  "name": "GIT_BRANCH",             "default": "main",                "description": "Branch to build"},
    {"type": "choice",  "name": "LANGUAGE",               "choices": ["auto", "python", "java-maven", "java-gradle", "nodejs", "react", "angular", "go", "dotnet"], "description": "Language (auto-detect if unsure)"},
    {"type": "string",  "name": "IMAGE_NAME",             "default": "",                    "description": "Docker image name (blank = skip image build)"},
    {"type": "string",  "name": "IMAGE_TAG",              "default": "latest",              "description": "Docker image tag"},
    {"type": "string",  "name": "REGISTRY",               "default": "132.186.17.22:5000",  "description": "Container registry"},
    {"type": "string",  "name": "DOCKERFILE_PATH",        "default": "Dockerfile",          "description": "Dockerfile path (Containerfile also accepted)"},
    {"type": "boolean", "name": "RUN_UNIT_TESTS",         "default": True,                  "description": "Run unit tests"},
    {"type": "boolean", "name": "RUN_INTEGRATION_TESTS",  "default": False,                 "description": "Run integration tests"},
    {"type": "string",  "name": "COVERAGE_THRESHOLD",     "default": "70",                  "description": "Min code coverage %"},
    {"type": "string",  "name": "PYTEST_ARGS",            "default": "",                    "description": "Extra pytest arguments"},
    {"type": "boolean", "name": "RUN_TRIVY_SCAN",         "default": True,                  "description": "Trivy filesystem + image scan"},
    {"type": "boolean", "name": "RUN_SECRET_DETECTION",   "default": True,                  "description": "Secret detection scan"},
    {"type": "boolean", "name": "RUN_K8S_MANIFEST_SCAN",  "default": True,                  "description": "K8s manifest scan (warn if missing)"},
    {"type": "boolean", "name": "RUN_DOCKERFILE_LINT",    "default": True,                  "description": "Hadolint Dockerfile lint (warn if missing)"},
    {"type": "boolean", "name": "RUN_OWASP_CHECK",        "default": False,                 "description": "OWASP Dependency-Check"},
    {"type": "boolean", "name": "RUN_GRYPE",              "default": False,                 "description": "Grype vulnerability scan"},
    {"type": "boolean", "name": "FAIL_ON_CRITICAL",       "default": True,                  "description": "Fail build on CRITICAL vulns"},
    {"type": "boolean", "name": "GENERATE_SBOM",          "default": True,                  "description": "Generate CycloneDX SBOM"},
    {"type": "boolean", "name": "RUN_SONARQUBE",          "default": True,                  "description": "SonarQube analysis"},
    {"type": "string",  "name": "SONAR_PROJECT_KEY",      "default": "",                    "description": "SonarQube project key (auto if blank)"},
    {"type": "boolean", "name": "DEPLOY_TO_K8S",          "default": False,                 "description": "Deploy to Kubernetes"},
    {"type": "string",  "name": "K8S_NAMESPACE",          "default": "",                    "description": "Kubernetes namespace"},
    {"type": "string",  "name": "K8S_MANIFESTS_DIR",      "default": "cat-deployments",     "description": "Path to K8s manifests"},
    {"type": "string",  "name": "AGENT_LABEL",            "default": "local-security-agent","description": "Jenkins agent label"},
    {"type": "string",  "name": "TIMEOUT_MINUTES",        "default": "120",                 "description": "Pipeline timeout (minutes)"},
    {"type": "boolean", "name": "FORCE_TOOL_REINSTALL",   "default": False,                 "description": "Force reinstall of agent tools"},
    {"type": "string",  "name": "SCAN_ID",                "default": "",                    "description": "Unique scan identifier"},
    {"type": "string",  "name": "SOURCE_UPLOAD_PATH",     "default": "",                    "description": "Path to uploaded source on server"},
]

# ── Pipeline jobs to create ──
PIPELINE_JOBS = [
    {
        "name": "security-scan-pipeline",
        "config": os.path.join(script_dir, "..", "pipelines", "security-scan-pipeline.groovy"),
        "type": "jenkinsfile",
        "description": "End-to-End Security Scanning Pipeline (Trivy, SAST, SCA, secrets, SBOM, SonarQube)",
        "params": PARAMS_SECURITY,
    },
    {
        "name": "ci-cd-pipeline",
        "config": os.path.join(script_dir, "..", "pipelines", "ci-cd", "Jenkinsfile"),
        "type": "jenkinsfile",
        "description": "Full CI/CD Pipeline (build, test, lint, security, deploy)",
        "params": PARAMS_CICD,
    },
    {
        "name": "devsecops-pipeline",
        "config": os.path.join(script_dir, "..", "pipelines", "devsecops", "Jenkinsfile"),
        "type": "jenkinsfile",
        "description": "Full DevSecOps Pipeline (test, SBOM, SonarQube, security)",
        "params": PARAMS_DEVSECOPS,
    },
]


def make_xml_config(jenkinsfile_path, description, params=None):
    """Wrap a Jenkinsfile into Jenkins pipeline job XML config.

    Parameters are injected directly into the <properties> block so Jenkins
    registers them immediately — without needing a first warm-up build.
    This enables /buildWithParameters from the very first invocation.
    """
    with open(jenkinsfile_path, "r") as f:
        script_content = f.read()

    # Escape for CDATA (replace ]]> if present)
    script_content = script_content.replace("]]>", "]]]]><![CDATA[>")

    properties_xml = _param_xml(params) if params else "  <properties/>"

    return f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>{description}</description>
  <keepDependencies>false</keepDependencies>
{properties_xml}
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[{script_content}]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>"""


def create_or_update_job(job_info):
    """Create or update a single Jenkins pipeline job."""
    job_name = job_info["name"]
    config_path = job_info["config"]

    if not os.path.isfile(config_path):
        print(f"  SKIP: Config file not found: {config_path}")
        return False

    if job_info["type"] == "xml":
        with open(config_path, "r") as f:
            job_config = f.read()
    else:
        job_config = make_xml_config(config_path, job_info["description"], job_info.get("params"))

    data = job_config.encode("utf-8")

    # Fresh cookie jar + opener per job (crumb is session-bound)
    fresh_cj = http.cookiejar.CookieJar()
    fresh_opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(fresh_cj)
    )
    crumb_req = urllib.request.Request(
        f"{jenkins_url}/crumbIssuer/api/json",
        headers={"Authorization": f"Basic {auth}"},
    )
    crumb_resp = fresh_opener.open(crumb_req)
    crumb_data = json.loads(crumb_resp.read().decode())

    post_headers = {
        "Authorization": f"Basic {auth}",
        "Content-Type": "application/xml; charset=utf-8",
        crumb_data["crumbRequestField"]: crumb_data["crumb"],
    }

    # Check if job exists (use same opener for session continuity)
    try:
        check_req = urllib.request.Request(
            f"{jenkins_url}/job/{job_name}/api/json",
            headers={"Authorization": f"Basic {auth}"},
        )
        fresh_opener.open(check_req)
        job_exists = True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            job_exists = False
        else:
            print(f"  ERROR checking '{job_name}': HTTP {e.code}")
            return False

    if job_exists:
        print(f"  Job '{job_name}' exists — updating...")
        url = f"{jenkins_url}/job/{job_name}/config.xml"
    else:
        print(f"  Creating job: {job_name}")
        url = f"{jenkins_url}/createItem?name={job_name}"

    try:
        req2 = urllib.request.Request(url, data=data, headers=post_headers, method="POST")
        resp2 = fresh_opener.open(req2)
        action = "updated" if job_exists else "created"
        print(f"  Job '{job_name}' {action} successfully (HTTP {resp2.status})")
        return True
    except urllib.error.HTTPError as e2:
        print(f"  ERROR: HTTP {e2.code}")
        print(f"  {e2.read().decode('utf-8', errors='replace')[:500]}")
        return False


# ── Main: Create all pipeline jobs ──
print("=" * 60)
print("  Creating/Updating ALL Pipeline Jobs in Jenkins")
print("=" * 60)
print(f"  Jenkins: {jenkins_url}")
print(f"  Jobs:    {len(PIPELINE_JOBS)}")
print("=" * 60)

results = []
for job_info in PIPELINE_JOBS:
    print(f"\n[{job_info['name']}]")
    success = create_or_update_job(job_info)
    results.append((job_info["name"], success))

print("\n" + "=" * 60)
print("  Summary:")
for name, ok in results:
    status = "OK" if ok else "FAILED"
    print(f"    {status:8s} {name}")
print("=" * 60)
