#!/bin/bash
#
# setup-openwebui-httpd.sh
#
# Purpose:
#   Configure RHEL UI server as a reverse proxy:
#
#   Client --> HTTP :80 --> httpd --> Open WebUI :8080
#
# Target:
#   UI server : 192.168.114.94
#   Open WebUI: 127.0.0.1:8080 (or localhost:8080)
#
# Run as root:
#   chmod +x setup-openwebui-httpd.sh
#   ./setup-openwebui-httpd.sh
#

set -euo pipefail

WEBUI_HOST="127.0.0.1"
WEBUI_PORT="8080"
HTTP_PORT="80"
HTTPD_CONF="/etc/httpd/conf.d/open-webui.conf"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run this script as root."
    echo "Example: sudo $0"
    exit 1
fi

log "1. Detecting RHEL version"
cat /etc/redhat-release || true

log "2. Stopping and disabling firewalld"
if systemctl list-unit-files | grep -q '^firewalld.service'; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
fi

systemctl is-active firewalld 2>/dev/null || true
echo "firewalld should now be inactive/disabled."

log "3. Installing Apache httpd"
dnf install -y httpd

log "4. Enabling required Apache proxy modules"
# RHEL httpd packages normally ship the proxy modules as DSO modules.
# Verify their availability after installation.
httpd -M 2>/dev/null | grep -E 'proxy_module|proxy_http_module' || true

log "5. Configuring SELinux for Apache reverse proxy"
if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS="$(getenforce)"
    echo "SELinux status: ${SELINUX_STATUS}"

    if [[ "${SELINUX_STATUS}" == "Enforcing" ]]; then
        if command -v setsebool >/dev/null 2>&1; then
            setsebool -P httpd_can_network_connect 1
            echo "Enabled: httpd_can_network_connect"
        else
            echo "WARNING: setsebool is not available."
        fi
    fi
fi

log "6. Checking Open WebUI backend"
if command -v ss >/dev/null 2>&1; then
    if ss -lnt | grep -qE ":${WEBUI_PORT}[[:space:]]"; then
        echo "Open WebUI backend appears to be listening on ${WEBUI_HOST}:${WEBUI_PORT}"
    else
        echo "WARNING: Nothing is currently detected listening on TCP ${WEBUI_PORT}."
        echo "Make sure the Open WebUI Docker container is running."
    fi
fi

log "7. Creating Apache reverse-proxy configuration"

cat > "${HTTPD_CONF}" <<EOF
# Open WebUI reverse proxy
# Client: http://<UI-SERVER-IP>/
# Backend: http://${WEBUI_HOST}:${WEBUI_PORT}/

<VirtualHost *:${HTTP_PORT}>
    ServerName 192.168.114.94

    ProxyRequests Off
    ProxyPreserveHost On

    # Reverse proxy to Open WebUI
    ProxyPass        / http://${WEBUI_HOST}:${WEBUI_PORT}/
    ProxyPassReverse / http://${WEBUI_HOST}:${WEBUI_PORT}/

    # Forward useful client information
    RequestHeader set X-Forwarded-Proto "http"
    RequestHeader set X-Forwarded-Port "${HTTP_PORT}"

    ErrorLog /var/log/httpd/open-webui-error.log
    CustomLog /var/log/httpd/open-webui-access.log combined
</VirtualHost>
EOF

log "8. Testing Apache configuration"
httpd -t

log "9. Enabling and starting Apache"
systemctl enable httpd
systemctl restart httpd

log "10. Verifying services"
echo "--- httpd ---"
systemctl --no-pager --full status httpd || true

echo
echo "--- firewalld ---"
systemctl --no-pager --full status firewalld 2>/dev/null || true

echo
echo "--- Listening ports ---"
ss -lntp | grep -E ':(80|8080)[[:space:]]' || true

echo
echo "--- Local HTTP test ---"
if command -v curl >/dev/null 2>&1; then
    curl -I --max-time 10 http://127.0.0.1/ || true
fi

log "SETUP COMPLETE"

echo "Open WebUI should now be accessible at:"
echo "  http://192.168.114.94/"
echo
echo "Apache configuration:"
echo "  ${HTTPD_CONF}"
echo
echo "Open WebUI backend:"
echo "  http://${WEBUI_HOST}:${WEBUI_PORT}/"
echo
echo "IMPORTANT:"
echo "  firewalld has been stopped and disabled."
echo "  If Open WebUI is still exposed as 0.0.0.0:8080, it can still"
echo "  be accessed directly using port 8080. For a stricter setup,"
echo "  bind Docker only to 127.0.0.1:8080."
