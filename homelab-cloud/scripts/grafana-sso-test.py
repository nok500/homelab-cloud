#!/usr/bin/env python3
"""End-to-end Grafana SSO login through Keycloak, as a browser does it (ADR 0014; make verify section 12).

  1. GET  https://grafana.lab.macpro/login/generic_oauth -> redirect to Keycloak's login page (realm lab)
  2. POST the login form with the user's password        -> Keycloak redirects back to /login/generic_oauth
  3. Grafana exchanges the code (client secret, PKCE) and sets its session cookie
  4. GET  /api/user                                       -> logged in as that user
  5. GET  /api/user/orgs                                  -> role Admin in the main org (group grafana-admins)

Usage: SSO_USER=labadmin SSO_PASSWORD=... grafana-sso-test.py <root-ca.crt> [expected-role]
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

GRAFANA = "https://grafana.lab.macpro"


def main() -> int:
    ca = sys.argv[1]
    role = sys.argv[2] if len(sys.argv) > 2 else "Admin"
    user, password = os.environ["SSO_USER"], os.environ["SSO_PASSWORD"]

    ctx = ssl.create_default_context(cafile=ca)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx), urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("Accept", "text/html,application/json")]   # like a browser

    # 1. Grafana sends us to Keycloak
    with opener.open(f"{GRAFANA}/login/generic_oauth", timeout=20) as r:
        page, login_url = r.read().decode(), r.geturl()
    if "/realms/lab/" not in login_url:
        print(f"step 1: expected Keycloak's lab realm, landed on {login_url}")
        return 1
    m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', page) \
        or re.search(r'action="([^"]*login-actions/authenticate[^"]*)"', page)
    if not m:
        print("step 1: no Keycloak login form on the page")
        return 1

    # 2+3. submit the form; Keycloak -> Grafana's callback -> session cookie. Like the Argo CD test, only the
    # cookie matters, not the page the redirect chain ends on.
    form = urllib.parse.urlencode({"username": user, "password": password, "credentialId": ""}).encode()
    try:
        with opener.open(html.unescape(m.group(1)), data=form, timeout=20) as r:
            final = r.geturl()
    except urllib.error.HTTPError as e:
        final = f"{e.url} (HTTP {e.code})"
    if not any(c.name == "grafana_session" for c in jar):
        print(f"step 2/3: no Grafana session after the login (ended on {final})")
        return 1

    # 4. who does Grafana think we are?
    with opener.open(f"{GRAFANA}/api/user", timeout=20) as r:
        me = json.load(r)
    if me.get("login") != user:
        print(f"step 4: /api/user says {me}")
        return 1

    # 5. the role the group mapping gave us
    with opener.open(f"{GRAFANA}/api/user/orgs", timeout=20) as r:
        orgs = json.load(r)
    roles = [o.get("role") for o in orgs]
    if role not in roles:
        print(f"step 5: logged in, but org roles are {roles}, expected {role}")
        return 1

    print(f"{user} logged in via Keycloak, Grafana role {role}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
