# Upsert the `abdm` plug_config so care_fe loads the ABDM MFE from this
# origin: avocado's `just care-register-abdm`, but through the ORM on the box
# instead of the admin API, so no admin credentials are involved. Run inside
# `manage.py shell` (just box-register-abdm). Idempotent.
from django.conf import settings
from django.core.cache import cache

from care.users.api.viewsets.plug_config import PlugConfigViewset
from care.users.models import PlugConfig

# `name` must be the federation name from the plug's vite.config.ts; the
# files are served at /mfe-plugs/abdm/ (lumine/nginx/care-box.conf).
meta = {
    "url": f"{settings.CURRENT_DOMAIN}/mfe-plugs/abdm/assets/remoteEntry.js",
    "localPath": "/mfe-plugs/abdm",
    "name": "care_abdm_fe",
    "plug": "abdm",
}
obj, created = PlugConfig.objects.get_or_create(slug="abdm", defaults={"meta": meta})
if created:
    result = "created"
elif obj.meta != meta:
    obj.meta = meta
    obj.save(update_fields=["meta"])
    result = "updated"
else:
    result = "unchanged"
# The public list is cached in redis; the API's own create/update clear it.
cache.delete(PlugConfigViewset.cache_key)
print(f"plug_config abdm {result}: {meta['url']}")
