<p align="center">
  <img src="docs/assets/logo.png" width="200" alt="pgwho — plataforma de monitoramento de PostgreSQL">
</p>

<h3 align="center">Monitoramento de PostgreSQL que aponta a consulta, a sessão e o índice — não só o gráfico.</h3>

<p align="center">
  Instalado no seu servidor com um comando. O histórico fica no banco do próprio pgwho;
  a IA é opcional e usa o provedor que você escolher.<br>
  Edição Pessoal grátis, com cadastro · Pro e Enterprise para equipes.
</p>

<p align="center">
  <a href="https://pgwho.com">Site</a> ·
  <a href="https://pgwho.com/#planos">Planos</a> ·
  <a href="#instalação">Instalação</a> ·
  <a href="#segurança-e-o-que-o-pgwho-acessa">Segurança</a> ·
  <a href="#suporte">Suporte</a>
</p>

<p align="center">
  <a href="https://github.com/wislanmoraes/pgwho-client/tags"><img alt="versão" src="https://img.shields.io/github/v/tag/wislanmoraes/pgwho-client?label=vers%C3%A3o&sort=semver"></a>
  <img alt="self-hosted com Docker" src="https://img.shields.io/badge/self--hosted-Docker-2496ED">
</p>

<p align="center"><b>Português</b> · <a href="README.en.md">English</a></p>

---

## O que você descobre

| | |
|---|---|
| **Visão da Instância**<br>Se a instância está saudável agora: conexões, cache, replicação e lag, WAL, idade de XID e horizonte do xmin, com a linha do tempo do que mudou. | **Sessões e locks**<br>Quem está bloqueando quem, a cadeia inteira de bloqueio e o histórico, para responder "o que travou às 3h". |
| **Query Insights**<br>Quais consultas consomem mais tempo e I/O no intervalo, e em que esperam, pelo `pg_stat_statements` e pela amostragem das sessões a cada 5 s. | **Gravador de Emergência**<br>O que aconteceu durante um pico em que nem o monitoramento conseguia conectar: a amostragem roda dentro do banco, com `pg_cron`. |
| **Index Advisor**<br>O índice que falta, testado com `hypopg` antes de criar; o que nunca é usado; o que é redundante. | **Diagnóstico e alertas**<br>Bloat, autovacuum atrasado e tabelas sem manutenção, com alertas que avisam quando abrem e quando resolvem: e-mail, Telegram, Google Chat ou webhook. |
| **Log Insights e planos**<br>O plano real da consulta lenta, capturado pelo `auto_explain`, numa árvore navegável. | **Investigação com IA**<br>Pergunte em português. A IA consulta métricas e catálogo só para leitura, com travas aplicadas fora do prompt, no provedor que você escolher: Anthropic, OpenAI, Gemini ou compatível. |

