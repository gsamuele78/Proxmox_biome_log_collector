#!/usr/bin/env python3
"""Scripted Keycloak browser login for the lab tests (stdlib only).

Follows redirects from START_URL until Keycloak's login form, submits the
lab user's credentials, then keeps following redirects. It stops at the
first redirect whose target starts with STOP_PREFIX (printing that URL) or
at the final page (printing "<status> <url>" and saving the body to
--body). Host names in --resolve HOST=IP are mapped without touching
/etc/hosts; TLS verification is off (lab self-signed certificates).
"""
import argparse
import html
import http.cookiejar
import re
import socket
import ssl
import sys
import urllib.parse
import urllib.request

p = argparse.ArgumentParser()
p.add_argument("start_url")
p.add_argument("--user", default="labuser")
p.add_argument("--password", default="labpass")
p.add_argument("--stop-prefix", default="")
p.add_argument("--resolve", action="append", default=[])
p.add_argument("--body", default="")
a = p.parse_args()

overrides = dict(r.split("=", 1) for r in a.resolve)
_orig = socket.getaddrinfo
socket.getaddrinfo = lambda host, *rest, **kw: _orig(overrides.get(host, host), *rest, **kw)

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    urllib.request.HTTPSHandler(context=ctx),
    NoRedirect,
)


def fetch(url, data=None):
    """Follow redirects manually; return (status, url, body) of the final page."""
    for _ in range(15):
        req = urllib.request.Request(url, data=data, headers={"Accept": "text/html"})
        try:
            resp = opener.open(req, timeout=20)
            return resp.status, url, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308):
                nxt = urllib.parse.urljoin(url, e.headers["Location"])
                if a.stop_prefix and nxt.startswith(a.stop_prefix):
                    print(nxt)
                    sys.exit(0)
                url, data = nxt, None
                continue
            return e.code, url, e.read().decode("utf-8", "replace")
    sys.exit("too many redirects")


status, url, body = fetch(a.start_url)
m = re.search(r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"', body) or re.search(
    r'action="([^"]*login-actions/authenticate[^"]*)"', body)
if not m:
    sys.exit(f"no Keycloak login form at {url} (HTTP {status})")
form = urllib.parse.urlencode({"username": a.user, "password": a.password, "credentialId": ""}).encode()
status, url, body = fetch(html.unescape(m.group(1)), form)
if a.body:
    with open(a.body, "w") as f:
        f.write(body)
print(f"{status} {url}")
