#!/usr/bin/env bash
# CavFi - publish the static site on this Ubuntu server with nginx + HTTPS.
# Safe to run again: it updates the files and skips steps that are already done.
set -euo pipefail

DOMAIN="cavfi.com"
WWW="www.cavfi.com"
ROOT="/var/www/cavfi"
SRC="/tmp/cavfi-upload"

echo "== 1/6 packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx dnsutils curl >/dev/null

echo "== 2/6 DNS check"
MYIP=$(curl -4 -s https://api.ipify.org || true)
DNSIP=$(dig +short A "$DOMAIN" @1.1.1.1 | tail -n1)
WWWIP=$(dig +short A "$WWW" @1.1.1.1 | tail -n1)
echo "   server IP:  $MYIP"
echo "   $DOMAIN -> $DNSIP"
echo "   $WWW -> $WWWIP"
if [ -z "$DNSIP" ] || [ "$DNSIP" != "$MYIP" ]; then
  echo "!! $DOMAIN does not point to this server yet."
  echo "   Add an A record  @   -> $MYIP  at your domain registrar, wait 5-30 minutes, then run this again."
  exit 1
fi
CERT_DOMAINS="-d $DOMAIN"
if [ "$WWWIP" = "$MYIP" ]; then CERT_DOMAINS="$CERT_DOMAINS -d $WWW"; else echo "   (www not pointing here yet, certificate will cover $DOMAIN only)"; fi

echo "== 3/6 port check"
OTHER=$(ss -ltnpH '( sport = :80 or sport = :443 )' | grep -v nginx || true)
if [ -n "$OTHER" ]; then
  echo "!! Something other than nginx is using port 80 or 443:"
  echo "$OTHER"
  echo "   Stop it or move it behind nginx, then run this again."
  exit 1
fi

echo "== 4/6 site files"
mkdir -p "$ROOT"
install -m 0644 "$SRC/index.html" "$ROOT/index.html"
install -m 0644 "$SRC/addresses.json" "$ROOT/addresses.json"
chown -R www-data:www-data "$ROOT"

echo "== 5/6 nginx"
CONF=/etc/nginx/sites-available/cavfi
if [ ! -f "$CONF" ]; then
cat > "$CONF" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN $WWW;
    root $ROOT;
    index index.html;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "DENY" always;

    # contract addresses change on redeploy: never cache
    location = /addresses.json {
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
        try_files \$uri =404;
    }
    location = /index.html {
        add_header Cache-Control "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
    }
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
fi
ln -sf "$CONF" /etc/nginx/sites-enabled/cavfi
nginx -t
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 'Nginx Full' >/dev/null
fi

echo "== 6/6 HTTPS"
if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  echo "   certificate already exists, renewing only if due"
  certbot renew --quiet || true
  # make sure www is included once it points here
  if [ "$WWWIP" = "$MYIP" ] && ! openssl x509 -in /etc/letsencrypt/live/$DOMAIN/cert.pem -noout -text | grep -q "DNS:$WWW"; then
    certbot --nginx $CERT_DOMAINS --expand --redirect --non-interactive --agree-tos --register-unsafely-without-email
  fi
else
  certbot --nginx $CERT_DOMAINS --redirect --non-interactive --agree-tos --register-unsafely-without-email
fi
systemctl reload nginx

rm -rf "$SRC"
echo
echo "Done: https://$DOMAIN"
curl -s -o /dev/null -w "   https://$DOMAIN -> HTTP %{http_code}\n" "https://$DOMAIN/" || true
curl -s -o /dev/null -w "   https://$DOMAIN/addresses.json -> HTTP %{http_code}\n" "https://$DOMAIN/addresses.json" || true
