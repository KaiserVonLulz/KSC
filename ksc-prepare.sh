#!/bin/bash

#==============================================================================
# Script di Preparazione per Installazione Manuale KSC 15.x + PostgreSQL
# Versione: 2.0
# Autore: Generato automaticamente
# Data: $(date +%Y-%m-%d)
#==============================================================================

set -euo pipefail

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configurazione
readonly KSC_VERSION="15.4.0-8873"
readonly WEB_CONSOLE_VERSION="15.4.1021"
readonly INSTALL_DIR="/tmp/ksc_install"

# URL download (aggiornali se cambiano)
readonly KSC_DOWNLOAD_URL="https://products.s.kaspersky-labs.com/administrationkit/ksc10/15.4.0.8873/english-24733053-en/3939393939367c44454c7c31/ksc64_15.4.0-8873_amd64.deb"
readonly WEB_CONSOLE_DOWNLOAD_URL="https://products.s.kaspersky-labs.com/administrationkit/ksc10/15.4.0.8952/english-25132578-en/313031343938397c44454c7c31/ksc-web-console-15.4.1021.x86_64.deb"

# Credenziali (modifica secondo necessità)
readonly KSC_PASSWORD="KSCAdmin123!"
readonly DB_PASSWORD="KSCAdmin123!"
readonly WEB_ADMIN_USER="Administrator"
readonly WEB_ADMIN_PASSWORD="KSCAdmin123!"

#==============================================================================
# FUNZIONI
#==============================================================================

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
    echo
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Questo script deve essere eseguito come root (usa sudo)"
        exit 1
    fi
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Impossibile determinare la distribuzione Linux"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "Questo script supporta solo Ubuntu. Rilevato: $ID"
        exit 1
    fi
    
    log_success "Sistema operativo: Ubuntu $VERSION"
}

check_system_resources() {
    local ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    local disk_gb=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
    
    log_info "Risorse sistema:"
    echo "  - RAM: ${ram_mb}MB $([ $ram_mb -lt 4096 ] && echo -e "${YELLOW}(⚠️  Raccomandati almeno 4GB)${NC}" || echo -e "${GREEN}(✅ OK)${NC}")"
    echo "  - CPU: ${cpu_cores} core$([ $cpu_cores -lt 2 ] && echo -e "${YELLOW}s (⚠️  Raccomandati almeno 2 core)${NC}" || echo -e "${GREEN}s (✅ OK)${NC}")"
    echo "  - Spazio: ${disk_gb}GB disponibili"
}

install_prerequisites() {
    log_section "INSTALLAZIONE PREREQUISITI"
    
    log_info "Aggiornamento indice pacchetti..."
    apt update -qq
    
    log_info "Installazione pacchetti necessari..."
    DEBIAN_FRONTEND=noninteractive apt install -y \
        postgresql \
        postgresql-contrib \
        python3-psycopg2 \
        curl \
        wget \
        sudo \
        systemd
    
    log_info "Avvio PostgreSQL..."
    systemctl enable postgresql
    systemctl start postgresql
    
    log_success "Prerequisiti installati correttamente"
}

configure_postgresql() {
    log_section "CONFIGURAZIONE POSTGRESQL"
    
    # Rileva versione PostgreSQL
    local pg_version=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oP 'PostgreSQL \K[0-9]+')
    local pg_config_path="/etc/postgresql/${pg_version}/main"
    
    log_info "PostgreSQL versione: $pg_version"
    log_info "Path configurazione: $pg_config_path"
    
    # Calcola parametri ottimali
    local ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local shared_buffers_mb=$((ram_mb / 4))
    local effective_cache_size_mb=$((ram_mb * 3 / 4))
    local maintenance_work_mem_mb=$((ram_mb / 20))
    
    log_info "Parametri calcolati per ${ram_mb}MB RAM:"
    echo "  - shared_buffers: ${shared_buffers_mb}MB"
    echo "  - effective_cache_size: ${effective_cache_size_mb}MB" 
    echo "  - maintenance_work_mem: ${maintenance_work_mem_mb}MB"
    
    # Backup configurazione originale
    if [[ ! -f "${pg_config_path}/postgresql.conf.backup" ]]; then
        cp "${pg_config_path}/postgresql.conf" "${pg_config_path}/postgresql.conf.backup"
        log_info "Backup configurazione creato"
    fi
    
    # Aggiunge configurazioni KSC
    log_info "Configurazione parametri PostgreSQL per KSC..."
    cat >> "${pg_config_path}/postgresql.conf" << EOF

# === KSC Optimizations ===
shared_buffers = ${shared_buffers_mb}MB
effective_cache_size = ${effective_cache_size_mb}MB
maintenance_work_mem = ${maintenance_work_mem_mb}MB
wal_buffers = 16MB

