#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  pgwho — Instalação inicial
#
#  Uso (em qualquer VM com Docker):
#    curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | bash
#
#  O script:
#    1. Verifica pré-requisitos (Docker, Docker Compose, curl)
#    2. Cria arquivos no diretório atual  (ou $PGWHO_DIR se definido)
#    3. Baixa docker-compose.client.yml e update.sh
#    4. Coleta configurações interativamente (com padrões inteligentes)
#    5. Baixa as imagens (públicas, sem login) e sobe os containers
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main"
INSTALL_DIR="${PGWHO_DIR:-${PGWATCH_DIR:-$PWD}}"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; CYAN="\033[0;36m"; DIM="\033[2m"; RESET="\033[0m"
info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${CYAN}━━━ $* ${RESET}"; }
default() { echo -e "  ${DIM}↳ $*${RESET}"; }

# Verifica se uma porta já está em uso (Docker ou sistema).
# Retorna 0 = livre, 1 = em uso.
# Imprime na stdout quem está usando quando em uso.
# Que certificado um domínio pode ter (HTTPS opcional)?
#   public     resolve para IP público: Let's Encrypt
#   local      nome de rede local (.local, .lan, .internal...) ou que só resolve
#              para IP privado: o Let's Encrypt nunca emite; só certificado
#              próprio, que o navegador avisa até alguém confiar nele
#   unresolved ainda não resolve (DNS novo, ou só no hosts de outra máquina)
domain_kind() {
  local d="$1" ips ip
  case "$d" in
    *.local|*.lan|*.home|*.internal|*.intranet|*.corp|*.localdomain|*.localhost|*.test|*.example|*.invalid|*.home.arpa)
      echo local; return ;;
  esac
  ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true)
  [[ -z "$ips" ]] && { echo unresolved; return; }
  for ip in $ips; do
    if ! [[ "$ip" =~ ^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; then
      echo public; return
    fi
  done
  echo local
}

# IPv4 público numa interface do servidor (VPS sem NAT). Sem consulta externa:
# um servidor atrás de NAT na nuvem não aparece aqui, e o aviso não sai.
has_public_ipv4() {
  command -v ip &>/dev/null || return 1
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
    | grep -q .
}

port_in_use() {
  local port="$1"

  # ── Docker containers ───────────────────────────────────────────────────────
  local docker_hit
  docker_hit=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
    | grep -E "(^|[^0-9])${port}->" || true)
  if [[ -n "$docker_hit" ]]; then
    local container
    container=$(echo "$docker_hit" | awk '{print $1}')
    echo -e "  ${RED}✗ Porta ${port} já usada pelo container Docker: ${YELLOW}${container}${RESET}"
    return 1
  fi

  # ── Sistema operacional (ss ou netstat como fallback) ───────────────────────
  local sys_hit=""
  if command -v ss &>/dev/null; then
    sys_hit=$(ss -tlnp 2>/dev/null | grep -E ":${port}\b" | awk '{print $NF}' || true)
  elif command -v netstat &>/dev/null; then
    sys_hit=$(netstat -tlnp 2>/dev/null | grep -E ":${port}\b" | awk '{print $NF}' || true)
  fi
  if [[ -n "$sys_hit" ]]; then
    echo -e "  ${RED}✗ Porta ${port} já usada pelo processo: ${YELLOW}${sys_hit}${RESET}"
    return 1
  fi

  return 0
}

# ── Banner ────────────────────────────────────────────────────────────────────

echo -e "${CYAN}"
echo "  ██████╗  ██████╗ ██╗    ██╗██╗  ██╗ ██████╗ "
echo "  ██╔══██╗██╔════╝ ██║    ██║██║  ██║██╔═══██╗"
echo "  ██████╔╝██║  ███╗██║ █╗ ██║███████║██║   ██║"
echo "  ██╔═══╝ ██║   ██║██║███╗██║██╔══██║██║   ██║"
echo "  ██║     ╚██████╔╝╚███╔███╔╝██║  ██║╚██████╔╝"
echo "  ╚═╝      ╚═════╝  ╚══╝╚══╝ ╚═╝  ╚═╝ ╚═════╝ "
echo -e "${RESET}"
echo -e "  Instalação inicial — PostgreSQL Monitoring with AI\n"

