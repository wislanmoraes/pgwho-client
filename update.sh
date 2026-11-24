#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  pgwho — Script de atualização para parceiros
#
#  Uso:
#    ./update.sh                          # usa variáveis de ambiente ou .env
#
#  Ou sempre na versão mais recente, sem baixar nada localmente:
#    curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/update.sh | bash
#
#  Variáveis de ambiente:
#    GHCR_USER        Usuário GitHub (padrão: wislanmoraes)
#    COMPOSE_FILE     Arquivo compose (padrão: docker-compose.client.yml)
#    HOST_DEPLOY_DIR  Caminho REAL no host do diretório de deploy (setado
#                      automaticamente pelo compose via ${PWD} na criação do
#                      updater) — necessário pra ele recriar a si mesmo.
#    SKIP_SELF_UPDATE=1  Desativa a auto-atualização deste script
#
#  Nota pra instalações de ANTES desta variável existir: a primeira
#  atualização depois de adotar isso ainda vai pedir um passo manual único
#  (o updater atual em execução não tem HOST_DEPLOY_DIR) — depois disso,
#  nunca mais precisa de intervenção manual:
#    docker compose -f docker-compose.client.yml up -d --force-recreate updater
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# DEPLOY_DIR (setado pelo sidecar `updater`, ver updater/main.py
# _fresh_update_script) tem prioridade sobre BASH_SOURCE: o sidecar busca
# uma cópia FRESCA deste script em /tmp antes de cada execução (contorna o
# bind mount :ro de update.sh e evita self-modificação de um script em
# execução — ver Issue #74), então ${BASH_SOURCE[0]} apontaria pra /tmp, não
# pra onde .env/docker-compose.client.yml realmente estão.
SCRIPT_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ── Cores para output ─────────────────────────────────────────────────────────

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; RESET="\033[0m"
info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Auto-atualização do próprio script ───────────────────────────────────────
# Baixa a versão mais recente de si mesmo do GitHub antes de prosseguir.
# Se executado via pipe (curl | bash), pula esta etapa automaticamente.

SCRIPT_URL="https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/update.sh"
SELF="$SCRIPT_DIR/update.sh"

if [[ "${SKIP_SELF_UPDATE:-0}" != "1" ]] && [[ -t 0 ]] && command -v curl &>/dev/null; then
  info "Verificando versão do script de atualização..."
  TEMP="$(mktemp)"
  if curl -fsSL "$SCRIPT_URL" -o "$TEMP" 2>/dev/null; then
    if ! cmp -s "$TEMP" "$SELF"; then
      info "Script atualizado. Reiniciando..."
      mv "$TEMP" "$SELF"
      chmod +x "$SELF"
      SKIP_SELF_UPDATE=1 exec bash "$SELF" "$@"
    else
      rm -f "$TEMP"
      info "Script já está na versão mais recente."
    fi
  else
    rm -f "$TEMP"
    warn "Não foi possível verificar atualização do script — continuando com a versão local."
  fi
fi

# ── A raiz do servidor aceita a montagem rslave? ─────────────────────────────
# Desde a v0.4.33 o compose monta o / do servidor no backend com propagação
# rslave (System Health, Issue #158). O Docker só aceita isso com a raiz do
# servidor marcada como montagem compartilhada — o padrão com systemd. Sem
# ela o backend NÃO SOBE ("path / is mounted on / but it is not a shared or
# slave mount"). Este teste roda ANTES de trocar o compose: se falhar, o
# update para e o cliente segue na versão atual, funcionando.
#   0 = aceita   1 = recusa   2 = não deu para testar
root_rslave_ok() {
  # Caminhos substituíveis só nos testes (.github/ci/rslave-preflight-tests.sh).
  local mountinfo="${PGWHO_MOUNTINFO:-/proc/self/mountinfo}" dockerenv="${PGWHO_DOCKERENV:-/.dockerenv}"
  # Executado direto no servidor (à mão, ou pelo install.sh): o mountinfo
  # do próprio processo é o do servidor.
  if [[ ! -f "$dockerenv" && -r "$mountinfo" ]]; then
    awk '$5 == "/" { found = 1; if ($0 ~ / shared:[0-9]+/) ok = 1 } END { exit found ? (ok ? 0 : 1) : 2 }' \
      "$mountinfo"
    return $?
  fi
  # Dentro do sidecar updater o mountinfo é o do container: pergunta ao
  # próprio Docker, com uma imagem que já está no servidor (nunca baixa nada:
  # servidores com firewall só liberam o ghcr.io, e o Docker Hub limita pulls).
  command -v docker &>/dev/null || return 2
  local img out
  img=$(docker inspect --format '{{.Config.Image}}' pgwho_backend 2>/dev/null || true)
  [[ -n "$img" ]] || img=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 'pgwho-backend' || true)
  [[ -n "$img" ]] || return 2
  if out=$(docker run --rm --pull never --entrypoint true \
             --mount type=bind,source=/,target=/host/root,readonly,bind-propagation=rslave "$img" 2>&1); then
    return 0
  fi
  # "not a shared or slave mount" ou "not a shared mount", conforme a versão do Docker.
  grep -qiE "shared or slave|not a shared mount" <<<"$out" && return 1
  return 2
}