# KSC Required Settings
max_connections = 151
temp_buffers = 24MB
work_mem = 16MB
max_parallel_workers_per_gather = 0
standard_conforming_strings = on

# Performance tuning
checkpoint_completion_target = 0.9
wal_level = replica
random_page_cost = 1.1
effective_io_concurrency = 200
EOF
    
    # Configurazione autenticazione
    if [[ ! -f "${pg_config_path}/pg_hba.conf.backup" ]]; then
        cp "${pg_config_path}/pg_hba.conf" "${pg_config_path}/pg_hba.conf.backup"
    fi
    
    log_info "Configurazione autenticazione PostgreSQL..."
    cat >> "${pg_config_path}/pg_hba.conf" << EOF

# KSC Database Access
local   KAV         ksc                                     md5
host    KAV         ksc         127.0.0.1/32            md5
host    KAV         ksc         ::1/128                 md5
EOF
    
    # Riavvio PostgreSQL
    log_info "Riavvio PostgreSQL..."
    systemctl restart postgresql
    sleep 3
    
    if systemctl is-active --quiet postgresql; then
        log_success "PostgreSQL riavviato correttamente"
    else
        log_error "Errore riavvio PostgreSQL"
        exit 1
    fi
}

setup_database() {
    log_section "SETUP DATABASE E UTENTI"
    
    # Crea gruppo e utente di sistema
    log_info "Creazione gruppo kladmins..."
    if ! getent group kladmins > /dev/null 2>&1; then
        groupadd --system kladmins
        log_success "Gruppo kladmins creato"
    else
        log_info "Gruppo kladmins già esistente"
    fi
    
    log_info "Creazione utente ksc..."
    if ! id "ksc" &>/dev/null; then
        useradd --system --groups kladmins --home-dir /home/ksc --create-home --shell /bin/bash ksc
        echo "ksc:${KSC_PASSWORD}" | chpasswd
        log_success "Utente ksc creato"
    else
        log_info "Utente ksc già esistente"
        usermod -a -G kladmins ksc
        echo "ksc:${KSC_PASSWORD}" | chpasswd
    fi
    
    # Aggiungi utente ksc al gruppo kladmins e imposta gruppo primario
    log_info "Configurazione membership gruppi per utente ksc..."
    gpasswd -a ksc kladmins
    usermod -g kladmins ksc
    log_success "Utente ksc aggiunto al gruppo kladmins e impostato come gruppo primario"
    
    # Utente PostgreSQL
    log_info "Creazione utente PostgreSQL ksc..."
    sudo -u postgres psql -c "CREATE USER ksc WITH PASSWORD '${DB_PASSWORD}' CREATEDB;" 2>/dev/null || \
    sudo -u postgres psql -c "ALTER USER ksc WITH PASSWORD '${DB_PASSWORD}' CREATEDB;" 
    
    # Database KAV
    log_info "Creazione database KAV..."
    sudo -u postgres psql -c "CREATE DATABASE \"KAV\" OWNER ksc ENCODING 'UTF-8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;" 2>/dev/null || \
    sudo -u postgres psql -c "ALTER DATABASE \"KAV\" OWNER TO ksc;"
    
    # Privilegi database
    sudo -u postgres psql -d KAV -c "GRANT ALL PRIVILEGES ON DATABASE \"KAV\" TO ksc;"
    
    # Test connessione
    log_info "Test connessione database..."
    if PGPASSWORD="${DB_PASSWORD}" psql -h localhost -U ksc -d KAV -c "SELECT version();" > /dev/null 2>&1; then
        log_success "Database configurato e testato correttamente"
    else
        log_error "Errore connessione database"
        exit 1
    fi
}

download_packages() {
    log_section "DOWNLOAD PACCHETTI KSC"
    
    # Crea directory installazione
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    log_info "Directory installazione: $INSTALL_DIR"
    
    # Download KSC Server
    local ksc_file="ksc64_${KSC_VERSION}_amd64.deb"
    if [[ ! -f "$ksc_file" ]]; then
        log_info "Download KSC Server (circa 157MB)..."
        wget --progress=dot:giga -O "$ksc_file" "$KSC_DOWNLOAD_URL"
        log_success "KSC Server scaricato: $ksc_file"
    else
        log_info "KSC Server già presente: $ksc_file"
    fi
    
    # Download Web Console  
    local web_console_file="ksc-web-console.deb"
    if [[ ! -f "$web_console_file" ]]; then
        log_info "Download Web Console (circa 86MB)..."
        wget --progress=dot:giga -O "$web_console_file" "$WEB_CONSOLE_DOWNLOAD_URL"
        log_success "Web Console scaricato: $web_console_file"
    else
        log_info "Web Console già presente: $web_console_file"
    fi
    
    # Verifica integrità file
    if [[ -f "$ksc_file" && -f "$web_console_file" ]]; then
        local ksc_size=$(stat -c%s "$ksc_file")
        local web_size=$(stat -c%s "$web_console_file")
        
        log_info "File scaricati:"
        echo "  - $ksc_file: $(numfmt --to=iec $ksc_size)"
        echo "  - $web_console_file: $(numfmt --to=iec $web_size)"
        
        if [[ $ksc_size -gt 100000000 && $web_size -gt 50000000 ]]; then
            log_success "Download completato correttamente"
        else
            log_error "I file scaricati sembrano incompleti"
            exit 1
        fi
    fi
}

