# Resolve an ONVIF camera's concrete RTSP URL (with credentials baked in) and
# print it as a RTSPtoWeb `streams` fragment keyed by stream_id — the piece you
# paste into RTSPTOWEB_CONFIG_JSON in secrets/care-teleicu.enc.yaml to make a
# camera's stream DECLARATIVE (survives stream-server / node restarts).
#
# This is the sibling of register-camera-stream.py: that one POSTs the stream to
# RTSPtoWeb's API at runtime (ephemeral — lost on restart); this one only
# resolves + prints so the stream can be persisted in the seed config instead.
#
# Run it INSIDE the teleicu-middleware pod (has onvif-zeep + can resolve
# in-cluster hostnames); `just care-resolve-camera` pipes it in. The stream_id
# MUST match the CARE device's `stream_id` field, so pass the device's existing
# id (read it from the device detail API) — do not let it mint a new one for a
# device that already exists.
#
# argv: <ip> <username> <password> <stream_id> [profile_index=0] [onvif_port=80]
import json
import sys
import urllib.parse
import uuid

import django
import os

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "core.settings")
django.setup()

from django.conf import settings  # noqa: E402  (must follow django.setup())
from onvif import ONVIFCamera  # noqa: E402

ip = sys.argv[1]
user = sys.argv[2]
password = sys.argv[3]
stream_id = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else str(uuid.uuid4())
profile_index = int(sys.argv[5]) if len(sys.argv) > 5 else 0
onvif_port = int(sys.argv[6]) if len(sys.argv) > 6 else 80

# Ask the camera for its RTSP URI over ONVIF (path is vendor-specific).
cam = ONVIFCamera(ip, onvif_port, user, password, settings.WSDL_PATH)
media = cam.create_media_service()
profile = media.GetProfiles()[profile_index]
req = media.create_type("GetStreamUri")
req.ProfileToken = profile.token
req.StreamSetup = {"Stream": "RTP-Unicast", "Transport": {"Protocol": "RTSP"}}
rtsp_uri = media.GetStreamUri(req).Uri

# Bake URL-encoded credentials into the RTSP URL so RTSPtoWeb can authenticate.
parts = urllib.parse.urlsplit(rtsp_uri)
netloc = "%s:%s@%s" % (
    urllib.parse.quote(user, safe=""),
    urllib.parse.quote(password, safe=""),
    parts.netloc,
)
rtsp_url = urllib.parse.urlunsplit((parts.scheme, netloc, parts.path, parts.query, ""))

# Emit the streams fragment (on_demand: dial the camera only while watched).
fragment = {
    stream_id: {
        "name": "care-camera-%s" % stream_id,
        "channels": {"0": {"name": "ch0", "url": rtsp_url, "on_demand": True, "audio": False}},
    }
}
print(json.dumps(fragment, indent=2))