# ── Docker Desktop (Windows/WSL, macOS) — Issue #248 ─────────────────────────
# O daemon roda numa VM própria cuja raiz não é compartilhada: o rslave é
# recusado e o backend não sobe. Lá o / montado é o da VM do Docker (não o do
# Windows/Mac), então a propagação não traz ganho: a montagem fica só `ro`
# (PGWHO_HOST_ROOT_MOUNT_OPTS, lida pelo compose). O mountinfo do shell não
# serve para detectar isso: no WSL ele é o da distro, que tem systemd.
# PGWHO_DOCKER_OS é substituível só nos testes.
docker_desktop() {
  [[ -n "${PGWHO_DOCKER_OS+x}" ]] || PGWHO_DOCKER_OS=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)
  [[ "$PGWHO_DOCKER_OS" == *"Docker Desktop"* ]]
}

env_file_value() {  # env_file_value <VAR> <arquivo .env>
  [[ -f "${2:-}" ]] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -1 | tr -d "\"' \r"
}

# Grava PGWHO_HOST_ROOT_MOUNT_OPTS=ro no .env no Docker Desktop. Nunca troca um
# valor que já esteja lá (quem definiu à mão sabe o que quer).
host_root_opts_for_docker_desktop() {
  local env_file="$1"
  docker_desktop || return 0
  [[ -f "$env_file" ]] || return 0
  grep -q '^[[:space:]]*PGWHO_HOST_ROOT_MOUNT_OPTS[[:space:]]*=' "$env_file" && return 0
  if [[ ! -w "$env_file" ]]; then
    warn "Docker Desktop: o .env não pode ser alterado daqui. Rode ./update.sh no servidor uma vez."
    return 0
  fi
  printf '\n# Docker Desktop: a raiz da VM do Docker não aceita a montagem rslave (Issue #248).\nPGWHO_HOST_ROOT_MOUNT_OPTS=ro\n' >> "$env_file"
  export PGWHO_HOST_ROOT_MOUNT_OPTS=ro
  info "Docker Desktop: raiz do servidor montada sem rslave (PGWHO_HOST_ROOT_MOUNT_OPTS=ro no .env) ✓"
}

rslave_preflight() {  # rslave_preflight <compose novo> [.env]
  local new_compose="$1" env_file="${2:-}" rc=0 opts
  grep -Eq 'propagation: rslave|ro,rslave\}' "$new_compose" 2>/dev/null || return 0
  # A instalação já monta a raiz sem rslave: nada a testar.
  opts="${PGWHO_HOST_ROOT_MOUNT_OPTS:-$(env_file_value PGWHO_HOST_ROOT_MOUNT_OPTS "$env_file")}"
  [[ -n "$opts" && "$opts" != *rslave* ]] && return 0
  docker_desktop && return 0
  root_rslave_ok || rc=$?
  case $rc in
    0) info "Montagem da raiz do servidor compatível ✓" ;;
    1) error "A raiz (/) do servidor não é uma montagem compartilhada: a nova versão não subiria o backend."
       error "Rode no servidor, como root:  mount --make-rshared /"
       error "e deixe isso no boot do servidor (sistemas com systemd já fazem isso). Depois atualize de novo."
       error "Nada foi alterado: o pgwho continua na versão atual."
       return 1 ;;
    *) warn "Não foi possível testar a montagem da raiz do servidor (sem imagem local do backend) — continuando."
       warn "Se o backend não subir com 'not a shared or slave mount', rode no servidor: mount --make-rshared /" ;;
  esac
  return 0
}

# ── Auto-atualização do docker-compose.client.yml ────────────────────────────
# Roda sempre (independente de SKIP_SELF_UPDATE) para garantir que novos
# serviços (ex: updater sidecar) sejam adicionados ao compose do cliente.

CLIENT_RAW_URL="https://raw.githubusercontent.com/wislanmoraes/pgwho-client"

host_root_opts_for_docker_desktop "$SCRIPT_DIR/.env"

