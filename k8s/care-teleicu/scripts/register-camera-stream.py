# Register an ONVIF camera's RTSP feed with the in-cluster RTSPtoWeb
# (stream-server) and print the resulting stream_id — the value you store on
# the CARE camera device's `stream_id` field.
#
# Run it INSIDE the teleicu-middleware pod (the gateway image ships onvif-zeep
# and can resolve `stream-server`); `just care-register-camera` pipes it in.
# Why the gateway does the ONVIF discovery: deepch/RTSPtoWeb cannot derive an
# RTSP URL from ONVIF itself, and RTSP paths are vendor-specific (never guess
# them) — so we ask the camera via ONVIF GetStreamUri, then hand RTSPtoWeb the
# concrete URL with credentials baked in.
#
# Caveat (see docs/care.md): the stream is written to RTSPtoWeb's in-memory /
# emptyDir config via its API, so a stream-server pod restart drops it. For a
# camera that must survive restarts, persist it declaratively instead — use
# resolve-camera-stream.py (`just care-resolve-camera`) and merge the fragment
# into RTSPTOWEB_CONFIG_JSON in the sops secret. We accept an optional stream_id
# argument here so re-registration reuses the same id.
#
# argv: <ip> <username> <password> [profile_index=0] [onvif_port=80] [stream_id]
import json
import os
import sys
import urllib.parse
import urllib.request
import uuid

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")
django.setup()

from django.conf import settings  # noqa: E402  (must follow django.setup())
from onvif import ONVIFCamera  # noqa: E402

ip = sys.argv[1]
user = sys.argv[2]
password = sys.argv[3]
profile_index = int(sys.argv[4]) if len(sys.argv) > 4 else 0
onvif_port = int(sys.argv[5]) if len(sys.argv) > 5 else 80
stream_id = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else str(uuid.uuid4())

# Ask the camera for its RTSP URI over ONVIF (path is vendor-specific).
cam = ONVIFCamera(ip, onvif_port, user, password, settings.WSDL_PATH)
media = cam.create_media_service()
profile = media.GetProfiles()[profile_index]
req = media.create_type("GetStreamUri")
req.ProfileToken = profile.token
req.StreamSetup = {"Stream": "RTP-Unicast", "Transport": {"Protocol": "RTSP"}}
rtsp_uri = media.GetStreamUri(req).Uri

# Bake URL-encoded credentials into the RTSP URL so RTSPtoWeb can authenticate
# (LIVE555/most cameras require digest/basic auth on the RTSP session).
parts = urllib.parse.urlsplit(rtsp_uri)
netloc = "%s:%s@%s" % (
    urllib.parse.quote(user, safe=""),
    urllib.parse.quote(password, safe=""),
    parts.netloc,
)
rtsp_url = urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, parts.query, ""))

# on_demand: RTSPtoWeb only dials the camera while a client is watching.
body = {
    "name": "care-camera-%s" % stream_id,
    "channels": {"0": {"name": "ch0", "url": rtsp_url, "on_demand": True, "audio": False}},
}

# Idempotent: /add rejects a duplicate id with a 500, so switch to /edit when
# the id already exists (lets you re-register the same stream_id after a
# stream-server restart without first deleting it).
listed = json.load(
    urllib.request.urlopen("http://stream-server:8080/streams", timeout=20)
)
existing = (listed.get("payload") or {})
action = "edit" if stream_id in existing else "add"
req = urllib.request.Request(
    "http://stream-server:8080/stream/%s/%s" % (stream_id, action),
    data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
resp = json.load(urllib.request.urlopen(req, timeout=20))
if resp.get("payload") != "success":
    sys.exit("RTSPtoWeb rejected the stream: %s" % resp)

# Only the stream_id goes to stdout, so callers can capture it cleanly.
print(stream_id)
