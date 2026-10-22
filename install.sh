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
#    5. Faz login no GHCR e sobe os containers
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

# ── Diretório de instalação ───────────────────────────────────────────────────

section "Preparando diretório"

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

  echo ""
  echo -e "  Pressione ${CYAN}Enter${RESET} para aceitar o valor padrão indicado em ${CYAN}[colchetes]${RESET}."
  echo ""
  echo -e "  ${DIM}pgwho será instalado em: ${CYAN}${INSTALL_DIR}${RESET}"
  echo -e "  ${DIM}(para instalar em outro local: cd /outro/diretorio && curl ... | bash)${RESET}"
  echo ""

  # ── Chave de Ativação pgwho (valida via site e obtém token GHCR) ──────────
  LICENSE_API_URL="${PGWHO_LICENSE_API:-https://pgwho.com/crm/api.php?action=validate_license}"

  # O GHCR aceita este token para baixar as imagens? (HTTP 200 no endpoint de token)
  ghcr_token_works() {
    local user="$1" token="$2" code
    code=$(curl -s -o /dev/null -w "%{http_code}" -u "${user}:${token}" \
      "https://ghcr.io/token?scope=repository:${user}/pgwho-backend:pull&service=ghcr.io" 2>/dev/null || true)
    [[ "$code" == "200" ]]
  }

  LICENSE_KEY_INPUT=""
  GHCR_TOKEN_INPUT=""
  GHCR_USER_RESOLVED="wislanmoraes"

  echo -e "  ${YELLOW}[OBRIGATÓRIO]${RESET} Chave de Ativação pgwho (enviada por e-mail / Portal CRM)"
  echo -e "  Formato: ${CYAN}TMA-XXXX-XXXX-...${RESET}"
  echo ""
  while true; do
    read -rp "  LICENSE_KEY: " RAW_KEY_INPUT </dev/tty
    RAW_KEY_INPUT="$(echo "$RAW_KEY_INPUT" | tr -d '[:space:]')"
    if [[ -z "$RAW_KEY_INPUT" ]]; then
      echo -e "  ${RED}Chave obrigatória.${RESET} Informe sua Chave de Ativação para validar e liberar o download."
      continue
    fi

    # Suporte legado caso seja informado um PAT ghp_ diretamente
    if [[ "$RAW_KEY_INPUT" == ghp_* ]] || [[ "$RAW_KEY_INPUT" == github_pat_* ]]; then
      GHCR_TOKEN_INPUT="$RAW_KEY_INPUT"
      info "Token GHCR direto informado ✓"
      break
    fi

    info "Validando Chave de Ativação em pgwho.com..."
    VALIDATION_JSON=$(curl -fsSL -X POST "$LICENSE_API_URL" \
      -H "Content-Type: application/json" \
      -d "{\"access_key\":\"${RAW_KEY_INPUT}\"}" 2>/dev/null || true)

    if [[ -z "$VALIDATION_JSON" ]]; then
      error "Não foi possível contatar o servidor de licenças (${LICENSE_API_URL})."
      continue
    fi

    IS_VALID=$(echo "$VALIDATION_JSON" | grep -oE '"valid"\s*:\s*(true|false)' | head -1 | grep -oE '(true|false)' || echo "false")
    if [[ "$IS_VALID" != "true" ]]; then
      ERR_MSG=$(echo "$VALIDATION_JSON" | sed -n 's/.*"message"\s*:\s*"\([^"]*\)".*/\1/p' | head -1)
      error "Chave inválida ou expirada: ${ERR_MSG:-Verifique sua chave no Portal CRM.}"
      continue
    fi

    EXTRACTED_TOKEN=$(echo "$VALIDATION_JSON" | sed -n 's/.*"github_token"\s*:\s*"\([^"]*\)".*/\1/p' | head -1)
    EXTRACTED_USER=$(echo "$VALIDATION_JSON" | sed -n 's/.*"ghcr_user"\s*:\s*"\([^"]*\)".*/\1/p' | head -1)
    EXTRACTED_EXP=$(echo "$VALIDATION_JSON" | sed -n 's/.*"expires_at"\s*:\s*"\([^"]*\)".*/\1/p' | head -1)

    if [[ -z "$EXTRACTED_TOKEN" ]]; then
      error "Licença válida, porém o token de pacotes não pôde ser obtido. Contate o suporte pgwho."
      continue
    fi

    if ! ghcr_token_works "${EXTRACTED_USER:-wislanmoraes}" "$EXTRACTED_TOKEN"; then
      # A chave é válida: guarda para o .env mesmo que o token venha de outro lugar.
      LICENSE_KEY_INPUT="$RAW_KEY_INPUT"
      error "Licença válida, porém o token de pacotes não foi aceito pelo GHCR (recusado ou GHCR inacessível). Informe um token do GitHub (ghp_...) com read:packages ou contate o suporte pgwho."
      continue
    fi

    LICENSE_KEY_INPUT="$RAW_KEY_INPUT"
    GHCR_TOKEN_INPUT="$EXTRACTED_TOKEN"
    GHCR_USER_RESOLVED="${EXTRACTED_USER:-wislanmoraes}"
    info "Licença validada com sucesso! (Válida até: ${EXTRACTED_EXP:-vigente}) ✓"
    break
  done
  echo ""

  # ── Porta do painel (com verificação de conflito) ────────────────────────
  echo -e "  ${CYAN}[OPCIONAL]${RESET} Porta do painel web"
  default "padrão: 80 — verificamos se já está em uso antes de continuar"
  while true; do
    read -rp "  FRONTEND_PORT [80]: " FRONTEND_PORT_INPUT </dev/tty
    FRONTEND_PORT="${FRONTEND_PORT_INPUT:-80}"
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
  echo -e "  ${DIM}FRONTEND_PORT   = ${FRONTEND_PORT}${RESET}"
  echo -e "  ${DIM}DB_PASSWORD     = (gerado automaticamente)${RESET}"
  echo -e "  ${DIM}SECRET_KEY      = (gerado automaticamente)${RESET}"
  echo -e "  ${DIM}ANTHROPIC_API_KEY = ${ANTHROPIC_API_KEY:-não configurado}${RESET}"
  [[ -n "$LICENSE_KEY_INPUT" ]] && echo -e "  ${DIM}LICENSE_KEY     = ${LICENSE_KEY_INPUT:0:13}…${RESET}"
  echo -e "  ${DIM}GHCR_TOKEN      = (sincronizado via licença)${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  echo ""

  cat > .env <<EOF