install_ksc_package() {
    log_section "INSTALLAZIONE PACCHETTO KSC"
    
    cd "$INSTALL_DIR"
    
    local ksc_file="ksc64_${KSC_VERSION}_amd64.deb"
    
    if [[ ! -f "$ksc_file" ]]; then
        log_error "File KSC non trovato: $ksc_file"
        exit 1
    fi
    
    log_info "Installazione pacchetto KSC Server..."
    log_warning "Durante l'installazione potrebbero apparire errori di dipendenze - verranno risolti automaticamente"
    
    # Installa il pacchetto KSC (ignora errori di dipendenze)
    dpkg -i "$ksc_file" || true
    
    # Risolvi eventuali dipendenze mancanti
    log_info "Risoluzione dipendenze..."
    apt-get install -f -y
    
    # Verifica installazione
    if dpkg -l | grep -q "ksc64"; then
        log_success "Pacchetto KSC installato correttamente"
    else
        log_error "Errore installazione pacchetto KSC"
        exit 1
    fi
    
    # Verifica presenza file postinstall.pl
    if [[ -f "/opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl" ]]; then
        log_success "File postinstall.pl trovato e pronto per la configurazione"
    else
        log_error "File postinstall.pl non trovato"
        exit 1
    fi
}

create_config_files() {
    log_section "CREAZIONE FILE CONFIGURAZIONE"
    
    cd "$INSTALL_DIR"
    
    # Configurazione Web Console
    log_info "Creazione configurazione Web Console..."
    cat > ksc-web-console-setup.json << EOF
{
  "address": "127.0.0.1",
  "port": 8080,
  "trusted": "127.0.0.1|13299|/var/opt/kaspersky/klnagent_srv/1093/cert/klserver.cer|KSC Server",
  "acceptEula": true
}
EOF
    
    # Copia automaticamente il file nella posizione corretta
    log_info "Copia automatica del file ksc-web-console-setup.json in /etc/..."
    cp ksc-web-console-setup.json /etc/
    chown root:root /etc/ksc-web-console-setup.json
    chmod 644 /etc/ksc-web-console-setup.json
    log_success "File ksc-web-console-setup.json copiato in /etc/"
    
    # Script helper installazione manuale
    log_info "Creazione script helper..."
    cat > install-manual.sh << 'EOF'
#!/bin/bash

echo "🚀 === GUIDA PROSSIMI PASSI MANUALI KSC ==="
echo
echo "📍 Directory corrente: $(pwd)"
echo "📦 File disponibili:"
ls -lh *.deb *.json 2>/dev/null || echo "Nessun file trovato"
echo
echo "✅ COMPLETATO AUTOMATICAMENTE:"
echo "   - PostgreSQL configurato e ottimizzato"
echo "   - Database KAV creato"
echo "   - Utenti sistema (ksc, kladmins) configurati"
echo "   - Pacchetto KSC Server installato"
echo "   - File configurazione Web Console preparati"
echo
echo "📋 === PASSI MANUALI RIMANENTI ==="
echo
echo "1️⃣  CONFIGURAZIONE KSC SERVER (WIZARD INTERATTIVO):"
echo "    sudo /opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl"
echo "    💡 Segui il wizard interattivo con queste risposte:"
echo ""
echo "       EULA acceptance: Y"
echo ""
echo "       Choose the Administration Server installation mode:"
echo "       1) Standard"
echo "       2) Primary cluster node"
echo "       3) Secondary cluster node"
echo "       Enter the range number (1, 2, or 3) [1]: 1"
echo ""
echo "       Enter Administration Server DNS-name or static IP-address:"
echo "       ksc.365servizi.it"
echo ""
echo "       Enter Administration Server SSL port number [13000]:"
echo "       (premi INVIO per default)"
echo ""
echo "       Define the approximate number of devices:"
echo "       1) 1 to 100 networked devices"
echo "       2) 101 to 1 000 networked devices"
echo "       3) More than 1 000 networked devices"
echo "       Enter the range number (1, 2, or 3) [1]: 2"
echo ""
echo "       Enter the security group name for services:"
echo "       kladmins"
echo ""
echo "       Enter the account name to start the Administration Server service:"
echo "       ksc"
echo ""
echo "       Enter the account name to start other services:"
echo "       ksc"
echo ""
echo "       Choose the database type to connect to:"
echo "       1) MySQL"
echo "       2) Postgres"
echo "       Enter the range number (1 or 2): 2"
echo ""
echo "       Enter the database address:"
echo "       127.0.0.1"
echo ""
echo "       Enter the database port:"
echo "       5432"
echo ""
echo "       Enter the database name:"
echo "       KAV"
echo ""
echo "       Enter the database login:"
echo "       ksc"
echo ""
echo "       Enter the database password:"
echo "       KSCAdmin123!"
echo ""
echo "2️⃣  INSTALLAZIONE WEB CONSOLE:"
echo "    sudo dpkg -i ksc-web-console.deb"
echo "    (il file ksc-web-console-setup.json è già in /etc/)"
echo ""
echo "3️⃣  VERIFICA SERVIZI:"
echo "    sudo systemctl status klad* kl* KSC*"
echo ""
echo "🌐 === ACCESSO ==="
echo "    Web Console: http://\$(hostname -I | awk '{print \$1}'):8080"
echo "    👤 Username: Administrator"
echo "    🔑 Password: KSCAdmin123!"
echo
echo "🗄️ === DATABASE PRECONFIGURATO ==="
echo "    Host: localhost:5432"
echo "    Database: KAV"
echo "    User: ksc"
echo "    Password: KSCAdmin123!"
echo
echo "👥 === UTENTI SISTEMA CONFIGURATI ==="
echo "    - Gruppo: kladmins"
echo "    - Utente: ksc (membro di kladmins)"
echo "    - Password sistema ksc: KSCAdmin123!"
echo
echo "💡 === NOTE ==="
echo "    - PostgreSQL già ottimizzato per KSC"
echo "    - Utenti di sistema già creati e configurati"
echo "    - File configurazione Web Console già in /etc/"
EOF
    
    chmod +x install-manual.sh
    
    log_success "File configurazione creati in $INSTALL_DIR"
}