# IMAGE_TAG fixado pela instalação (ambiente ou .env — o .env só é carregado
# mais abaixo). Vazio quando segue a última versão.
pinned_image_tag() {
  local t="${IMAGE_TAG:-}"
  if [[ -z "$t" && -f "$SCRIPT_DIR/.env" ]]; then
    t=$(sed -n 's/^[[:space:]]*IMAGE_TAG[[:space:]]*=[[:space:]]*//p' "$SCRIPT_DIR/.env" | tail -1 | tr -d "\"' \r")
  fi
  t="${t#v}"
  # Só caracteres de tag de imagem: o valor entra numa URL.
  [[ "$t" =~ ^[0-9A-Za-z._-]+$ && "$t" != "latest" ]] && echo "$t"
  return 0
}

# URLs do compose em ordem de preferência: com IMAGE_TAG=0.4.32, o compose da
# tag v0.4.32 do pgwho-client (o que acompanha aquelas imagens); se a tag não
# existir lá (versão anterior à publicação por tag, tag de commit), a main.
compose_urls() {
  local tag
  tag=$(pinned_image_tag)
  [[ -n "$tag" ]] && echo "$CLIENT_RAW_URL/v${tag}/docker-compose.client.yml"
  echo "$CLIENT_RAW_URL/main/docker-compose.client.yml"
}

