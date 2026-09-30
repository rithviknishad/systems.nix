"""(Re)create the TeleICU devices in CARE from the persisted camera streams.

Run via `just care-wire-devices <facility_id> [user] [pass]`, which pipes in
`sops --decrypt --output-type json secrets/care-teleicu.enc.yaml`. Idempotent
by `registered_name`: existing devices are PUT (updated), missing ones POSTed.

Creates, on the given facility:
  - the gateway device (endpoint = the gateway's public host),
  - one ONVIF camera per stream in RTSPTOWEB_CONFIG_JSON, reusing the stream's
    id as the device's stream_id (so the declarative RTSPtoWeb seed keeps
    working unchanged) and the ONVIF host/creds embedded in its RTSP URL,
  - a vitals-observation device for the mock HL7 monitor.
Prints the gateway id, which goes into GATEWAY_DEVICE_ID
(k8s/care-teleicu/care-teleicu.yaml). Camera creds go only into the request
bodies; nothing secret is printed.

Gotcha: the device plugs' handle_create/handle_update read their metadata
from the TOP LEVEL of the request body, not from `care_metadata` (which is
silently ignored), so metadata fields are sent flat.
"""

import json
import sys
import urllib.error
import urllib.request
from urllib.parse import unquote, urlsplit

API = "https://care.rithviknishad.dev"
GATEWAY_HOST = "care-teleicu-gateway.rithviknishad.dev"
# One of the device_ids the mock HL7 monitor emits (mock_data/hl7-monitor.json
# covers 192.168.1.11-20); the middleware matches observations on it.
VITALS_ADDR = "192.168.1.13"

facility, user, password = sys.argv[1], sys.argv[2], sys.argv[3]


def call(method, path, body=None, token=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        # Cloudflare answers urllib's default User-Agent with error 1010.
        headers={"Content-Type": "application/json", "User-Agent": "avocado-care-wire-devices/1"},
    )
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read()[:500]!r}")


def vendor(u):
    # RTSP paths are vendor-specific (see docs/care.md); good enough to label.
    p = u.path + ("?" + u.query if u.query else "")
    if u.hostname.startswith("mock-ptz-camera"):
        return "Mock PTZ"
    if "/unicaststream/" in p:
        return "MATRIX"
    if "/Streaming/Channels/" in p:
        return "PRAMA"
    if "/video/live" in p:
        return "CP Plus"
    return "Unknown"


secret = json.load(sys.stdin)
data = secret.get("stringData") or secret.get("data")
streams = json.loads(data["RTSPTOWEB_CONFIG_JSON"])["streams"]

token = call("POST", "/api/v1/auth/login/", {"username": user, "password": password})["access"]
dev_path = f"/api/v1/facility/{facility}/device/"
existing = {d["registered_name"]: d for d in call("GET", dev_path + "?limit=100", token=token)["results"]}


def ensure(body, metadata):
    body = {"status": "active", "availability_status": "available", **body, **metadata}
    name = body["registered_name"]
    if name in existing:
        did = existing[name]["id"]
        call("PUT", f"{dev_path}{did}/", body, token)
        print(f"updated {did}  {name}")
        return did
    did = call("POST", dev_path, body, token)["id"]
    print(f"created {did}  {name}")
    return did


gateway = ensure(
    {"care_type": "gateway", "registered_name": "TeleICU Gateway - avocado/linux", "user_friendly_name": "Avocado Gateway"},
    {"endpoint_address": GATEWAY_HOST, "insecure": False},
)

for stream_id, stream in streams.items():
    u = urlsplit(stream["channels"]["0"]["url"])
    ven = vendor(u)
    label = "mock" if ven == "Mock PTZ" else u.hostname
    ensure(
        {"care_type": "camera", "manufacturer": ven, "registered_name": f"{ven} camera ({label})", "user_friendly_name": f"{ven} Camera"},
        {
            "type": "ONVIF",
            "gateway": gateway,
            "endpoint_address": u.hostname,
            "username": unquote(u.username or ""),
            "password": unquote(u.password or ""),
            "stream_id": stream_id,
        },
    )

ensure(
    {"care_type": "vitals-observation", "registered_name": "Mock HL7 Monitor", "user_friendly_name": "HL7 Monitor"},
    {"type": "HL7-Monitor", "gateway": gateway, "endpoint_address": VITALS_ADDR},
)

print(f"\nGATEWAY_DEVICE_ID={gateway}")
print("-> set it in k8s/care-teleicu/care-teleicu.yaml, `just care-teleicu-deploy`, then restart teleicu-middleware + teleicu-celery")
