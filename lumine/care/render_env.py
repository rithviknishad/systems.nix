"""Render or verify the env files lumine/render-secrets.sh writes.

Reads the decrypted sops dotenv on stdin; never prints a value, only key
names.

  render_env.py render care TEMPLATE   > /etc/care/care.env
  render_env.py render versitygw       > /etc/care/versitygw.env
  render_env.py check  care TEMPLATE   (run under systemd with EnvironmentFile=,
  render_env.py check  versitygw        so os.environ is what systemd parsed)
"""

import os
import sys

# Only needed by humans/recipes (seeding), not by the app: kept out of the
# env file so the services never see them.
NOT_FOR_APP_PREFIX = "BOX_"


def parse_secrets(text):
    secrets = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            sys.exit("secrets: malformed line (no '=')")
        # Single-quoted in the env files, and systemd has no escapes inside
        # single quotes, so these two can't be represented.
        if "'" in value or "\n" in value:
            sys.exit(f"secrets: {key} contains a quote or newline; regenerate it")
        secrets[key] = value
    return secrets


def parse_template(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            if len(value) >= 2 and value[0] == value[-1] == "'":
                value = value[1:-1]
            values[key] = value
    return values


def care_values(secrets, template):
    app = {k: v for k, v in secrets.items() if not k.startswith(NOT_FOR_APP_PREFIX)}
    settings = parse_template(template)
    if clash := sorted(app.keys() & settings.keys()):
        sys.exit(f"keys in both the template and the secrets: {', '.join(clash)}")
    return settings, app


def versitygw_values(secrets):
    # The gateway's root credentials ARE CARE's bucket credentials (as on
    # avocado), and it gets nothing else.
    return {
        "ROOT_ACCESS_KEY_ID": secrets["BUCKET_KEY"],
        "ROOT_SECRET_ACCESS_KEY": secrets["BUCKET_SECRET"],
    }


def main():
    action, kind = sys.argv[1], sys.argv[2]
    secrets = parse_secrets(sys.stdin.read())
    if kind == "care":
        template = sys.argv[3]
        settings, app = care_values(secrets, template)
        expected = {**settings, **app}
    elif kind == "versitygw":
        app = expected = versitygw_values(secrets)
    else:
        sys.exit(f"unknown kind {kind}")

    if action == "render":
        if kind == "care":
            with open(template) as f:
                sys.stdout.write(f.read())
            sys.stdout.write("\n# --- secrets (secrets/care-box.enc.env) ---\n")
        else:
            sys.stdout.write("# Rendered by lumine/render-secrets.sh from secrets/care-box.enc.env.\n")
        for key, value in app.items():
            sys.stdout.write(f"{key}='{value}'\n")
    elif action == "check":
        bad = sorted(k for k, v in expected.items() if os.environ.get(k) != v)
        if bad:
            sys.exit(f"{kind}: systemd parses these differently: {', '.join(bad)}")
        print(f"{kind}: systemd reads all {len(expected)} values back unchanged")
    else:
        sys.exit(f"unknown action {action}")


if __name__ == "__main__":
    main()