if command -v curl &>/dev/null; then
  COMPOSE_TMP="$(mktemp)"
  COMPOSE_URL=""
  for url in $(compose_urls); do
    if curl -fsSL "$url" -o "$COMPOSE_TMP" 2>/dev/null; then
      COMPOSE_URL="$url"
      break
    fi
    [[ "$url" == */main/* ]] || warn "Compose da versão fixada não encontrado no pgwho-client ($url) — usando o da main."
  done
  if [[ -n "$COMPOSE_URL" ]]; then
    [[ "$COMPOSE_URL" == */main/* ]] || info "Usando o docker-compose.client.yml da versão fixada (${COMPOSE_URL#"$CLIENT_RAW_URL"/})."
    TARGET_COMPOSE="$SCRIPT_DIR/${COMPOSE_FILE:-docker-compose.client.yml}"
    if ! cmp -s "$COMPOSE_TMP" "$TARGET_COMPOSE"; then
      if ! rslave_preflight "$COMPOSE_TMP" "$SCRIPT_DIR/.env"; then
        rm -f "$COMPOSE_TMP"
        exit 1
      fi
      info "docker-compose.client.yml atualizado."
      # Achado ao vivo num cliente: este arquivo é montado no sidecar
      # `updater` como bind mount de ARQUIVO ÚNICO (ver docker-compose.
      # client.yml, serviço updater — precisa ser gravável, ao contrário de
      # .env/update.sh que são :ro). `mv` faz um rename() atômico, que TROCA
      # o inode do destino — o kernel recusa isso quando o caminho tem algo
      # montado nele (exatamente o que um bind mount de arquivo é) e devolve
      # EBUSY ("Resource busy"), abortando a atualização logo depois de
      # baixar o compose novo, antes até do `docker compose pull`. `cat` (ou
      # `cp` sem --remove-destination) escreve NO MESMO inode em vez de
      # trocá-lo — compatível com esse tipo de bind mount.
      cat "$COMPOSE_TMP" > "$TARGET_COMPOSE"
      rm -f "$COMPOSE_TMP"
    else
      rm -f "$COMPOSE_TMP"
    fi
  else
    rm -f "$COMPOSE_TMP"
    warn "Não foi possível atualizar docker-compose.client.yml — continuando com a versão local."
  fi
fi

# ── Carrega .env se existir ───────────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

# ── Chave dos segredos do banco interno (Issue #228) ─────────────────────────
# Sem PGWHO_ENCRYPTION_KEY, as senhas das instâncias, os segredos dos canais e
# as chaves de IA ficam cifrados com uma semente que está no código: qualquer
# cópia do banco os abre. Gera a chave uma vez e nunca troca uma que exista —
# trocar deixaria ilegível tudo o que foi gravado com a anterior. O backend
# regrava os segredos com a chave nova no boot.
if [[ -z "${PGWHO_ENCRYPTION_KEY:-}" && -f "$SCRIPT_DIR/.env" ]]; then
  if [[ -w "$SCRIPT_DIR/.env" ]] && command -v openssl &>/dev/null; then
    NEW_ENCRYPTION_KEY=$(openssl rand -base64 32 | tr '+/' '-_')
    if grep -q '^PGWHO_ENCRYPTION_KEY=' "$SCRIPT_DIR/.env"; then
      # A linha existe mas está vazia (o -z acima garante): preenche. awk + cat
      # em vez de `sed -i`: funciona com o sed do macOS e mantém o arquivo (dono,
      # permissão 600, bind mount).
      awk -v k="$NEW_ENCRYPTION_KEY" '/^PGWHO_ENCRYPTION_KEY=/{print "PGWHO_ENCRYPTION_KEY=" k; next} {print}' \
        "$SCRIPT_DIR/.env" > "$SCRIPT_DIR/.env.tmp.$$" && cat "$SCRIPT_DIR/.env.tmp.$$" > "$SCRIPT_DIR/.env"
      rm -f "$SCRIPT_DIR/.env.tmp.$$"
    else
      printf '\n# Chave dos segredos do banco interno: guarde junto com o backup do banco.\nPGWHO_ENCRYPTION_KEY=%s\n' \
        "$NEW_ENCRYPTION_KEY" >> "$SCRIPT_DIR/.env"
    fi
    export PGWHO_ENCRYPTION_KEY="$NEW_ENCRYPTION_KEY"
    info "Chave dos segredos do banco interno gerada (PGWHO_ENCRYPTION_KEY no .env) ✓"
    warn "Guarde o .env junto com o backup do banco: sem a chave, um banco restaurado não abre as senhas das instâncias."
  else
    warn "PGWHO_ENCRYPTION_KEY não definida e o .env não pode ser alterado daqui (atualização pela tela)."
    warn "Rode ./update.sh no servidor uma vez para gerar a chave dos segredos do banco interno."
  fi
fi
# ── fim: chave dos segredos ──────────────────────────────────────────────────

# ── Configuração ─────────────────────────────────────────────────────────────

GHCR_USER="${GHCR_USER:-wislanmoraes}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.client.yml}"
REGISTRY="ghcr.io"

# ── Verificações ──────────────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
  error "Docker não encontrado. Instale o Docker antes de continuar."
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  error "Arquivo '$COMPOSE_FILE' não encontrado. Execute o script na pasta correta."
  exit 1
fi

# ── Acesso às imagens (#239) ─────────────────────────────────────────────────
# As imagens do pgwho são públicas e os tokens de pacotes foram revogados: o
# download não usa login. Um GHCR_TOKEN que tenha ficado no .env sai dele.

# Tira GHCR_TOKEN do .env sem trocar o arquivo (cat > mantém dono, permissão e
# o inode do bind mount do updater). Dentro do updater o .env é :ro — fica para
# o próximo ./update.sh no servidor.
drop_ghcr_token_from_env() {
  local envf="$SCRIPT_DIR/.env" tmp
  [[ -f "$envf" ]] && grep -q '^GHCR_TOKEN=' "$envf" || return 0
  if [[ ! -w "$envf" ]]; then
    info "O token de imagens no .env não é mais usado; sai no próximo ./update.sh no servidor."
    return 0
  fi
  tmp=$(mktemp)
  grep -v '^GHCR_TOKEN=' "$envf" > "$tmp" || true
  cat "$tmp" > "$envf"
  rm -f "$tmp"
  info "Token de acesso às imagens removido do .env (não é mais necessário) ✓"
}

drop_ghcr_token_from_env
unset GHCR_TOKEN

# ── Preservação automática de volume (migração pgwatchai -> pgwho) ────────────
if [[ -z "${DATA_VOLUME_NAME:-}" ]] && docker volume inspect pgwatchai_timescaledb_data >/dev/null 2>&1; then
  export DATA_VOLUME_NAME="pgwatchai_timescaledb_data"
  export DB_USER="${DB_USER:-pgwatch}"
  export DB_NAME="${DB_NAME:-pgwatch_ai}"
  if [[ -w "$SCRIPT_DIR/.env" ]]; then
    if ! grep -q '^DATA_VOLUME_NAME=' "$SCRIPT_DIR/.env"; then
      echo "DATA_VOLUME_NAME=pgwatchai_timescaledb_data" >> "$SCRIPT_DIR/.env"
    fi
    if ! grep -q '^DB_USER=' "$SCRIPT_DIR/.env"; then
      echo "DB_USER=$DB_USER" >> "$SCRIPT_DIR/.env"
    fi
    if ! grep -q '^DB_NAME=' "$SCRIPT_DIR/.env"; then
      echo "DB_NAME=$DB_NAME" >> "$SCRIPT_DIR/.env"
    fi
    info "Volume legado (pgwatchai_timescaledb_data) detectado e preservado no .env."
  elif [[ -w "$SCRIPT_DIR/$COMPOSE_FILE" ]]; then
    sed -i 's/pgwho_timescaledb_data/pgwatchai_timescaledb_data/g' "$SCRIPT_DIR/$COMPOSE_FILE" 2>/dev/null || true
    info "Volume legado (pgwatchai_timescaledb_data) detectado e preservado no compose."
  fi
fi

# ── Identidade da instalação para a licença v2 (Issue #234) ───────────────────
# PGWHO_INSTALLATION_ID vive no .env: reinstalar com o mesmo .env mantém a
# ativação. Numa instalação que ainda não tem a variável, adota o id que o
# backend já guardou no banco (atualizações feitas pela tela não escrevem no
# .env); só sem nenhum gera um novo. Nunca troca um id que já exista.
if [[ -z "${PGWHO_INSTALLATION_ID:-}" && -f "$SCRIPT_DIR/.env" ]]; then
  if [[ -w "$SCRIPT_DIR/.env" ]]; then
    NEW_INSTALLATION_ID=""
    for db_container in pgwho_db pgwatch_db; do
      NEW_INSTALLATION_ID=$(docker exec "$db_container" psql -U "${DB_USER:-pgwho}" -d "${DB_NAME:-pgwho}" -tAc \
        "SELECT value FROM system_settings WHERE key = 'installation_id'" 2>/dev/null | tr -d '[:space:]' || true)
      [[ -n "$NEW_INSTALLATION_ID" ]] && break
    done
    if [[ ! "$NEW_INSTALLATION_ID" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
      if command -v openssl &>/dev/null; then
        NEW_INSTALLATION_ID="inst-$(openssl rand -hex 16)"
      else
        NEW_INSTALLATION_ID="inst-$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
      fi
    fi
    if grep -q '^PGWHO_INSTALLATION_ID=' "$SCRIPT_DIR/.env"; then
      awk -v k="$NEW_INSTALLATION_ID" '/^PGWHO_INSTALLATION_ID=/{print "PGWHO_INSTALLATION_ID=" k; next} {print}' \
        "$SCRIPT_DIR/.env" > "$SCRIPT_DIR/.env.tmp.$$" && cat "$SCRIPT_DIR/.env.tmp.$$" > "$SCRIPT_DIR/.env"
      rm -f "$SCRIPT_DIR/.env.tmp.$$"
    else
      printf '\n# Identidade desta instalação para a licença: mantenha ao reinstalar.\nPGWHO_INSTALLATION_ID=%s\n' \
        "$NEW_INSTALLATION_ID" >> "$SCRIPT_DIR/.env"
    fi
    export PGWHO_INSTALLATION_ID="$NEW_INSTALLATION_ID"
    info "Identidade da instalação gravada no .env (PGWHO_INSTALLATION_ID) ✓"
  else
    warn "PGWHO_INSTALLATION_ID não definida e o .env não pode ser alterado daqui (atualização pela tela)."
    warn "O backend usa o id guardado no banco; rode ./update.sh no servidor uma vez para gravá-lo no .env."
  fi
fi
# ── fim: identidade da instalação ────────────────────────────────────────────

# ── Espaço em disco ───────────────────────────────────────────────────────────
# As imagens novas (~2,5 GB) são baixadas antes das antigas saírem. Sem espaço,
# o pull enche o disco e o banco não sobe depois ("No space left on device"),
# deixando a aplicação fora do ar. Checar ANTES de parar qualquer coisa.

MIN_FREE_GB="${PGWHO_MIN_FREE_GB:-4}"

info "Removendo imagens antigas sem tag antes de baixar..."
docker image prune -f >/dev/null 2>&1 || true

DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
# Dentro do updater, o caminho do host não existe; "/" do container fica no
# mesmo disco que guarda as imagens do Docker.
[[ -n "$DOCKER_ROOT" && -d "$DOCKER_ROOT" ]] || DOCKER_ROOT="/"
FREE_KB=$(df -Pk "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || true)
if [[ "$FREE_KB" =~ ^[0-9]+$ ]]; then
  FREE_GB=$(awk -v kb="$FREE_KB" 'BEGIN {printf "%.1f", kb / 1048576}')
  if (( FREE_KB < MIN_FREE_GB * 1048576 )); then
    error "Espaço livre insuficiente para atualizar: ${FREE_GB} GB (mínimo ${MIN_FREE_GB} GB)."
    error "Nada foi alterado: a versão atual continua no ar."
    error "Libere espaço no host e rode de novo, por exemplo:"
    error "  docker image prune -a      # imagens que nenhum container usa"
    error "  journalctl --vacuum-size=200M"
    error "  df -h /                    # conferir"
    exit 1
  fi
  info "Espaço livre: ${FREE_GB} GB ✓"
else
  warn "Não foi possível medir o espaço livre — seguindo com a atualização."
fi

# ── Baixar novas imagens ──────────────────────────────────────────────────────

info "Baixando novas imagens..."
pull_images() {
  docker compose -f "$COMPOSE_FILE" pull \
    && docker compose -f "$COMPOSE_FILE" --profile tools pull watchshell  # profile 'tools'
}
if ! pull_images; then
  # O Docker pode ter mandado uma credencial antiga do ghcr.io (token revogado,
  # #239), que o GHCR recusa até para imagem pública. Ela não serve para nada:
  # sai dela e tenta de novo sem login.
  warn "Falha ao baixar as imagens; tentando de novo sem a credencial guardada do $REGISTRY."
  docker logout "$REGISTRY" >/dev/null 2>&1 || true
  if ! pull_images; then
    error "Não foi possível baixar as imagens."
    exit 1
  fi
fi

# ── Reiniciar serviços ────────────────────────────────────────────────────────

# Quem recria os containers é o `docker compose up`: ele só troca o que mudou
# (imagem ou configuração do serviço). O banco interno não é mais parado à mão
# em toda atualização — com a mesma imagem e o mesmo serviço, segue no ar.
# Parar à mão só sobra para o que o compose não reconhece como seu:
# - containers pgwatch_* do nome antigo (rebrand), que nenhum compose recria;
# - um pgwho_* de outro projeto compose (instalação feita antes do `name:` no
#   compose, ou em outra pasta): o compose recusaria criar o container com o
#   mesmo nome ("already in use").
# O banco recebe tempo para o checkpoint de desligamento (o padrão do docker
# stop, 10 s, mata o postgres no meio e obriga a recuperação de crash no boot).
DB_STOP_TIMEOUT="${PGWHO_DB_STOP_TIMEOUT:-120}"
DB_VOLUME="${DATA_VOLUME_NAME:-pgwho_timescaledb_data}"

compose_project_name() {
  local p="${COMPOSE_PROJECT_NAME:-}"
  [[ -n "$p" ]] || p=$(sed -n 's/^name:[[:space:]]*//p' "$COMPOSE_FILE" 2>/dev/null | head -1 | tr -d "\"' \r")
  [[ -n "$p" ]] || p=$(basename "$(pwd)")
  echo "$p"
}

stop_and_remove() {  # stop_and_remove <container> — só se existir
  local c="$1" t=10
  docker inspect "$c" >/dev/null 2>&1 || return 0
  [[ "$c" == *_db ]] && t="$DB_STOP_TIMEOUT"
  docker stop -t "$t" "$c" >/dev/null 2>&1 || true
  docker rm "$c" >/dev/null 2>&1 || true
  # Um banco antigo que continuasse de pé no mesmo volume ao lado do novo
  # (postmasters em namespaces diferentes não se enxergam) corromperia os dados.
  if docker inspect "$c" >/dev/null 2>&1; then
    error "Não foi possível remover o container $c — parando a atualização antes de subir o banco novo."
    exit 1
  fi
}

# Volume de dados montado num container de banco (vazio se não achar).
db_volume_of() {
  docker inspect --format '{{range .Mounts}}{{if or (eq .Destination "/var/lib/postgresql") (eq .Destination "/var/lib/postgresql/data")}}{{.Name}}{{end}}{{end}}' "$1" 2>/dev/null || true
}

remove_foreign_containers() {  # remove_foreign_containers <container>...
  local project c owner vol
  project=$(compose_project_name)
  for c in "$@"; do
    owner=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null) || continue
    [[ "$owner" != "$project" ]] || continue
    if [[ "$c" == *_db ]]; then
      # Recriado pelo compose, o banco monta $DB_VOLUME. Se o container antigo
      # usa outro volume, o banco novo nasceria vazio (initdb) e a atualização
      # pareceria perda total — os dados estão no volume antigo.
      vol=$(db_volume_of "$c")
      if [[ -n "$vol" && "$vol" != "$DB_VOLUME" ]]; then
        error "O banco atual ($c) usa o volume '$vol', mas o compose montaria '$DB_VOLUME'."
        error "Recriar agora subiria um banco vazio. Nada foi parado: a versão atual continua no ar."
        error "Defina DATA_VOLUME_NAME=$vol no .env e rode a atualização de novo."
        exit 1
      fi
    fi
    warn "Container $c pertence a outro projeto compose ('${owner}', esperado '${project}') — removendo para recriar."
    stop_and_remove "$c"
  done
}

