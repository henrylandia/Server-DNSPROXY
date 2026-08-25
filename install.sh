#!/bin/bash
# ============================================================
# Coltan DNS+Proxy Service — Instalador
# Se ejecuta como root en un Debian 12 recién instalado
# (con apt update && apt upgrade ya hechos).
# ============================================================
set -e

PACKAGE_DIR="$(pwd)"
INSTALL_DIR="/opt/dnspanel"
REPO_CATEGORIES_DIR="/opt/coltan-dns-proxy"

echo "===================================================="
echo " Coltan DNS+Proxy Service — Instalación"
echo "===================================================="

# ---------- 1. Dependencias del sistema ----------
echo "==> Instalando paquetes del sistema..."
apt install -y dnsmasq nftables sniproxy sqlite3 git curl build-essential \
  dnsutils tcpdump rsync jq openssh-server p0f arp-scan iproute2

echo "==> Instalando Ookla Speedtest CLI..."
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt install -y speedtest

echo "==> Instalando Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs

echo "==> Instalando pm2 global..."
npm install -g pm2

# ---------- 2. Servicios base apagados hasta que el panel los controle ----------
echo "==> Preparando dnsmasq/sniproxy (controlados por el panel, no arrancan solos)..."
systemctl stop dnsmasq sniproxy 2>/dev/null || true
systemctl disable sniproxy 2>/dev/null || true

# ---------- 3. Descifrar y extraer la aplicación ----------
echo ""
echo "Ingresá la clave de instalación:"
read -s INSTALL_PASSWORD
echo ""

DECRYPT_TMP="/tmp/coltan-payload.tar.gz"

if [ ! -f "${PACKAGE_DIR}/payload.tar.gz.enc" ]; then
  echo "ERROR: no se encontró payload.tar.gz.enc junto a install.sh"
  exit 1
fi

openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
  -in "${PACKAGE_DIR}/payload.tar.gz.enc" \
  -out "$DECRYPT_TMP" \
  -pass pass:"$INSTALL_PASSWORD" 2>/dev/null

if [ ! -s "$DECRYPT_TMP" ]; then
  echo "ERROR: clave incorrecta o paquete dañado. Instalación cancelada."
  rm -f "$DECRYPT_TMP"
  exit 1
fi

echo "==> Clave correcta, extrayendo aplicación a ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
mkdir -p /tmp/coltan-extract-tmp
tar -xzf "$DECRYPT_TMP" -C /tmp/coltan-extract-tmp
cp -r /tmp/coltan-extract-tmp/app/. "$INSTALL_DIR/"
cp /tmp/coltan-extract-tmp/schema.sql "$INSTALL_DIR/schema.sql"
rm -rf "$DECRYPT_TMP" /tmp/coltan-extract-tmp
cd "$INSTALL_DIR"

echo "==> Instalando dependencias de Node..."
npm install

# ---------- 4. Base de datos ----------
echo "==> Creando base de datos..."
mkdir -p "$INSTALL_DIR/db"
sqlite3 "$INSTALL_DIR/db/panel.db" < "$INSTALL_DIR/schema.sql"

echo "==> Cargando datos iniciales (categorías, mail_settings)..."
sqlite3 "$INSTALL_DIR/db/panel.db" << 'SEEDEOF'
INSERT OR IGNORE INTO mail_settings (id) VALUES (1);

INSERT OR IGNORE INTO system_settings (key, value) VALUES
  ('websafe_enabled', '0'),
  ('dns_upstream', '1.1.1.1,8.8.8.8'),
  ('repo_url', 'https://raw.githubusercontent.com/henrylandia/coltan-dns-proxy/main');