# ── Pré-requisitos ────────────────────────────────────────────────────────────

section "Verificando pré-requisitos"

# Requisitos recomendados (docs/requisitos.md): só avisa, nunca interrompe.
CPUS_HOST=$(nproc 2>/dev/null || echo 0)
MEM_KB_HOST=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_GB_HOST=$(( ${MEM_KB_HOST:-0} / 1024 / 1024 ))
if [[ "$CPUS_HOST" -gt 0 && "$CPUS_HOST" -lt 6 ]] || [[ "${MEM_KB_HOST:-0}" -gt 0 && "$MEM_GB_HOST" -lt 11 ]]; then
  warn "Servidor com ${CPUS_HOST} CPU(s) e ${MEM_GB_HOST} GB: o recomendado é 6 CPUs e 12 GB."
  warn "O pgwho funciona, mas pode ficar lento com muitas instâncias monitoradas."
fi

for cmd in docker curl openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd não encontrado. Instale antes de continuar."
    exit 1
  fi
  info "$cmd ✓"
done

if ! docker compose version &>/dev/null; then
  error "Docker Compose plugin não encontrado. Execute: apt install docker-compose-plugin"
  exit 1
fi
info "docker compose ✓"

if ! docker info &>/dev/null; then
  error "Docker daemon não está rodando ou seu usuário não tem permissão."
  error "Execute: systemctl start docker  (ou adicione seu usuário ao grupo docker)"
  exit 1
fi
info "docker daemon ✓"

# Docker Desktop (Windows/WSL, macOS): o daemon roda numa VM própria. A raiz
# dela não aceita a montagem rslave; o update.sh grava
# PGWHO_HOST_ROOT_MOUNT_OPTS=ro no .env e a checagem abaixo não se aplica
# (no WSL o mountinfo do shell é o da distro, não o da VM do Docker). Issue #248.
DOCKER_OS=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)
[[ "$DOCKER_OS" == *"Docker Desktop"* ]] && info "Docker Desktop ✓"

# A raiz (/) do servidor precisa ser montagem compartilhada: o backend monta o
# / do servidor com propagação rslave (System Health) e, sem isso, não sobe.
# Systemd já deixa assim; sem systemd, falta um comando antes de instalar.
MOUNTINFO="${PGWHO_MOUNTINFO:-/proc/self/mountinfo}"   # substituível só nos testes
if [[ "${DOCKER_OS:-}" != *"Docker Desktop"* && -r "$MOUNTINFO" ]] && \
   ! awk '$5 == "/" { if ($0 ~ / shared:[0-9]+/) ok = 1 } END { exit ok ? 0 : 1 }' "$MOUNTINFO"; then
  error "A raiz (/) do servidor não é uma montagem compartilhada: o backend do pgwho não subiria."
  error "Rode como root:  mount --make-rshared /"
  error "e deixe isso no boot do servidor (sistemas com systemd já fazem isso). Depois rode o instalador de novo."
  exit 1
fi
info "montagem da raiz compartilhada ✓"

# ── Diretório de instalação ───────────────────────────────────────────────────

section "Preparando diretório"