# O compose vai recriar o banco? (imagem ou configuração do serviço mudou).
# Na dúvida responde que sim — o CHECKPOINT abaixo é inofensivo.
db_will_be_recreated() {
  local cur_img new_ref new_img cur_hash new_hash
  docker inspect pgwho_db >/dev/null 2>&1 || return 1   # não existe: será criado, nada a parar
  cur_hash=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' pgwho_db 2>/dev/null || true)
  new_hash=$(docker compose -f "$COMPOSE_FILE" config --hash timescaledb 2>/dev/null | awk '{print $2}' || true)
  [[ -n "$cur_hash" && -n "$new_hash" && "$cur_hash" == "$new_hash" ]] || return 0
  cur_img=$(docker inspect --format '{{.Image}}' pgwho_db 2>/dev/null || true)
  new_ref=$(docker compose -f "$COMPOSE_FILE" config --images timescaledb 2>/dev/null | head -1 || true)
  new_img=$(docker image inspect --format '{{.Id}}' "$new_ref" 2>/dev/null || true)
  [[ -n "$cur_img" && -n "$new_img" && "$cur_img" == "$new_img" ]] || return 0
  return 1
}

info "Removendo containers legados (pgwatch_*), se existirem..."
for c in pgwatch_backend pgwatch_watchshell pgwatch_db pgwatch_frontend; do
  stop_and_remove "$c"
