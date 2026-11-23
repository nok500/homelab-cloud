#!/usr/bin/env python3
"""End-to-end Argo CD SSO login through Keycloak, as a browser does it (ADR 0012; make verify section 10).

  1. GET  https://argocd.lab.macpro/auth/login         -> redirect to Keycloak's login page (realm lab)
  2. POST the login form with the user's password      -> Keycloak redirects back to /auth/callback
  3. Argo CD exchanges the code (client secret) and sets its session cookie
  4. GET  /api/v1/session/userinfo                     -> logged in, with the expected group
  5. GET  /api/v1/applications                         -> the group's RBAC role lets it list Applications

Usage: SSO_USER=labadmin SSO_PASSWORD=... sso-login-test.py <root-ca.crt> [expected-group]
TLS is verified against the lab root CA at every hop. Prints one line; exit 0 only if every step held.
"""
import html
import http.cookiejar
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request

ARGOCD = "https://argocd.lab.macpro"


def main() -> int:
    ca = sys.argv[1]
    group = sys.argv[2] if len(sys.argv) > 2 else "argocd-admins"
    user, password = os.environ["SSO_USER"], os.environ["SSO_PASSWORD"]

    ctx = ssl.create_default_context(cafile=ca)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPCookieProcessor(jar))

    # 1. Argo CD sends us to Keycloak
    with opener.open(f"{ARGOCD}/auth/login?return_url={urllib.parse.quote(ARGOCD + '/applications')}", timeout=20) as r:
        page, login_url = r.read().decode(), r.geturl()
    if "/realms/lab/" not in login_url:
        print(f"step 1: expected Keycloak's lab realm, landed on {login_url}")
        return 1
    m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page) \
        or re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
    if not m:
        print("step 1: no Keycloak login form on the page")
        return 1

    # 2+3. submit the form; Keycloak -> /auth/callback -> Argo CD session cookie
    form = urllib.parse.urlencode({"username": user, "password": password, "credentialId": ""}).encode()
    with opener.open(html.unescape(m.group(1)), data=form, timeout=20) as r:
        final = r.geturl()
    if not any(c.name.startswith("argocd.token") for c in jar):
        print(f"step 2/3: no Argo CD session after the login (ended on {final})")
        return 1

    # 4. who does Argo CD think we are?
    with opener.open(f"{ARGOCD}/api/v1/session/userinfo", timeout=20) as r:
        info = json.load(r)
    if not info.get("loggedIn") or group not in (info.get("groups") or []):
        print(f"step 4: userinfo {info}")
        return 1

    # 5. RBAC: the group's role can list Applications
    with opener.open(f"{ARGOCD}/api/v1/applications", timeout=20) as r:
        apps = json.load(r).get("items") or []
    if not apps:
        print("step 5: logged in, but Argo CD lists no Applications (RBAC)")
        return 1

    print(f"{user} logged in via Keycloak, groups {info['groups']}, sees {len(apps)} Applications")
    return 0


if __name__ == "__main__":
    sys.exit(main())