# ── Banco de dados ────────────────────────────────────────────────────────────
DB_USER=pgwho
DB_NAME=pgwho
DB_PASSWORD=${DB_PASSWORD_GEN}

# ── Segurança ─────────────────────────────────────────────────────────────────
SECRET_KEY=${SECRET_KEY_GEN}

# ── Rede ──────────────────────────────────────────────────────────────────────
FRONTEND_PORT=${FRONTEND_PORT}
IMAGE_TAG=latest

# ── Integrações de IA (configure depois na UI se preferir) ────────────────────
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

# ── Collector ─────────────────────────────────────────────────────────────────
COLLECTOR_INTERVAL_SECONDS=60
ACTIVITY_SAMPLE_INTERVAL_SECONDS=5
ALERT_EVALUATION_INTERVAL_SECONDS=60

# ── Licenciamento & Atualização ───────────────────────────────────────────────
LICENSE_KEY=${LICENSE_KEY_INPUT}
GHCR_TOKEN=${GHCR_TOKEN_INPUT}
GHCR_USER=${GHCR_USER_RESOLVED}
EOF

  info ".env criado ✓"
fi

# ── Primeira execução ─────────────────────────────────────────────────────────

section "Subindo containers"

SKIP_SELF_UPDATE=1 bash update.sh

# ── Resumo ────────────────────────────────────────────────────────────────────

section "Instalação concluída"

PORTA=$(grep -E '^FRONTEND_PORT=' .env 2>/dev/null | cut -d= -f2 || echo "80")
IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "  ${GREEN}✅ pgwho instalado com sucesso!${RESET}"
echo ""
echo -e "  Acesse:       ${CYAN}http://${IP}:${PORTA}${RESET}"
echo -e "  Login padrão: ${CYAN}admin / admin${RESET}  ← troque a senha após o primeiro acesso"
echo ""
echo -e "  Arquivos em:  ${CYAN}${INSTALL_DIR}${RESET}"
echo ""
echo -e "  Para atualizar no futuro:"
echo -e "    ${CYAN}cd ${INSTALL_DIR} && ./update.sh${RESET}"
echo ""
