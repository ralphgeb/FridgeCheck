"""Revoke the Apple Development certificates that CI runs create.

Every TestFlight run starts on a fresh Mac, and Xcode signs the archive with a new
development certificate made through the App Store Connect API. Apple allows only a few,
so without clean-up the runs soon fail with "maximum number of certificates".

Only development certificates named "Created via API" are touched: the ones a Mac creates
for itself (named after the person or the Mac) and every distribution certificate are left alone.
The builds already on TestFlight don't depend on these certificates.
"""
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"].strip()
    issuer = os.environ["ASC_ISSUER_ID"].strip()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def main() -> int:
    headers = {"Authorization": f"Bearer {token()}"}
    r = requests.get(f"{API}/certificates", headers=headers, params={"limit": 200}, timeout=30)
    if r.status_code != 200:
        print(f"::warning::Couldn't list certificates ({r.status_code}); skipping clean-up")
        return 0
    revoked = 0
    for cert in r.json().get("data", []):
        a = cert.get("attributes", {})
        kind = (a.get("certificateType") or "").upper()
        label = f"{a.get('name') or ''} {a.get('displayName') or ''}".lower()
        if "DEVELOPMENT" not in kind or "created via api" not in label:
            continue
        d = requests.delete(f"{API}/certificates/{cert['id']}", headers=headers, timeout=30)
        if d.status_code in (200, 204):
            revoked += 1
        else:
            print(f"::warning::Couldn't revoke a CI certificate ({d.status_code})")
    print(f"Revoked {revoked} development certificate(s) created by earlier CI runs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
