#!/usr/bin/with-contenv bash
# Installs our jail/filter definitions into the writable /config volume.
#
# A read-only bind mount placed directly under /config/fail2ban doesn't
# survive: the image seeds /config/fail2ban with its full default config set
# on first run, and that process doesn't coexist with a single file mounted
# inside the directory it's populating. So instead our config lives at
# /our-config (a plain read-only bind mount, untouched by the image) and this
# script -- run via the image's custom-cont-init.d hook, after defaults are
# in place -- copies it into /config/fail2ban.
cp /our-config/jail.local /config/fail2ban/jail.local
mkdir -p /config/fail2ban/filter.d
cp /our-config/filter.d/vaultwarden.conf /config/fail2ban/filter.d/vaultwarden.conf