done
remove_foreign_containers pgwho_backend pgwho_watchshell pgwho_db pgwho_frontend

if db_will_be_recreated; then
  # Com o banco ainda no ar, um CHECKPOINT grava o que está sujo agora: o
  # checkpoint de desligamento fica quase vazio e cabe folgado no tempo de
  # parada. Se o psql morrer, o checkpoint segue no checkpointer, sem lock.
  info "O banco interno vai ser recriado (imagem ou configuração nova) — CHECKPOINT antes de parar..."
  docker exec pgwho_db psql -q -U "${DB_USER:-pgwho}" -d "${DB_NAME:-pgwho}" -c CHECKPOINT >/dev/null 2>&1 \
    || warn "CHECKPOINT prévio não rodou — o banco faz o checkpoint ao desligar."
else
  info "Banco interno sem mudança de imagem nem de configuração — continua no ar."
fi

compose_up_db_backend() {
  # --timeout: vale para parar os containers ANTIGOS na recriação (sem ele o
  # compose usa o stop_grace_period gravado no container antigo — 10 s em
  # instalações de antes desse campo).
  docker compose -f "$COMPOSE_FILE" up -d --timeout "$DB_STOP_TIMEOUT" timescaledb backend
}

info "Subindo banco e backend com as novas imagens (o compose só recria o que mudou)..."
# depends_on: timescaledb: condition: service_healthy garante a ordem correta.
# Se o banco ainda não ficou saudável (recuperação de crash longa), o compose
# desiste e o backend novo fica criado, mas parado: espera o banco e tenta de novo.
if ! compose_up_db_backend; then
  warn "O compose não conseguiu subir banco e backend. Últimas linhas do log do banco:"
  docker logs --tail 30 pgwho_db 2>&1 || true
  info "Aguardando o banco interno ficar saudável (até $(( ${PGWHO_DB_WAIT_TRIES:-200} * ${PGWHO_HEALTH_INTERVAL:-3} / 60 )) min)..."
  for i in $(seq 1 "${PGWHO_DB_WAIT_TRIES:-200}"); do
    st=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' pgwho_db 2>/dev/null || echo missing)
    [[ "$st" == "healthy" ]] && break
    (( i % 10 == 0 )) && echo "  banco: $st ($i/${PGWHO_DB_WAIT_TRIES:-200}) — $(docker logs --tail 1 pgwho_db 2>&1 | tail -1)"
    sleep "${PGWHO_HEALTH_INTERVAL:-3}"
  done
  if ! compose_up_db_backend; then
    error "Banco e backend não subiram. Últimas linhas do log do banco:"
    docker logs --tail 60 pgwho_db 2>&1 || true
    error "  docker compose -f $COMPOSE_FILE ps"
    exit 1
  fi