Também: mudanças de schema, Setup Check (diz o que falta configurar e entrega o comando pronto), terminal `psql` no navegador e a saúde do próprio servidor do pgwho.
O que cada edição inclui: [pgwho.com/#planos](https://pgwho.com/#planos).

## Instalação

```bash
mkdir -p ~/pgwho && cd ~/pgwho
curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | bash
```

1. O instalador confere o Docker e o servidor, e pergunta só três coisas: um domínio (opcional, para HTTPS com certificado automático), a porta do painel e, se quiser, uma chave de IA.
2. No final, ele mostra o endereço e a **senha inicial do admin**. Anote: ela aparece só ali, e o primeiro acesso pede uma senha nova.
3. Ative a licença em **Configurações › Licença**, com o código `PGW-...` ou o documento recebido no Portal do Cliente. A edição Pessoal é grátis: o cadastro é em [pgwho.com](https://pgwho.com).

<details>
<summary>Prefere ler o script antes de rodar?</summary>

```bash
curl -fsSLO https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh
less install.sh
bash install.sh
```
</details>

## Primeiros passos

1. Em **Gerenciar instâncias**, cadastre o PostgreSQL com um usuário que tenha o papel `pg_monitor`.
2. Abra o **Setup Check**: ele mostra o que falta (`pg_stat_statements`, `auto_explain`, permissões) e entrega o comando pronto.
3. Em cerca de um minuto, a Visão da Instância já tem dados.

<details>
<summary>PostgreSQL no mesmo servidor do pgwho</summary>

Cadastre a instância com o host **`host.docker.internal`**. Não use `localhost`, que dentro do container é o próprio pgwho, nem o IP da rede Docker do pgwho, que muda se a rede for recriada.

No PostgreSQL:

- `listen_addresses` precisa incluir o IP da ponte do Docker no host (`ip -4 addr show docker0`). O mais simples é `'*'`, mantendo a porta 5432 fechada para a internet no firewall. Mudar esse parâmetro exige reiniciar o PostgreSQL.
- O `pg_hba.conf` precisa liberar as redes Docker para o usuário de monitoramento:
  `host  all  monitor  <faixa das redes Docker>  scram-sha-256`
  A faixa da rede do pgwho aparece com:

  ```bash
  docker network inspect $(docker inspect pgwho_backend --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}') --format '{{.Name}}: {{(index .IPAM.Config 0).Subnet}}'
  ```

  Se a rede for recriada, a faixa pode mudar. Para não depender dela, libere a faixa inteira que o Docker reserva para as redes dele.
</details>

## Requisitos

| | |
|---|---|
| Sistema | Linux x86_64 (amd64) com Docker e o plugin Compose (`docker compose`). Também roda no Docker Desktop e no WSL. |
| Servidor recomendado | **6 CPUs e 12 GB** até 5 instâncias · 8 CPUs e 24 GB até 15 · 12 CPUs e 40 GB acima disso |
| Disco | Pelo menos **4 GB livres** para atualizar (as imagens novas são baixadas antes de trocar as antigas) |
| Rede | Saída na porta 443. Entrada na porta do painel ou, com domínio, nas portas 80 e 443 |
| Montagem da raiz | Linux com systemd. Sem systemd, rode `mount --make-rshared /` antes de instalar e no boot do servidor. O instalador confere isso e para antes de mudar qualquer coisa |

## Atualização

Quando houver uma versão nova, a interface mostra um aviso. Clique em **Atualizar agora** ou rode no servidor:

```bash
cd ~/pgwho && ./update.sh
```

A atualização:

- baixa a versão mais recente do próprio script e do `docker-compose.client.yml`;
- confere o espaço em disco **antes** de parar qualquer container (ajuste com `PGWHO_MIN_FREE_GB`, por exemplo `PGWHO_MIN_FREE_GB=6 ./update.sh`);
- troca as imagens e só reinicia o painel depois que o backend responde;
- remove as imagens antigas que nenhum container usa.

Pela interface, também dá para voltar a uma versão anterior pelo histórico de atualizações.

<details>
<summary>Reinstalação limpa (apaga o histórico de monitoramento)</summary>

Rode o instalador de novo na mesma pasta e escolha **[2] Reinstalação limpa**. O `.env` é preservado, com as senhas e as chaves, e não é preciso reconfigurar. Sem prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | PGWHO_FRESH=1 bash
```
</details>

## Segurança e o que o pgwho acessa

- **Exposto:** só o painel. O banco interno e a API ficam na rede interna do Docker.
- **HTTPS:** com um domínio, o instalador configura HTTPS com certificado automático (Let's Encrypt). Sem domínio, num servidor com IP público, ele avisa que o painel ficaria sem criptografia.
- **Senhas das instâncias:** são guardadas cifradas com a `PGWHO_ENCRYPTION_KEY`, gerada no `.env`. **Faça backup do `.env` junto com o backup do banco**: sem a chave, um banco restaurado não abre as senhas.
- **Nas instâncias monitoradas:** os scripts de diagnóstico rodam em sessões somente leitura (`default_transaction_read_only`) e com `lock_timeout`, para nunca enfileirar a aplicação atrás de um lock.
- **No servidor do pgwho:** o backend lê `/proc`, `/sys` e `/` em modo somente leitura (tela de saúde do servidor) e usa o socket do Docker (terminal e saúde dos containers). O serviço de atualização também usa o socket, para trocar as imagens pela interface.
- **Saída de rede:** download das imagens em `ghcr.io`, verificação da licença em `pgwho.com` (existe ativação offline) e o provedor de IA, se você configurar um.

## Suporte

- Portal do Cliente: [pgwho.com/portal](https://pgwho.com/portal)
- Site, planos e termos: [pgwho.com](https://pgwho.com)

O pgwho é software comercial; a edição Pessoal é gratuita, com cadastro. Este repositório traz apenas os arquivos de instalação e atualização.