# WSL: o /mnt/c, /mnt/d... é o disco do Windows. Lá o `chmod 600 .env` não tem
# efeito (senha e tokens ficariam legíveis) e o updater monta .env, update.sh e
# o compose através da ponte Windows↔Linux. Quem abre o WSL pelo cmd cai em
# /mnt/c/WINDOWS/system32 e instalaria ali. Issue #248.
PROC_VERSION="${PGWHO_PROC_VERSION:-/proc/version}"   # substituível só nos testes
if [[ "$INSTALL_DIR" == /mnt/[a-zA-Z]/* || "$INSTALL_DIR" == /mnt/[a-zA-Z] ]] && \
   grep -qi microsoft "$PROC_VERSION" 2>/dev/null; then
  error "O diretório de instalação está no disco do Windows: $INSTALL_DIR"
  error "Instale dentro do WSL, por exemplo:"
  error "  mkdir -p ~/pgwho && cd ~/pgwho && curl -fsSL $BASE_URL/install.sh | bash"
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
info "Diretório: $INSTALL_DIR"

# ── Baixar arquivos base ──────────────────────────────────────────────────────

section "Baixando arquivos"

curl -fsSL "$BASE_URL/docker-compose.client.yml" -o docker-compose.client.yml
info "docker-compose.client.yml ✓"

curl -fsSL "$BASE_URL/update.sh" -o update.sh
chmod +x update.sh
info "update.sh ✓"

# ── Detectar instalação existente ────────────────────────────────────────────

EXISTING_CONTAINERS=$(docker compose -f docker-compose.client.yml ps --quiet 2>/dev/null || true)

if [[ -n "$EXISTING_CONTAINERS" ]] || docker volume ls --quiet 2>/dev/null | grep -q "timescaledb_data"; then
  section "Instalação existente detectada"

  if [[ "${PGWHO_FRESH:-${PGWATCH_FRESH:-0}}" == "1" ]]; then
    REINSTALL=1
  else
    echo -e "  O pgwho já está instalado neste servidor."
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Atualização normal    — mantém dados históricos de monitoramento"
    echo -e "  ${CYAN}[2]${RESET} Reinstalação limpa    — ${RED}APAGA${RESET} dados de monitoramento e recria do zero"
    echo -e "       ${DIM}(targets, usuários e alertas configurados são preservados)${RESET}"
    echo ""
    echo -e "  ${DIM}Dica: passe PGWHO_FRESH=1 antes do curl para forçar reinstalação sem prompt.${RESET}"
    echo ""
    read -rp "  Escolha [1]: " INSTALL_CHOICE </dev/tty
    INSTALL_CHOICE="${INSTALL_CHOICE:-1}"
    [[ "$INSTALL_CHOICE" == "2" ]] && REINSTALL=1 || REINSTALL=0
  fi

  if [[ "${REINSTALL:-0}" == "1" ]]; then
    warn "Removendo instalação anterior (containers + volumes)..."
    docker compose -f docker-compose.client.yml down -v 2>/dev/null || true
    docker rm -f pgwatch_backend pgwatch_watchshell pgwatch_db pgwatch_frontend pgwatch_updater 2>/dev/null || true
    docker volume rm pgwatchai_timescaledb_data pgwho_timescaledb_data 2>/dev/null || true

    warn "Removendo imagens antigas do pgwho..."
    docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
      | grep -E 'ghcr.io/wislanmoraes/(pgwho|pgwatchai)' \
      | awk '{print $2}' \
      | xargs -r docker rmi -f 2>/dev/null || true

    warn "Limpando imagens sem tag (dangling)..."
    docker image prune -f 2>/dev/null || true

    info "Instalação anterior removida ✓"
    echo ""
  else
    info "Executando atualização normal..."
    SKIP_SELF_UPDATE=1 bash update.sh
    exit 0
  fi
fi

# ── Configurar .env ───────────────────────────────────────────────────────────

section "Configurando variáveis de ambiente"

if [[ -f ".env" ]]; then
  warn ".env já existe — pulando criação. Edite manualmente se necessário."
else
  # Valores gerados automaticamente
  DB_PASSWORD_GEN=$(openssl rand -hex 16)
  SECRET_KEY_GEN=$(openssl rand -hex 32)
  ENCRYPTION_KEY_GEN=$(openssl rand -base64 32 | tr '+/' '-_')   # chave Fernet (Issue #228)
  INSTALLATION_ID_GEN="inst-$(openssl rand -hex 16)"           # identidade da instalação (Issue #234)
  # Senha inicial do admin (Issue #264): nunca admin/admin. Mostrada só aqui no
  # terminal; o primeiro login exige trocar.
  ADMIN_PASSWORD_GEN=$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-16)

  echo ""
  echo -e "  Pressione ${CYAN}Enter${RESET} para aceitar o valor padrão indicado em ${CYAN}[colchetes]${RESET}."
  echo ""
  echo -e "  ${DIM}pgwho será instalado em: ${CYAN}${INSTALL_DIR}${RESET}"
  echo -e "  ${DIM}(para instalar em outro local: cd /outro/diretorio && curl ... | bash)${RESET}"
  echo ""

  # As imagens do pgwho são públicas (#239): o download não usa login nem
  # token. A licença é ativada depois, na tela (Configurações › Licença), com o
  # código PGW-... — o instalador não fala com o servidor de licenças.
  GHCR_USER_RESOLVED="wislanmoraes"
  echo ""

  # ── HTTPS (opcional, #269) ───────────────────────────────────────────────
  # Sem HTTPS, senha do login, sessão e senhas das instâncias passam em texto
  # puro pela rede. Com um domínio, o Caddy (serviço `https` do compose) emite
  # e renova o certificado; o painel em HTTP fica só no próprio servidor.
  echo -e "  ${CYAN}[OPCIONAL]${RESET} Domínio para acesso com HTTPS (certificado automático)"
  default "deixe vazio para acessar por http://IP:porta (rede interna ou proxy próprio)"
  default "com domínio: ele precisa apontar para este servidor, e as portas 80 e 443 ficam com o pgwho"
  PGWHO_DOMAIN=""
  PGWHO_TLS_INTERNAL=false
  while true; do
    read -rp "  PGWHO_DOMAIN [sem HTTPS]: " PGWHO_DOMAIN_INPUT </dev/tty
    PGWHO_DOMAIN_INPUT=$(echo "${PGWHO_DOMAIN_INPUT:-}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    PGWHO_DOMAIN_INPUT="${PGWHO_DOMAIN_INPUT#https://}"; PGWHO_DOMAIN_INPUT="${PGWHO_DOMAIN_INPUT#http://}"
    PGWHO_DOMAIN_INPUT="${PGWHO_DOMAIN_INPUT%/}"
    [[ -z "$PGWHO_DOMAIN_INPUT" ]] && break
    if ! [[ "$PGWHO_DOMAIN_INPUT" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
      error "Informe só o nome, ex.: pgwho.suaempresa.com.br"
      continue
    fi
    PGWHO_TLS_INTERNAL=false
    case "$(domain_kind "$PGWHO_DOMAIN_INPUT")" in
      local)
        echo ""
        warn "${PGWHO_DOMAIN_INPUT} é um nome de rede local (ou só aponta para IP privado):"
        warn "o Let's Encrypt só emite certificado para domínio público que chegue a este"
        warn "servidor pela internet. Aqui, só um certificado próprio do pgwho: o navegador"
        warn "mostra \"não seguro\" até você confiar nele (o final da instalação diz como)."
        read -rp "  Usar HTTPS com o certificado próprio do pgwho? [s/N]: " TLS_OK </dev/tty || TLS_OK=""
        if [[ ! "${TLS_OK:-}" =~ ^[sS]$ ]]; then
          echo -e "  ${DIM}Informe outro domínio ou deixe vazio para seguir sem HTTPS.${RESET}"
          continue
        fi
        PGWHO_TLS_INTERNAL=true
        ;;
      unresolved)
        echo ""
        warn "${PGWHO_DOMAIN_INPUT} ainda não resolve neste servidor. O certificado só sai quando"
        warn "o DNS apontar para cá e as portas 80 e 443 estiverem acessíveis pela internet."
        read -rp "  Seguir com este domínio mesmo assim? [s/N]: " TLS_OK </dev/tty || TLS_OK=""
        [[ "${TLS_OK:-}" =~ ^[sS]$ ]] || continue
        ;;
    esac
    if port_in_use 80 >/dev/null && port_in_use 443 >/dev/null; then
      PGWHO_DOMAIN="$PGWHO_DOMAIN_INPUT"
      if [[ "$PGWHO_TLS_INTERNAL" == true ]]; then
        info "HTTPS em https://${PGWHO_DOMAIN} com certificado próprio do pgwho ✓"
      else
        info "HTTPS em https://${PGWHO_DOMAIN} ✓"
      fi
      break
    fi
    port_in_use 80 || true; port_in_use 443 || true
    echo -e "  ${YELLOW}Libere as portas 80 e 443 ou deixe o domínio vazio.${RESET}"
  done
  echo ""

  # ── Porta do painel (com verificação de conflito) ────────────────────────
  PORT_DEFAULT=80
  if [[ -n "$PGWHO_DOMAIN" ]]; then
    PORT_DEFAULT=8080
    echo -e "  ${CYAN}[OPCIONAL]${RESET} Porta do painel em HTTP, só neste servidor (127.0.0.1)"
    default "padrão: 8080 — o acesso de fora é pelo HTTPS"
  else
    echo -e "  ${CYAN}[OPCIONAL]${RESET} Porta do painel web"
    default "padrão: 80 — verificamos se já está em uso antes de continuar"
  fi
  while true; do
    read -rp "  FRONTEND_PORT [${PORT_DEFAULT}]: " FRONTEND_PORT_INPUT </dev/tty
    FRONTEND_PORT="${FRONTEND_PORT_INPUT:-$PORT_DEFAULT}"
    if [[ -n "$PGWHO_DOMAIN" ]] && [[ "$FRONTEND_PORT" == "80" || "$FRONTEND_PORT" == "443" ]]; then
      echo -e "  ${YELLOW}As portas 80 e 443 ficam com o HTTPS; escolha outra.${RESET}"
      continue
    fi
    if port_in_use "$FRONTEND_PORT"; then
      info "Porta ${FRONTEND_PORT} disponível ✓"
      break
    fi
    echo -e "  ${YELLOW}Escolha outra porta ou resolva o conflito antes de continuar.${RESET}"
  done
  echo ""

  # ── Chave de IA (opcional) ────────────────────────────────────────────────
  echo -e "  ${CYAN}[OPCIONAL]${RESET} Chave de API de IA (Anthropic, OpenAI ou Google)"
  default "pode ser configurada depois na interface"
  read -rp "  ANTHROPIC_API_KEY [não configurado]: " ANTHROPIC_API_KEY_INPUT </dev/tty
  ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY_INPUT:-}"
  echo ""

  # ── Resumo antes de gravar ────────────────────────────────────────────────
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  echo -e "  ${DIM}PGWHO_DOMAIN    = ${PGWHO_DOMAIN:-sem HTTPS}${RESET}"
  echo -e "  ${DIM}FRONTEND_PORT   = ${FRONTEND_PORT}${RESET}"
  echo -e "  ${DIM}DB_PASSWORD     = (gerado automaticamente)${RESET}"
  echo -e "  ${DIM}SECRET_KEY      = (gerado automaticamente)${RESET}"
  echo -e "  ${DIM}ANTHROPIC_API_KEY = ${ANTHROPIC_API_KEY:-não configurado}${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  echo ""

  HTTPS_ENV=""
  if [[ -n "$PGWHO_DOMAIN" ]]; then
    HTTPS_ENV="
# ── HTTPS (Caddy, certificado automático) ─────────────────────────────────────
COMPOSE_PROFILES=https
PGWHO_DOMAIN=${PGWHO_DOMAIN}
# true = certificado próprio do pgwho (domínio de rede local; o navegador avisa
# até alguém confiar nele). false = Let's Encrypt.
PGWHO_TLS_INTERNAL=${PGWHO_TLS_INTERNAL}
FRONTEND_BIND=127.0.0.1:
PGWHO_PUBLIC_URL=https://${PGWHO_DOMAIN}"
  fi

  cat > .env <<EOF
# ── Banco de dados ────────────────────────────────────────────────────────────
DB_USER=pgwho
DB_NAME=pgwho
DB_PASSWORD=${DB_PASSWORD_GEN}

# ── Segurança ─────────────────────────────────────────────────────────────────
SECRET_KEY=${SECRET_KEY_GEN}
# Cifra as senhas das instâncias no banco interno. Guarde junto com o backup do
# banco e nunca troque: sem ela, as senhas gravadas não abrem.
PGWHO_ENCRYPTION_KEY=${ENCRYPTION_KEY_GEN}
# Identidade desta instalação para a licença: mantenha ao reinstalar.
PGWHO_INSTALLATION_ID=${INSTALLATION_ID_GEN}
# Senha inicial do admin: usada só no primeiro boot; o primeiro login exige trocar.
PGWHO_ADMIN_PASSWORD=${ADMIN_PASSWORD_GEN}

# ── Rede ──────────────────────────────────────────────────────────────────────
FRONTEND_PORT=${FRONTEND_PORT}
IMAGE_TAG=latest
${HTTPS_ENV}

# ── Integrações de IA (configure depois na UI se preferir) ────────────────────
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

# ── Collector ─────────────────────────────────────────────────────────────────
COLLECTOR_INTERVAL_SECONDS=60
ACTIVITY_SAMPLE_INTERVAL_SECONDS=5
ALERT_EVALUATION_INTERVAL_SECONDS=60

# ── Atualização (a licença é ativada na tela, com o código PGW-...) ──────────
GHCR_USER=${GHCR_USER_RESOLVED}
EOF

  chmod 600 .env   # senhas e chaves; os containers que o leem rodam como root
  info ".env criado ✓"
fi

# ── Primeira execução ─────────────────────────────────────────────────────────

section "Subindo containers"

SKIP_SELF_UPDATE=1 bash update.sh

# ── Resumo ────────────────────────────────────────────────────────────────────

section "Instalação concluída"

PORTA=$(grep -E '^FRONTEND_PORT=' .env 2>/dev/null | cut -d= -f2 || echo "80")
# Docker Desktop publica as portas no localhost do Windows/Mac; o IP da
# distro WSL ou da VM não é o endereço de acesso.
if [[ "${DOCKER_OS:-}" == *"Docker Desktop"* ]]; then
  IP=localhost
else
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

DOMINIO=$(grep -E '^PGWHO_DOMAIN=' .env 2>/dev/null | cut -d= -f2 || true)
PERFIS=$(grep -E '^COMPOSE_PROFILES=' .env 2>/dev/null | cut -d= -f2 || true)

echo ""
echo -e "  ${GREEN}✅ pgwho instalado com sucesso!${RESET}"
echo ""
if [[ -n "$DOMINIO" && ",${PERFIS}," == *",https,"* ]]; then
  echo -e "  Acesse:       ${CYAN}https://${DOMINIO}${RESET}"
  if [[ "$(grep -E '^PGWHO_TLS_INTERNAL=' .env 2>/dev/null | cut -d= -f2 || true)" == "true" ]]; then
    echo ""
    warn "Certificado próprio do pgwho (rede local): o navegador mostra \"não seguro\" até"
    warn "você confiar nele. Para confiar, exporte o certificado raiz:"
    echo -e "    ${CYAN}docker compose -f docker-compose.client.yml cp https:/data/caddy/pki/authorities/local/root.crt ./pgwho-ca.crt${RESET}"
    default "e importe o pgwho-ca.crt como autoridade raiz confiável em cada computador que acessa:"
    default "Windows: certmgr.msc › Autoridades de Certificação Raiz Confiáveis › Importar"
    default "macOS: Acesso às Chaves › Sistema, e marque \"Confiar sempre\""
    default "Linux: copie para /usr/local/share/ca-certificates/ e rode update-ca-certificates"
    default "O nome ${DOMINIO} também precisa resolver nesses computadores (DNS interno ou arquivo hosts)."
  else
    default "o certificado sai no primeiro acesso; se falhar: docker logs pgwho_https"
  fi
else
  echo -e "  Acesse:       ${CYAN}http://${IP}:${PORTA}${RESET}"
  # #269: painel sem HTTPS num servidor com IP público = senha e sessão em
  # texto puro pela internet. Só um aviso: a decisão (firewall, rede interna, proxy
  # próprio) é de quem instala.
  if has_public_ipv4; then
    echo ""
    warn "Este servidor tem IP público e o painel está sem HTTPS: a senha do login"
    warn "e as senhas das instâncias passariam em texto puro pela internet."
    warn "Feche a porta ${PORTA} no firewall (acesso só pela rede interna) ou"
    warn "reinstale informando um domínio para HTTPS."
  fi
fi
INITIAL_PW=$(grep -E '^PGWHO_ADMIN_PASSWORD=' .env 2>/dev/null | cut -d= -f2- || true)
if [[ -n "$INITIAL_PW" ]]; then
  echo -e "  Login:        ${CYAN}admin / ${INITIAL_PW}${RESET}  ← senha inicial; o primeiro acesso pede uma nova"
else
  echo -e "  Login:        ${CYAN}admin${RESET} com a senha que você já usava"
fi
echo ""
echo -e "  Licença:      ${CYAN}Configurações › Licença${RESET} — cole o código de ativação (PGW-...)"
echo ""
echo -e "  Arquivos em:  ${CYAN}${INSTALL_DIR}${RESET}"
echo ""
echo -e "  Para atualizar no futuro:"
echo -e "    ${CYAN}cd ${INSTALL_DIR} && ./update.sh${RESET}"
echo ""
