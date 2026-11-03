"""Sets up Halo Plus in App Store Connect, so the app can sell it through the App Store.

    ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_PRIVATE_KEY="$(cat AuthKey.p8)" python3 tools/asc_iap_setup.py

Creates (or finds, so it's safe to run again):
  - the subscription group "Halo Plus", with its display name
  - the monthly subscription com.ralphgeb.halo.plus.monthly, with its name and description
  - its price: $0.99 in the US, the App Store's matching price elsewhere, £0.99 in the UK
  - availability in every territory
  - a review screenshot of the offer (replace it with a real screenshot before App Review)

That's everything "Ready to Submit" needs, which is what TestFlight and the sandbox need to sell
it. The Paid Apps Agreement must be active in App Store Connect › Business for any purchase to go
through. A product ID can never be used again, even after it's deleted.
"""
import hashlib
import io
import json
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.ralphgeb.halo"
PRODUCT_ID = "com.ralphgeb.halo.plus.monthly"
GROUP_NAME = "Halo Plus"
LOCALES = {
    "en-US": ("Halo Plus", "Every day, every graph and your own colors."),
    "en-GB": ("Halo Plus", "Every day, every graph and your own colours."),
}
BASE_TERRITORY, BASE_PRICE = "USA", "0.99"
OVERRIDES = {"GBR": "0.99"}


def token():
    key = os.environ["ASC_PRIVATE_KEY"].strip()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 1100,
                       "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"})


SESSION = requests.Session()


def call(method, path, body=None, ok=(200, 201, 204)):
    SESSION.headers["Authorization"] = f"Bearer {token()}"
    url = path if path.startswith("http") else API + path
    r = SESSION.request(method, url, json=body, timeout=60)
    if r.status_code not in ok:
        detail = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in r.json().get("errors", [])) if r.text else ""
        raise SystemExit(f"{method} {path} -> {r.status_code} {detail}")
    return r.json() if r.text else {}


def all_pages(path):
    out = []
    while path:
        page = call("GET", path)
        out += page.get("data", [])
        path = page.get("links", {}).get("next")
    return out


def rel(kind, id_):
    return {"data": {"type": kind, "id": id_}}


