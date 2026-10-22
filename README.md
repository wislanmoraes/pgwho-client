# pgwho — Instalação do Cliente

Monitoramento de PostgreSQL com inteligência artificial.

## Pré-requisitos

- Docker 24+ com Docker Compose plugin
- Porta **80** liberada para entrada
- Acesso à internet (saída 443) para pull das imagens
- Pelo menos **4 GB livres** em disco (as imagens novas são baixadas antes de trocar as antigas)
- **Chave de Ativação** pgwho (formato `TMA-XXXX-...`), enviada por e-mail ou disponível no Portal do Cliente

## Instalação

Execute em qualquer terminal com Docker instalado:

```bash
curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | bash
```

O instalador irá:
1. Verificar os pré-requisitos
2. Criar o diretório `~/pgwho`
3. Solicitar a Chave de Ativação, validá-la no servidor de licenças e obter o acesso às imagens
   (também aceita um token do GitHub `ghp_...` com o escopo `read:packages`)
4. Gerar senha do banco e chave de segurança automaticamente
5. Subir todos os containers

Ao final, a URL de acesso e o login padrão serão exibidos.

## Atualização

Quando uma nova versão estiver disponível, um badge verde aparecerá na interface.
Clique em **Atualizar agora** ou execute no servidor:

```bash
cd ~/pgwho && ./update.sh
```

A cada execução, o script realiza automaticamente:
1. **Auto-atualização do próprio script** — baixa a versão mais recente do `update.sh`
2. **Atualização do `docker-compose.client.yml`** — garante que novos serviços e configurações sejam aplicados
3. **Validação da licença** — renova o acesso às imagens; um acesso recusado não substitui o que já funciona
4. **Verificação de espaço em disco** — se houver menos de 4 GB livres, a atualização é interrompida
   antes de parar qualquer container, e a versão atual continua no ar
5. **Pull e restart das imagens Docker** — atualiza o backend, frontend e demais containers
6. **Limpeza** — remove as imagens antigas que nenhum container usa

O mínimo de espaço livre pode ser ajustado com a variável `PGWHO_MIN_FREE_GB` (por exemplo,
`PGWHO_MIN_FREE_GB=6 ./update.sh`).

Não é necessário baixar ou editar nenhum arquivo manualmente.

## Reinstalação limpa

Em atualizações que exijam apagar os dados históricos (ex: mudança de versão do PostgreSQL),
execute o instalador novamente — ele detectará a instalação existente e oferecerá a opção de reinstalar:

```bash
curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | bash
```

Escolha a opção **[2] Reinstalação limpa** no menu. Os dados de monitoramento serão apagados,
mas o arquivo `.env` (chave de ativação, senhas, porta) é preservado — não é necessário reconfigurar.

Para ambientes automatizados (sem prompt interativo):

```bash
PGWHO_FRESH=1 curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | bash
```

## Suporte

Em caso de dúvidas, entre em contato com o suporte técnico.
