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

# ── Pipeline jobs to create ──
# Each entry: (job_name, config_xml_path OR pipeline_script_path, config_type)
# config_type: "xml" = use full XML config, "jenkinsfile" = wrap Jenkinsfile in XML
PIPELINE_JOBS = [
    {
        "name": "security-scan-pipeline",
        "config": os.path.join(script_dir, "..", "pipelines", "security-scan-pipeline.groovy"),
        "type": "jenkinsfile",
        "description": "End-to-End Security Scanning Pipeline (Trivy, SAST, SCA, secrets, SBOM, SonarQube)",
    },
    {
        "name": "ci-cd-pipeline",
        "config": os.path.join(script_dir, "..", "pipelines", "ci-cd", "Jenkinsfile"),
        "type": "jenkinsfile",
        "description": "Full CI/CD Pipeline (build, test, lint, security, deploy)",
    },
    {
        "name": "devsecops-pipeline",
        "config": os.path.join(script_dir, "..", "pipelines", "devsecops", "Jenkinsfile"),
        "type": "jenkinsfile",
        "description": "Full DevSecOps Pipeline (test, SBOM, SonarQube, security)",
    },
]


def make_xml_config(jenkinsfile_path, description):
    """Wrap a Jenkinsfile into Jenkins pipeline job XML config."""
    with open(jenkinsfile_path, "r") as f:
        script_content = f.read()

    # Escape for CDATA (replace ]]> if present)
    script_content = script_content.replace("]]>", "]]]]><![CDATA[>")

    return f"""<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>{description}</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
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
        job_config = make_xml_config(config_path, job_info["description"])

    data = job_config.encode()

    # Fresh crumb + cookie jar for each request (crumb is session-bound)
    fresh_cj = http.cookiejar.CookieJar()
    fresh_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(fresh_cj))
    crumb_req = urllib.request.Request(
        f"{jenkins_url}/crumbIssuer/api/json",
        headers={"Authorization": f"Basic {auth}"},
    )
    crumb_resp = fresh_opener.open(crumb_req)
    crumb_data = json.loads(crumb_resp.read().decode())

    post_headers = {
        "Authorization": f"Basic {auth}",
        "Content-Type": "application/xml",
        crumb_data["crumbRequestField"]: crumb_data["crumb"],
    }

    # Check if job exists
    try:
        check_req = urllib.request.Request(
            f"{jenkins_url}/job/{job_name}/api/json",
            headers={"Authorization": f"Basic {auth}"},
        )
        fresh_opener.open(check_req)
        print(f"  Job '{job_name}' exists — updating...")
        req2 = urllib.request.Request(
            f"{jenkins_url}/job/{job_name}/config.xml",
            data=data,
            headers=post_headers,
            method="POST",
        )
        resp2 = fresh_opener.open(req2)
        print(f"  Job '{job_name}' updated successfully (HTTP {resp2.status})")
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"  Creating job: {job_name}")
            req2 = urllib.request.Request(
                f"{jenkins_url}/createItem?name={job_name}",
                data=data,
                headers=post_headers,
                method="POST",
            )
            try:
                resp2 = fresh_opener.open(req2)
                print(f"  Job '{job_name}' created successfully (HTTP {resp2.status})")
                return True
            except urllib.error.HTTPError as e2:
                print(f"  ERROR creating '{job_name}': HTTP {e2.code}")
                print(f"  {e2.read().decode()[:500]}")
                return False
        else:
            print(f"  ERROR checking '{job_name}': HTTP {e.code}")
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