def main():
    apps = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        raise SystemExit(f"No app with bundle ID {BUNDLE_ID} in App Store Connect")
    app = apps[0]["id"]
    print("App", apps[0]["attributes"]["name"])

    # the group
    groups = all_pages(f"/v1/apps/{app}/subscriptionGroups")
    group = next((g["id"] for g in groups if g["attributes"]["referenceName"] == GROUP_NAME), None)
    if not group:
        group = call("POST", "/v1/subscriptionGroups", {"data": {
            "type": "subscriptionGroups", "attributes": {"referenceName": GROUP_NAME},
            "relationships": {"app": rel("apps", app)}}})["data"]["id"]
        print("Created group", GROUP_NAME)
    have = {l["attributes"]["locale"] for l in all_pages(f"/v1/subscriptionGroups/{group}/subscriptionGroupLocalizations")}
    for locale in LOCALES:
        if locale not in have:
            call("POST", "/v1/subscriptionGroupLocalizations", {"data": {
                "type": "subscriptionGroupLocalizations", "attributes": {"name": GROUP_NAME, "locale": locale},
                "relationships": {"subscriptionGroup": rel("subscriptionGroups", group)}}})
            print("Group name for", locale)

    # the subscription
    subs = all_pages(f"/v1/subscriptionGroups/{group}/subscriptions")
    sub = next((s["id"] for s in subs if s["attributes"]["productId"] == PRODUCT_ID), None)
    if not sub:
        sub = call("POST", "/v1/subscriptions", {"data": {
            "type": "subscriptions",
            "attributes": {"name": "Halo Plus Monthly", "productId": PRODUCT_ID, "subscriptionPeriod": "ONE_MONTH",
                           "familySharable": False, "groupLevel": 1,
                           "reviewNote": "Halo Plus unlocks earlier days, longer graphs, the cards under Balance, "
                                         "cardio load, the sleep bank, custom colors and app icons. Tap any locked "
                                         "card or Settings › Get Halo Plus."},
            "relationships": {"group": rel("subscriptionGroups", group)}}})["data"]["id"]
        print("Created subscription", PRODUCT_ID)
    have = {l["attributes"]["locale"] for l in all_pages(f"/v1/subscriptions/{sub}/subscriptionLocalizations")}
    for locale, (name, description) in LOCALES.items():
        if locale not in have:
            call("POST", "/v1/subscriptionLocalizations", {"data": {
                "type": "subscriptionLocalizations",
                "attributes": {"name": name, "description": description, "locale": locale},
                "relationships": {"subscription": rel("subscriptions", sub)}}})
            print("Name and description for", locale)

    # availability
    territories = [t["id"] for t in all_pages("/v1/territories?limit=200")]
    existing = call("GET", f"/v1/subscriptions/{sub}/subscriptionAvailability", ok=(200, 404))
    if not existing.get("data"):
        call("POST", "/v1/subscriptionAvailabilities", {"data": {
            "type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"subscription": rel("subscriptions", sub),
                              "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})
        print("Available in", len(territories), "territories")

    # prices
    priced = {p.get("relationships", {}).get("territory", {}).get("data", {}).get("id")
              for p in all_pages(f"/v1/subscriptions/{sub}/prices?include=territory&limit=200")}
    points = all_pages(f"/v1/subscriptions/{sub}/pricePoints?filter[territory]={BASE_TERRITORY}&limit=200")
    base = next((p for p in points if p["attributes"]["customerPrice"] == BASE_PRICE), None)
    if not base:
        raise SystemExit(f"No {BASE_PRICE} price point in {BASE_TERRITORY}")
    plan = {BASE_TERRITORY: base["id"]}
    for p in all_pages(f"/v1/subscriptionPricePoints/{base['id']}/equalizations?include=territory&limit=200"):
        plan[p["relationships"]["territory"]["data"]["id"]] = p["id"]
    for territory, price in OVERRIDES.items():
        match = next((p for p in all_pages(f"/v1/subscriptions/{sub}/pricePoints?filter[territory]={territory}&limit=200")
                      if p["attributes"]["customerPrice"] == price), None)
        if match:
            plan[territory] = match["id"]
    added = 0
    for territory, point in plan.items():
        if territory in priced:
            continue
        call("POST", "/v1/subscriptionPrices", {"data": {
            "type": "subscriptionPrices", "attributes": {"preserveCurrentPrice": False},
            "relationships": {"subscription": rel("subscriptions", sub),
                              "subscriptionPricePoint": rel("subscriptionPricePoints", point),
                              "territory": rel("territories", territory)}}})
        added += 1
    print("Prices set in", added, "territories" if added != 1 else "territory")

    # review screenshot
    shot = call("GET", f"/v1/subscriptions/{sub}/appStoreReviewScreenshot", ok=(200, 404))
    if not shot.get("data"):
        png = screenshot()
        made = call("POST", "/v1/subscriptionAppStoreReviewScreenshots", {"data": {
            "type": "subscriptionAppStoreReviewScreenshots",
            "attributes": {"fileName": "halo-plus.png", "fileSize": len(png)},
            "relationships": {"subscription": rel("subscriptions", sub)}}})["data"]
        for op in made["attributes"]["uploadOperations"]:
            part = png[op["offset"]:op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            r = requests.request(op["method"], op["url"], data=part, headers=headers, timeout=60)
            if r.status_code >= 300:
                raise SystemExit(f"Screenshot upload -> {r.status_code}")
        call("PATCH", f"/v1/subscriptionAppStoreReviewScreenshots/{made['id']}", {"data": {
            "type": "subscriptionAppStoreReviewScreenshots", "id": made["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(png).hexdigest()}}})
        print("Review screenshot uploaded")

    state = call("GET", f"/v1/subscriptions/{sub}")["data"]["attributes"].get("state")
    print("Halo Plus is", state)


def screenshot():
    """A plain picture of the offer, iPhone-sized, for App Review's reference."""
    from PIL import Image, ImageDraw, ImageFont
    w, h = 1290, 2796
    img = Image.new("RGB", (w, h), (9, 9, 9))
    d = ImageDraw.Draw(img)

    def font(size):
        for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/Helvetica.ttc"):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
        return ImageFont.load_default()

    d.ellipse([w / 2 - 150, 700, w / 2 + 150, 1000], outline=(242, 242, 237), width=40)
    lines = [("Halo Plus", 110, (242, 242, 237)), ("Every day, every card, made yours.", 52, (150, 150, 150)),
             ("Every earlier day, and longer graphs", 50, (242, 242, 237)),
             ("Heart zones, cardio load and trends", 50, (242, 242, 237)),
             ("Your sleep bank and schedule", 50, (242, 242, 237)),
             ("Your own colors and app icons", 50, (242, 242, 237)),
             ("Subscribe · $0.99 a month", 60, (9, 9, 9))]
    y = 1120
    for i, (text, size, colour) in enumerate(lines):
        f = font(size)
        tw = d.textlength(text, font=f)
        if i == len(lines) - 1:
            y += 80
            d.rounded_rectangle([120, y - 40, w - 120, y + 120], radius=40, fill=(242, 242, 237))
        d.text(((w - tw) / 2, y), text, font=f, fill=colour)
        y += size + 70
    out = io.BytesIO()
    img.save(out, format="PNG")
    return out.getvalue()


if __name__ == "__main__":
    for v in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"):
        if not os.environ.get(v):
            sys.exit(f"{v} is missing")
    main()
