#!/usr/bin/env python3
"""End-to-end Argo Workflows SSO login through Keycloak, as a browser does it (ADR 0015; make verify section 13).

  1. GET  https://workflows.lab.macpro/oauth2/redirect -> redirect to Keycloak's login page (realm lab)
  2. POST the login form with the user's password      -> Keycloak redirects back to /oauth2/callback
  3. The server exchanges the code (client secret) and sets its `authorization` cookie
  4. GET  /api/v1/userinfo                             -> logged in, with the group, mapped to service account argo-admin
  5. GET  /api/v1/workflows/ci                         -> that account may list the workflows in ci

Usage: SSO_USER=labadmin SSO_PASSWORD=... argo-workflows-sso-test.py <root-ca.crt>
TLS is verified against the lab root CA at every hop. Prints one line; exit 0 only if every step held.
"""
import html
import http.cookiejar
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

WORKFLOWS = "https://workflows.lab.macpro"
GROUP, ACCOUNT = "argo-workflows-admins", "argo-admin"


def main() -> int:
    ca = sys.argv[1]
    user, password = os.environ["SSO_USER"], os.environ["SSO_PASSWORD"]

    ctx = ssl.create_default_context(cafile=ca)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept", "text/html,application/json")]   # like a browser

    # 1. the server sends us to Keycloak
    with opener.open(f"{WORKFLOWS}/oauth2/redirect?redirect={urllib.parse.quote(WORKFLOWS + '/')}", timeout=20) as r:
        page, login_url = r.read().decode(), r.geturl()
    if "/realms/lab/" not in login_url:
        print(f"step 1: expected Keycloak's lab realm, landed on {login_url}")
        return 1
    m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page) \
        or re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
    if not m:
        print("step 1: no Keycloak login form on the page")
        return 1

    # 2+3. submit the form; Keycloak -> /oauth2/callback -> the authorization cookie (only the cookie matters,
    # not the page the redirect chain ends on)
    form = urllib.parse.urlencode({"username": user, "password": password, "credentialId": ""}).encode()
    try:
        with opener.open(html.unescape(m.group(1)), data=form, timeout=20) as r:
            final = r.geturl()
    except urllib.error.HTTPError as e:
        final = f"{e.url} (HTTP {e.code})"
    if not any(c.name == "authorization" for c in jar):
        print(f"step 2/3: no Argo Workflows session after the login (ended on {final})")
        return 1

    # 4. who does the server think we are, and which account does SSO RBAC give us?
    with opener.open(f"{WORKFLOWS}/api/v1/userinfo", timeout=20) as r:
        me = json.load(r)
    if GROUP not in (me.get("groups") or []):
        print(f"step 4: logged in, but groups are {me.get('groups')} (expected {GROUP})")
        return 1
    if me.get("serviceAccountName") not in (None, ACCOUNT):
        print(f"step 4: mapped to service account {me.get('serviceAccountName')}, expected {ACCOUNT}")
        return 1

    # 5. the account's RBAC: list the workflows in ci
    try:
        with opener.open(f"{WORKFLOWS}/api/v1/workflows/ci?listOptions.limit=1", timeout=20) as r:
            json.load(r)
    except urllib.error.HTTPError as e:
        print(f"step 5: listing workflows in ci gave HTTP {e.code}")
        return 1

    print(f"{user} logged in via Keycloak, groups incl. {GROUP} -> {ACCOUNT}, lists the workflows in ci")
    return 0


if __name__ == "__main__":
    sys.exit(main())