INSERT OR IGNORE INTO categories (name, source, github_path, enabled_by_default) VALUES
  ('Streaming', 'github', 'categories/streaming.txt', 0),
  ('Porno', 'github', 'categories/porno.txt', 0),
  ('Phishing', 'github', 'security/phishing.txt', 1),
  ('Musica', 'github', 'categories/musica.txt', 0),
  ('Video', 'github', 'categories/video.txt', 0),
  ('Gambling', 'github', 'categories/gambling.txt', 0),
  ('Torrents', 'github', 'categories/torrents.txt', 0),
  ('Software', 'github', 'categories/software.txt', 0),
  ('Noticias', 'github', 'categories/noticias.txt', 0),
  ('Redes Sociales', 'github', 'categories/redes_sociales.txt', 0);

INSERT OR IGNORE INTO websafe_categories (name, github_path) VALUES
  ('Tracking', 'categories/tracking.txt'),
  ('Ads', 'categories/ads.txt');
SEEDEOF

# ---------- 5. Usuario admin por defecto ----------
echo "==> Creando usuario admin por defecto..."
ADMIN_HASH=$(node -e "console.log(require('bcrypt').hashSync('coltan', 10))")
sqlite3 "$INSTALL_DIR/db/panel.db" "INSERT INTO users (username, password_hash, role) VALUES ('admin', '${ADMIN_HASH}', 'admin');"

# ---------- 6. Variables de entorno ----------
echo "==> Generando .env..."
JWT_SECRET=$(openssl rand -hex 32)
cat > "$INSTALL_DIR/.env" << EOF
PORT=3030
DB_PATH=${INSTALL_DIR}/db/panel.db
JWT_SECRET=${JWT_SECRET}
EOF

# ---------- 7. Carpetas de trabajo ----------
mkdir -p /var/log/coltan
mkdir -p /etc/dnsmasq.d/clients
mkdir -p /etc/dnsmasq.d/websafe
mkdir -p /etc/sniproxy/clients
chmod 777 /var/log/coltan

# ---------- 8. Repo local de categorías (vacío, el admin configura la URL en Settings) ----------
mkdir -p "$REPO_CATEGORIES_DIR"

# ---------- 9. Unidades systemd (plantillas por cliente) ----------
echo "==> Instalando unidades systemd..."

cat > /etc/systemd/system/dnsmasq-client@.service << 'EOF'
[Unit]
Description=dnsmasq instance for client %i
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --conf-file=/etc/dnsmasq.d/clients/client_%i.conf --keep-in-foreground --no-daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sniproxy-client@.service << 'EOF'
[Unit]
Description=sniproxy instance for client %i
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/sniproxy -f -c /etc/sniproxy/clients/client_%i.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---------- 10. Servicio de restauración al boot ----------
cat > /etc/systemd/system/coltan-restore.service << EOF
[Unit]
Description=Reaplica todas las reglas de Coltan DNS+Proxy al arrancar
After=network-online.target dnsmasq.service
Wants=network-online.target
Before=coltan-bandwidth-restore.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node -e " \\
  const db = require('./db'); \\
  const { applyClientDns } = require('./dnsmasq.service'); \\
  const { applyClientProxy } = require('./sniproxy.service'); \\
  const { applyRuleset } = require('./firewall.service'); \\
  const clients = db.prepare('SELECT * FROM clients').all(); \\
  for (const c of clients) { \\
    if (c.dns_enabled) { try { applyClientDns(c.id); } catch(e) { console.error('dns', c.id, e.message); } } \\
    if (c.proxy_enabled) { try { applyClientProxy(c.id); } catch(e) { console.error('proxy', c.id, e.message); } } \\
  } \\
  applyRuleset(); \\
  console.log('Reglas reaplicadas para', clients.length, 'clientes'); \\
"

[Install]
WantedBy=multi-user.target
EOF

# ---------- 11. Shaping de ancho de banda al boot ----------
cat > /etc/systemd/system/coltan-bandwidth-restore.service << EOF
[Unit]
Description=Reaplica shaping de ancho de banda al arrancar
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node -e "const {applyDownloadShaping,applyUploadShaping}=require('./tc.service'); applyDownloadShaping(); applyUploadShaping();"

