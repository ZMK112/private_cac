#!/bin/sh
set -eu

mkdir -p /etc/sing-box
python3 -m ccimage.bridge > /etc/sing-box/config.json

exec /usr/local/bin/sing-box run -c /etc/sing-box/config.json
