"""Read (and, if needed, refresh) the Wispr Flow Supabase access token.

Approach "A" from DESIGN.md: we lift the token Wispr already stored rather than
reimplementing its login. The token is read from Wispr's own session.json at
runtime and held only in memory — it is never written into this repo or logs.

Supabase auth is a standard protocol, so we can refresh headlessly (without the
Wispr app running) using the public anon key embedded in Wispr's bundle.
"""

import json
import os
import time
import urllib.request

# Wispr's Supabase project (from the app bundle). The anon key is a *public*
# client key (role: anon) — safe to embed; it only gates the refresh endpoint.
SUPABASE_URL = "https://dodjkfqhwrzqjwkfnthl.supabase.co"
SUPABASE_ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRvZGprZnFod3J6cWp3a2ZudGhsIiwicm9sZSI6"
    "ImFub24iLCJpYXQiOjE3MTk4ODQzMDcsImV4cCI6MjAzNTQ2MDMwN30."
    "h6EeQ_6kqFeznH25icVUX0Szn9__kc8HoSXAsxxBWG8"
)

SESSION_JSON = os.path.expanduser(
    "~/Library/Application Support/Wispr Flow/session.json"
)
TOKEN_KEY = "sb-dodjkfqhwrzqjwkfnthl-auth-token"


def _load_session() -> dict:
    with open(SESSION_JSON) as f:
        blob = json.load(f)[TOKEN_KEY]
    return json.loads(blob)


def _refresh(refresh_token: str) -> dict:
    """Exchange a refresh token for a fresh session via Supabase."""
    body = json.dumps({"refresh_token": refresh_token}).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/auth/v1/token?grant_type=refresh_token",
        data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "apikey": SUPABASE_ANON_KEY,
            "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def get_access_token(auto_refresh: bool = True) -> str:
    """Return a currently-valid Wispr access token (JWT).

    Reads Wispr's session.json. If the token is within 60s of expiry and
    auto_refresh is set, refreshes it via Supabase (does not persist the result;
    Wispr's own app owns the on-disk session).
    """
    sess = _load_session()
    expires_at = sess.get("expires_at", 0)
    if auto_refresh and time.time() > expires_at - 60:
        sess = _refresh(sess["refresh_token"])
    return sess["access_token"]


if __name__ == "__main__":
    tok = get_access_token()
    # Print only a safe fingerprint, never the token itself.
    print(f"got access token: {len(tok)} chars, ...{tok[-6:]}")
