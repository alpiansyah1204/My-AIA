#!/bin/bash
#
# setup-nginx-openwebui.sh
#
# RHEL UI Server:
#   192.168.114.94
#
# Architecture:
#   Browser :80
#       -> Nginx
#       -> Open WebUI 127.0.0.1:8080
#
# Purpose:
#   Replace Apache httpd with Nginx and configure Open WebUI
#   for real-time AI response streaming.
#
# Streaming settings:
#   proxy_buffering off
#   proxy_cache off
#   proxy_http_version 1.1
#   long read/send timeouts
#   WebSocket support
#
# Run as root:
#   chmod +x setup-nginx-openwebui.sh
#   ./setup-nginx-openwebui.sh
#

set -euo pipefail

SERVER_IP="192.168.114.94"
WEBUI_HOST="127.0.0.1"
WEBUI_PORT="8080"

NGINX_CONF="/etc/nginx/conf.d/open-webui.conf"
NGINX_BACKUP_DIR="/etc/nginx/backup-openwebui"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi

log "1. Checking Open WebUI backend"

if ss -lnt 2>/dev/null | grep -qE ":${WEBUI_PORT}[[:space:]]"; then
    echo "Open WebUI is listening on TCP ${WEBUI_PORT}."
else
    echo "WARNING: Nothing detected on TCP ${WEBUI_PORT}."
    echo "Make sure the Open WebUI container is running."
fi

log "2. Stopping and removing Apache httpd"

if systemctl list-unit-files 2>/dev/null | grep -q '^httpd.service'; then
    systemctl stop httpd 2>/dev/null || true
    systemctl disable httpd 2>/dev/null || true
fi

# Remove Apache packages if installed.
# This does NOT remove Docker or Open WebUI data/volumes.
if rpm -q httpd >/dev/null 2>&1; then
    dnf remove -y httpd
else
    echo "httpd package is not installed."
fi

log "3. Installing Nginx"

dnf install -y nginx

log "4. Creating Nginx backup directory"

mkdir -p "${NGINX_BACKUP_DIR}"

if [[ -f "${NGINX_CONF}" ]]; then
    cp -a "${NGINX_CONF}" \
        "${NGINX_BACKUP_DIR}/open-webui.conf.${TIMESTAMP}"
    echo "Existing Open WebUI Nginx configuration backed up."
fi

log "5. Configuring SELinux"

if command -v getenforce >/dev/null 2>&1; then
    SELINUX_STATUS="$(getenforce)"
    echo "SELinux: ${SELINUX_STATUS}"

    if [[ "${SELINUX_STATUS}" == "Enforcing" ]]; then
        if command -v setsebool >/dev/null 2>&1; then
            setsebool -P httpd_can_network_connect 1
            echo "Enabled httpd_can_network_connect for Nginx reverse proxy."
        else
            echo "WARNING: setsebool is not available."
        fi
    fi
fi

log "6. Creating Nginx Open WebUI configuration"

mkdir -p /etc/nginx/conf.d

cat > "${NGINX_CONF}" <<EOF
# ============================================================
# Open WebUI Nginx Reverse Proxy
#
# Client:
#   http://${SERVER_IP}/
#
# Backend:
#   http://${WEBUI_HOST}:${WEBUI_PORT}/
#
# Streaming:
#   proxy_buffering off
#   proxy_cache off
# ============================================================

server {
    listen 80;
    listen [::]:80;

    server_name ${SERVER_IP};

    # --------------------------------------------------------
    # Open WebUI WebSocket
    # --------------------------------------------------------
    location /ws/ {
        proxy_pass http://${WEBUI_HOST}:${WEBUI_PORT};

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        proxy_buffering off;
        proxy_cache off;
    }

    # --------------------------------------------------------
    # Open WebUI HTTP/API
    # --------------------------------------------------------
    location / {
        proxy_pass http://${WEBUI_HOST}:${WEBUI_PORT};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Critical for AI token streaming.
        proxy_buffering off;
        proxy_cache off;

        # Disable proxy response transformation.
        proxy_set_header Accept-Encoding "";

        # Long-running AI requests.
        proxy_connect_timeout 10s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        # Send data to the browser as soon as it arrives.
        proxy_request_buffering off;
    }

    access_log /var/log/nginx/open-webui-access.log;
    error_log  /var/log/nginx/open-webui-error.log warn;
}
EOF

log "7. Testing Nginx configuration"

nginx -t

log "8. Enabling and starting Nginx"

systemctl enable nginx
systemctl restart nginx

log "9. Checking Nginx status"

systemctl --no-pager --full status nginx || true

if ! systemctl is-active --quiet nginx; then
    echo "ERROR: Nginx failed to start."
    echo
    echo "Nginx error log:"
    journalctl -u nginx --no-pager -n 50 || true
    exit 1
fi

log "10. Checking listening ports"

ss -lntp | grep -E ':(80|8080)[[:space:]]' || true

log "11. Testing Open WebUI backend"

curl -I --max-time 10 "http://${WEBUI_HOST}:${WEBUI_PORT}/" || true

log "12. Testing Nginx frontend"

curl -I --max-time 10 "http://127.0.0.1/" || true

log "13. Checking firewalld"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "WARNING: firewalld is currently ACTIVE."
    echo "Your previous requirement was for firewalld to remain disabled."
else
    echo "firewalld is inactive."
fi

log "SETUP COMPLETE"

echo
echo "Open WebUI:"
echo "  http://${SERVER_IP}/"
echo
echo "Nginx configuration:"
echo "  ${NGINX_CONF}"
echo
echo "Open WebUI backend:"
echo "  http://${WEBUI_HOST}:${WEBUI_PORT}/"
echo
echo "Streaming:"
echo "  proxy_buffering off"
echo "  proxy_cache off"
echo "  proxy_http_version 1.1"
echo "  WebSocket /ws/ enabled"
echo "  read/send timeout: 600s"
echo
echo "IMPORTANT:"
echo "  Open WebUI should be bound to 127.0.0.1:8080."
echo "  Do not expose 0.0.0.0:8080 if Nginx is the public entry point."
echo
echo "Test in browser:"
echo "  http://${SERVER_IP}/"
