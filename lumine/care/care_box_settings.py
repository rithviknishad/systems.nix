# CARE settings for lumine (care-box.rithviknishad.dev): upstream's
# config.settings.deployment plus the overrides the box needs.
# deploy-backend.sh copies this into every build as
# config/settings/care_box.py.
from .base import env
from .deployment import *  # noqa: F403
from .deployment import LOGGING

# deployment.py hard-codes EMAIL_USE_TLS = True, but the box relays mail
# through avocado's Mailpit, which only speaks plain SMTP, so STARTTLS would
# fail every send.
EMAIL_USE_TLS = env.bool("EMAIL_USE_TLS", default=True)

# gunicorn runs with --preload here (2 GB of RAM), so Django configures
# logging inside the gunicorn master, and disable_existing_loggers=True then
# silences gunicorn's own loggers: no access log, and no arbiter messages
# such as WORKER TIMEOUT. Loggers named here stay enabled.
for _name in ("gunicorn.error", "gunicorn.access"):
    LOGGING["loggers"][_name] = {
        "level": "INFO",
        "handlers": ["console"],
        "propagate": False,
    }