fi

# Espera o /health olhando o container: crash-loop (reinício ou saída) falha
# na hora; boot lento (DDL do lifespan em base grande, ALTER EXTENSION) tem
# até ~10 min. Só leitura — nada fica preso se o script morrer aqui.
info "Aguardando backend ficar saudável..."
BACKEND_OK=0
HEALTH_TRIES="${PGWHO_HEALTH_TRIES:-200}"
restarts0=$(docker inspect --format '{{.RestartCount}}' pgwho_backend 2>/dev/null || echo 0)
for i in $(seq 1 "$HEALTH_TRIES"); do
  sleep "${PGWHO_HEALTH_INTERVAL:-3}"
  if docker exec pgwho_backend curl -sf http://localhost:8000/health >/dev/null 2>&1; then
    info "Backend saudável."
    BACKEND_OK=1
    break
  fi
  read -r state restarts < <(docker inspect --format '{{.State.Status}} {{.RestartCount}}' pgwho_backend 2>/dev/null || echo "missing 0")
  if [[ "$state" == "exited" || "$state" == "dead" || "$state" == "missing" ]] || (( ${restarts:-0} > ${restarts0:-0} )); then
    error "O backend parou durante o boot (estado: $state, reinícios: ${restarts:-0})."
    break
  fi
  (( i % 10 == 0 )) && echo "  aguardando... ($i/$HEALTH_TRIES) — $(docker logs --tail 1 pgwho_backend 2>&1 | tail -1)"
