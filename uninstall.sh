#!/bin/bash
# ============================================================
# Coltan DNS+Proxy Service — Desinstalador
# Revierte TODO lo que hace install.sh, para poder repetir
# pruebas de instalación desde cero en la misma máquina.
# No desinstala paquetes de apt (dnsmasq, node, etc.) porque
# reinstalarlos en cada prueba sería lento e innecesario.
# ============================================================

echo "===================================================="
echo " Coltan DNS+Proxy Service — Desinstalador"
echo "===================================================="

# ---------- 1. pm2: bajar el dashboard y sacar el auto-arranque ----------
echo "==> Deteniendo dashboard (pm2)..."
pm2 delete dnspanel 2>/dev/null || true
pm2 unstartup systemd 2>/dev/null || true
rm -f /root/.pm2/dump.pm2

# ---------- 2. Instancias por cliente (dnsmasq y sniproxy) ----------
echo "==> Deteniendo instancias por cliente..."
for unit in $(systemctl list-units --all --plain --no-legend 'dnsmasq-client@*' | awk '{print $1}'); do
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
done
for unit in $(systemctl list-units --all --plain --no-legend 'sniproxy-client@*' | awk '{print $1}'); do
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
done

# ---------- 3. Servicios y timers propios ----------
echo "==> Deteniendo servicios y timers de Coltan..."
UNITS="coltan-restore.service coltan-bandwidth-restore.service coltan-p0f.service \
  coltan-bypass-sync.service coltan-bypass-sync.timer \
  coltan-websafe-sync.service coltan-websafe-sync.timer \
  coltan-traffic-collector.service coltan-traffic-collector.timer \
  coltan-report-check.service coltan-report-check.timer"

for unit in $UNITS; do
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
done

# ---------- 4. Borrar archivos de unidades systemd ----------
echo "==> Borrando unidades systemd..."
rm -f /etc/systemd/system/dnsmasq-client@.service
rm -f /etc/systemd/system/sniproxy-client@.service
rm -f /etc/systemd/system/coltan-restore.service
rm -f /etc/systemd/system/coltan-bandwidth-restore.service
rm -f /etc/systemd/system/coltan-p0f.service
rm -f /etc/systemd/system/coltan-bypass-sync.service
rm -f /etc/systemd/system/coltan-bypass-sync.timer
rm -f /etc/systemd/system/coltan-websafe-sync.service
rm -f /etc/systemd/system/coltan-websafe-sync.timer
rm -f /etc/systemd/system/coltan-traffic-collector.service
rm -f /etc/systemd/system/coltan-traffic-collector.timer
rm -f /etc/systemd/system/coltan-report-check.service
rm -f /etc/systemd/system/coltan-report-check.timer
rm -f /etc/systemd/system/pm2-root.service

systemctl daemon-reload

# ---------- 5. dnsmasq global: apagar (install.sh lo deja activo) ----------
echo "==> Deteniendo dnsmasq global..."
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true

# ---------- 6. nftables: borrar la tabla que arma el panel ----------
echo "==> Limpiando reglas de nftables..."
nft delete table ip coltan_dns 2>/dev/null || true

# ---------- 7. tc: limpiar shaping y la interfaz virtual ifb0 ----------
echo "==> Limpiando shaping de ancho de banda..."
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -n "$IFACE" ]; then
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
fi
ip link del ifb0 2>/dev/null || true

# ---------- 8. Archivos y carpetas de la aplicación ----------
echo "==> Borrando archivos de la aplicación..."
rm -rf /opt/dnspanel
rm -rf /opt/coltan-dns-proxy
rm -rf /etc/dnsmasq.d/clients
rm -rf /etc/dnsmasq.d/websafe
rm -f /etc/dnsmasq.d/*.conf
rm -rf /etc/sniproxy/clients
rm -rf /var/log/coltan
rm -f /etc/nftables-dns.conf

echo ""
echo "===================================================="
echo " Desinstalación completa."
echo " La máquina quedó como antes de correr install.sh"
echo " (los paquetes de apt no se desinstalaron, para que"
echo " la próxima instalación sea más rápida)."
echo "===================================================="
echo ""