print_summary() {
    log_section "🎉 PREPARAZIONE COMPLETATA"
    
    echo -e "${GREEN}✅ SISTEMA PREPARATO PER INSTALLAZIONE MANUALE KSC${NC}"
    echo
    echo -e "${CYAN}📍 File preparati in: ${INSTALL_DIR}${NC}"
    echo "   ✅ KSC Server: installato automaticamente"
    echo "   🎯 Web Console: ksc-web-console.deb (pronto per installazione)"  
    echo "   ✅ Config Web Console: ksc-web-console-setup.json (già copiato in /etc/)"
    echo "   🎯 Script helper: install-manual.sh"
    echo
    echo -e "${GREEN}🗄️ PostgreSQL configurato e ottimizzato${NC}"
    echo "   👤 Database KAV creato con utente 'ksc'"
    echo "   🔧 Parametri ottimizzati per la RAM disponibile"
    echo "   ✅ Connessione testata"
    echo
    echo -e "${GREEN}👥 Utenti sistema configurati${NC}"
    echo "   👤 Utente 'ksc' creato e aggiunto al gruppo 'kladmins'"
    echo "   🔐 Password utente ksc: ${KSC_PASSWORD}"
    echo
    echo -e "${YELLOW}📋 PROSSIMI PASSI MANUALI:${NC}"
    echo "   1. cd $INSTALL_DIR"
    echo "   2. ./install-manual.sh  (per vedere le istruzioni dettagliate)"
    echo "   3. sudo /opt/kaspersky/ksc64/lib/bin/setup/postinstall.pl  (wizard configurazione)"
    echo "   4. Seguire wizard configurazione KSC con le risposte indicate"
    echo "   5. sudo dpkg -i ksc-web-console.deb"
    echo
    echo -e "${CYAN}🌐 Web Console: http://$(hostname -I | awk '{print $1}'):8080${NC}"
    echo -e "${CYAN}👤 Admin: ${WEB_ADMIN_USER} / ${WEB_ADMIN_PASSWORD}${NC}"
    echo -e "${CYAN}🗄️ Database: ksc / ${DB_PASSWORD}${NC}"
    echo
    echo -e "${GREEN}🚀 Preparazione completata! Tempo risparmiato: ~15-20 minuti${NC}"
}

#==============================================================================
# MAIN
#==============================================================================

main() {
    log_section "🚀 PREPARAZIONE SISTEMA PER KSC 15.x + POSTGRESQL"
    
    check_root
    check_ubuntu
    check_system_resources
    
    install_prerequisites
    configure_postgresql  
    setup_database
    download_packages
    install_ksc_package
    create_config_files
    
    print_summary
    
    echo
    log_success "Script completato con successo!"
}

# Esegui solo se chiamato direttamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