[Install]
WantedBy=multi-user.target
EOF

# ---------- 12. p0f (detección pasiva de dispositivos) ----------
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
cat > /etc/systemd/system/coltan-p0f.service << EOF
[Unit]
Description=p0f - deteccion pasiva de dispositivos para Coltan DNS+Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/p0f -i ${IFACE} -o /var/log/coltan/p0f.log
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ---------- 13. Sync de bypass (Google/Microsoft) diario ----------
cat > /etc/systemd/system/coltan-bypass-sync.service << EOF
[Unit]
Description=Sincroniza rangos de bypass (Google, Microsoft) para el proxy

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node -e "const {syncGoogle,syncMicrosoft365,syncMicrosoftAuthHosts}=require('./bypass-sync.service'); (async()=>{await syncGoogle();await syncMicrosoft365();await syncMicrosoftAuthHosts();require('./firewall.service').applyRuleset();})();"
EOF

cat > /etc/systemd/system/coltan-bypass-sync.timer << 'EOF'
[Unit]
Description=Corre la sync de bypass todos los días

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ---------- 14. Sync de Web Safe diario ----------
cat > /etc/systemd/system/coltan-websafe-sync.service << EOF
[Unit]
Description=Sincroniza listas de Web Safe (tracking/ads)

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node -e "const {syncWebsafeCategories,applyWebsafeToggle,getWebsafeStatus}=require('./websafe.service'); syncWebsafeCategories().then(()=>{ if(getWebsafeStatus().enabled) applyWebsafeToggle(true); });"
EOF

cat > /etc/systemd/system/coltan-websafe-sync.timer << 'EOF'
[Unit]
Description=Corre la sync de Web Safe todos los días

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ---------- 15. Collector de tráfico (cada 5 min) ----------
cat > /etc/systemd/system/coltan-traffic-collector.service << EOF
[Unit]
Description=Recolecta muestras de tráfico por identificador

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node -e "require('./traffic-collector.service').collectTrafficSample();"
EOF

cat > /etc/systemd/system/coltan-traffic-collector.timer << 'EOF'
[Unit]
Description=Corre el collector de tráfico cada 5 minutos

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

# ---------- 16. Chequeo de reporte por mail (cada hora) ----------
cat > /etc/systemd/system/coltan-report-check.service << EOF
[Unit]
Description=Chequea si corresponde enviar el reporte automatico por mail

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node -e "require('./report.service').checkAndSendIfDue().then(r => console.log(JSON.stringify(r)));"
StandardOutput=append:/var/log/coltan/report-check.log
EOF

cat > /etc/systemd/system/coltan-report-check.timer << 'EOF'
[Unit]
Description=Corre el chequeo de reporte cada hora

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ---------- 17. pm2: dashboard como servicio ----------
echo "==> Configurando pm2..."
cd "$INSTALL_DIR"
pm2 start server.js --name dnspanel
pm2 save
pm2 startup systemd -u root --hp /root

# ---------- 18. Habilitar todo ----------
echo "==> Habilitando servicios..."
systemctl daemon-reload
systemctl enable dnsmasq
systemctl start dnsmasq
systemctl enable coltan-restore.service
systemctl enable coltan-bandwidth-restore.service
systemctl enable --now coltan-p0f.service
systemctl enable --now coltan-bypass-sync.timer
systemctl enable --now coltan-websafe-sync.timer
systemctl enable --now coltan-traffic-collector.timer
systemctl enable --now coltan-report-check.timer

# ---------- 19. Datos de red para mostrar al final ----------
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "===================================================="
echo " Instalación completa"
echo "===================================================="
echo ""
echo " Panel: http://${CURRENT_IP}:3030"
echo " Usuario: admin"
echo " Contraseña: coltan"
echo ""
echo " IMPORTANTE: cambiá la contraseña del admin y configurá"
echo " la IP fija del servidor desde Settings → Red."
echo ""
