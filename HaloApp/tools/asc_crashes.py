"""Fetches the crash reports testers shared from TestFlight (the "Share" button after a crash)
and writes the useful part of the newest few to HaloApp/screens/crashes.txt: when, device, iOS,
build, the exception and the crashed thread's stack. Tester details are left out."""
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
BUNDLE = "com.ralphgeb.halo"


def token():
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 1100,
                       "aud": "appstoreconnect-v1"},
                      os.environ["ASC_PRIVATE_KEY"].strip(), algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


def get(path, params=None):
    r = requests.get(path if path.startswith("http") else API + path, params=params,
                     headers={"Authorization": f"Bearer {token()}"}, timeout=60)
    print(f"GET {path} -> {r.status_code}")
    if r.status_code != 200:
        print(r.text[:800])
        return None
    return r.json()


def useful(text):
    """The header lines that matter and every thread's stack, without personal details."""
    keep, out = ("Hardware Model", "OS Version", "Version:", "Code Type", "Exception Type",
                 "Exception Codes", "Termination Reason", "Triggered by Thread", "Crashed Thread",
                 "Date/Time", "Application Specific Information"), []
    in_thread = False
    for line in text.splitlines():
        if line.startswith(keep):
            out.append(line)
        if line.startswith("Thread ") or line.startswith("Last Exception Backtrace"):
            in_thread = True
        if in_thread:
            out.append(line)
            if line.strip() == "":
                in_thread = False
        if line.startswith("Binary Images"):
            break
    return "\n".join(out)


apps = get("/v1/apps", {"filter[bundleId]": BUNDLE})
if not apps or not apps.get("data"):
    sys.exit("App not found")
app = apps["data"][0]["id"]
subs = get(f"/v1/apps/{app}/betaFeedbackCrashSubmissions", {"limit": 5, "sort": "-createdDate"})
os.makedirs("HaloApp/screens", exist_ok=True)
with open("HaloApp/screens/crashes.txt", "w") as f:
    if not subs:
        f.write("Couldn't read crash submissions (see the workflow log).\n")
        sys.exit(0)
    for s in subs.get("data", []):
        a = s.get("attributes", {})
        f.write("=" * 70 + "\n")
        for k in ("createdDate", "deviceModel", "osVersion", "appPlatform", "comment"):
            if a.get(k):
                f.write(f"{k}: {a[k]}\n")
        log = get(f"/v1/betaFeedbackCrashSubmissions/{s['id']}/crashLog")
        text = ((log or {}).get("data") or {}).get("attributes", {}).get("logText") or ""
        f.write(useful(text) if text else "(no crash log attached)\n")
        f.write("\n")
print(open("HaloApp/screens/crashes.txt").read()[:6000])
