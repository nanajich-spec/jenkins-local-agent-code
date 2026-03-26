#!/usr/bin/env python3
"""Update the security-scan-pipeline job in Jenkins with new config.

Fetches the current config XML, updates parameters and pipeline script,
then pushes it back. Uses cookies for session-bound CSRF crumbs.
"""

import urllib.request
import urllib.error
import http.cookiejar
import base64
import json
import xml.etree.ElementTree as ET
import io
import os
import sys

jenkins_url = "http://132.186.17.22:32000"
user, password = "admin", "admin"
job_name = "security-scan-pipeline"

# Setup opener with cookies
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
auth = base64.b64encode(f"{user}:{password}".encode()).decode()

# -------------------------------------------------------------------
# Step 1: Get current config
# -------------------------------------------------------------------
print(f"Fetching current config for '{job_name}'...")
req = urllib.request.Request(
    f"{jenkins_url}/job/{job_name}/config.xml",
    headers={"Authorization": f"Basic {auth}"}
)
resp = opener.open(req)
config_xml = resp.read().decode()

tree = ET.ElementTree(ET.fromstring(config_xml))
root = tree.getroot()

# -------------------------------------------------------------------
# Step 2: Add new parameters if missing
# -------------------------------------------------------------------
params_el = root.find(".//parameterDefinitions")
existing_params = [p.find("name").text for p in params_el]
print(f"Existing params: {existing_params}")

new_params = {
    "SOURCE_UPLOAD_PATH": ("Path to uploaded source code (set by client)", ""),
    "SCAN_ID": ("Unique scan ID for this run (set by client)", ""),
    "REGISTRY_URL": ("Container registry URL", "132.186.17.22:5000"),
}

for name, (desc, default) in new_params.items():
    if name not in existing_params:
        param_el = ET.SubElement(params_el, "hudson.model.StringParameterDefinition")
        ET.SubElement(param_el, "name").text = name
        ET.SubElement(param_el, "description").text = desc
        ET.SubElement(param_el, "defaultValue").text = default
        ET.SubElement(param_el, "trim").text = "false"
        print(f"  Added param: {name}")
    else:
        print(f"  Param already exists: {name}")

# -------------------------------------------------------------------
# Step 3: Read pipeline script from file
# -------------------------------------------------------------------
script_dir = os.path.dirname(os.path.abspath(__file__))
pipeline_file = os.path.join(script_dir, "..", "pipelines", "security-scan-pipeline.groovy")

if not os.path.isfile(pipeline_file):
    print(f"ERROR: Pipeline script not found: {pipeline_file}")
    sys.exit(1)

with open(pipeline_file, "r") as f:
    new_script = f.read()

script_el = root.find(".//definition/script")
script_el.text = new_script
print("Updated pipeline script from file")

# -------------------------------------------------------------------
# Step 4: Serialize and push
# -------------------------------------------------------------------
output = io.StringIO()
tree.write(output, encoding="unicode", xml_declaration=False)
new_config = "<?xml version='1.1' encoding='UTF-8'?>\n" + output.getvalue()

# Get crumb with cookies
req = urllib.request.Request(
    f"{jenkins_url}/crumbIssuer/api/json",
    headers={"Authorization": f"Basic {auth}"}
)
resp = opener.open(req)
crumb_data = json.loads(resp.read().decode())

headers = {
    "Authorization": f"Basic {auth}",
    "Content-Type": "application/xml",
    crumb_data["crumbRequestField"]: crumb_data["crumb"],
}
req = urllib.request.Request(
    f"{jenkins_url}/job/{job_name}/config.xml",
    data=new_config.encode(),
    headers=headers,
    method="POST",
)
try:
    resp = opener.open(req)
    print(f"Job updated successfully (HTTP {resp.status})")
except urllib.error.HTTPError as e:
    print(f"Error: HTTP {e.code}")
    body = e.read().decode()
    # Try to extract error from HTML
    if "<pre>" in body:
        import re
        err_msg = re.findall(r"<pre[^>]*>(.*?)</pre>", body, re.DOTALL)
        for m in err_msg:
            print(f"  {m.strip()[:500]}")
    else:
        print(body[:500])
    sys.exit(1)