done

if [[ "$BACKEND_OK" != "1" ]]; then
  error "O backend não respondeu em /health depois da atualização."
  error "Últimas linhas do log do backend:"
  docker logs --tail 60 pgwho_backend 2>&1 || true
  error "O frontend e o updater não foram trocados. Confira o log acima e o estado dos containers:"
  error "  docker compose -f $COMPOSE_FILE ps"
  exit 1
fi

info "Atualizando frontend..."
docker compose -f "$COMPOSE_FILE" up -d frontend

# WatchShell fica no profile 'tools': só é atualizado se estiver em uso.
if [[ -n "$(docker ps -q --filter name='^pgwho_watchshell$' 2>/dev/null || true)" ]]; then
  info "Atualizando WatchShell..."
  docker compose -f "$COMPOSE_FILE" --profile tools up -d watchshell
fi

info "Subindo demais serviços..."
# --no-recreate: não recria containers já em execução (ex: pgwho_updater que está rodando este script)
docker compose -f "$COMPOSE_FILE" up -d --no-recreate --remove-orphans

# ── Auto-recriação do updater ─────────────────────────────────────────────────
# O updater nunca recria a si mesmo acima (--no-recreate, de propósito: é este
# script rodando dentro dele). Isso significa que mudanças no próprio serviço
# `updater` do compose (nova imagem, novos mounts, novo healthcheck) nunca se
# aplicam sozinhas — historicamente exigiam um `docker compose up -d
# --force-recreate updater` manual depois de toda atualização normal.
#
# Se executado diretamente no terminal do host (! -f /.dockerenv), podemos
# recriar o updater diretamente. Se executado de dentro do sidecar updater,
# delegamos a um container auxiliar descartável usando HOST_DEPLOY_DIR.
if [[ ! -f "${PGWHO_DOCKERENV:-/.dockerenv}" ]]; then
  info "Recriando serviço updater no host..."
  docker rm -f pgwatch_updater 2>/dev/null || true
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps updater
elif [[ -z "${HOST_DEPLOY_DIR:-}" ]]; then
  warn "HOST_DEPLOY_DIR não definido — pulando auto-recriação do updater."
  warn "Instalações antigas (de antes desta variável existir) precisam de:"
  warn "  docker compose -f $COMPOSE_FILE up -d --force-recreate updater"
else
  info "Agendando recriação do updater (em container auxiliar separado)..."
  # O auxiliar usa a imagem do próprio pgwho-updater, que o pull acima já
  # trouxe e que tem docker + docker compose — nunca baixa nada (servidores
  # com firewall só liberam o ghcr.io, e o Docker Hub limita pulls).
  UPDATER_IMAGE=$(docker compose -f "$COMPOSE_FILE" config --images updater 2>/dev/null | head -1 || true)
  UPDATER_IMAGE="${UPDATER_IMAGE:-$REGISTRY/wislanmoraes/pgwho-updater:${IMAGE_TAG:-latest}}"
  # sleep 2 dá tempo do `docker run -d` retornar e este script terminar
  # (o updater manda o "done" e a UI já reporta sucesso) antes do updater
  # antigo ser efetivamente derrubado.
  docker run --rm -d --pull never \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HOST_DEPLOY_DIR:$HOST_DEPLOY_DIR" \
    -w "$HOST_DEPLOY_DIR" \
    --entrypoint sh \
    "$UPDATER_IMAGE" \
    -c "sleep 2 && docker rm -f pgwatch_updater 2>/dev/null || true; docker compose -f '$COMPOSE_FILE' up -d --force-recreate --no-deps updater" \
    >/dev/null
fi

# ── Limpeza de imagens antigas ────────────────────────────────────────────────

info "Removendo imagens não utilizadas para liberar espaço..."
docker image prune -f
# Imagens do nome antigo (pgwatchai-*) continuam com tag depois do rebrand e o
# prune acima não as remove. docker rmi recusa as que algum container ainda usa.
LEGACY_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '/pgwatchai-' || true)
if [[ -n "$LEGACY_IMAGES" ]]; then
  echo "$LEGACY_IMAGES" | xargs docker rmi >/dev/null 2>&1 || true
  info "Imagens antigas pgwatchai-* removidas."
fi

# ── Verificação final ─────────────────────────────────────────────────────────

echo ""
info "Status dos containers:"
docker compose -f "$COMPOSE_FILE" ps

echo ""
info "✅ Atualização concluída com sucesso!"
