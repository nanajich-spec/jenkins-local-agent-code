#!/usr/bin/env python3
"""Create the security-scan-pipeline job in Jenkins via REST API."""

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

# Read job config XML from file
script_dir = os.path.dirname(os.path.abspath(__file__))
config_path = os.path.join(script_dir, "..", "config", "pipeline-job-config.xml")
with open(config_path, "r") as f:
    job_config = f.read()

headers["Content-Type"] = "application/xml"
data = job_config.encode()
job_name = "security-scan-pipeline"

# Check if job exists
try:
    check_req = urllib.request.Request(
        f"{jenkins_url}/job/{job_name}/api/json",
        headers={"Authorization": f"Basic {auth}"}
    )
    opener.open(check_req)
    print(f"Job '{job_name}' exists, updating...")
    req2 = urllib.request.Request(
        f"{jenkins_url}/job/{job_name}/config.xml",
        data=data, headers=headers, method="POST"
    )
    resp2 = opener.open(req2)
    print(f"Job updated successfully (HTTP {resp2.status})")
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"Creating job: {job_name}")
        req2 = urllib.request.Request(
            f"{jenkins_url}/createItem?name={job_name}",
            data=data, headers=headers, method="POST"
        )
        try:
            resp2 = opener.open(req2)
            print(f"Job created successfully (HTTP {resp2.status})")
        except urllib.error.HTTPError as e2:
            print(f"Error creating job: HTTP {e2.code}")
            print(e2.read().decode()[:500])
            sys.exit(1)
    else:
        print(f"Error checking job: HTTP {e.code}")
        sys.exit(1)
