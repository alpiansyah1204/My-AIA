#!/bin/bash
set -euo pipefail

HTTPD_CONF="/etc/httpd/conf.d/open-webui.conf"
SERVER_NAME="192.168.114.94"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

echo "=== Installing/confirming httpd ==="
dnf install -y httpd

echo "=== Apache modules ==="
httpd -M 2>/dev/null | grep -E 'proxy_module|proxy_http_module|headers_module' || true

echo "=== Backup existing configuration ==="
if [[ -f "$HTTPD_CONF" ]]; then
  cp -a "$HTTPD_CONF" "${HTTPD_CONF}.backup.$(date +%Y%m%d-%H%M%S)"
fi

echo "=== Creating streaming-friendly Open WebUI proxy ==="
cat > "$HTTPD_CONF" <<'EOF'
<VirtualHost *:80>
    ServerName 192.168.114.94

    ProxyRequests Off
    ProxyPreserveHost On

    # Flush proxied data progressively for AI token streaming.
    ProxyPass        / http://127.0.0.1:8080/ connectiontimeout=5 timeout=600 flushpackets=on flushwait=10
    ProxyPassReverse / http://127.0.0.1:8080/

    # Forward client/proxy information.
    RequestHeader set X-Forwarded-Proto "http"
    RequestHeader set X-Forwarded-Port "80"
    RequestHeader set X-Forwarded-Host "%{HTTP_HOST}s"

    # Avoid compression on API responses, which can delay visible streaming.
    SetEnvIfNoCase Request_URI "^/api/" no-gzip dont-vary

    ErrorLog /var/log/httpd/open-webui-error.log
    CustomLog /var/log/httpd/open-webui-access.log combined
</VirtualHost>
EOF

echo "=== Testing Apache configuration ==="
httpd -t

echo "=== Enabling/restarting Apache ==="
systemctl enable httpd
systemctl restart httpd

echo "=== Apache status ==="
systemctl --no-pager --full status httpd || true

echo "=== Listening ports ==="
ss -lntp | grep -E ':(80|8080)[[:space:]]' || true

echo "=== Testing Open WebUI backend ==="
curl -I --max-time 10 http://127.0.0.1:8080/ || true

echo "=== Testing Apache frontend ==="
curl -I --max-time 10 http://127.0.0.1/ || true

echo
echo "============================================================"
echo "SETUP COMPLETE"
echo "============================================================"
echo "Open WebUI: http://192.168.114.94/"
echo
echo "Streaming configuration:"
echo "  flushpackets=on"
echo "  flushwait=10ms"
echo "  proxy timeout=600s"
echo
echo "AI responses should now stream progressively without refresh."
