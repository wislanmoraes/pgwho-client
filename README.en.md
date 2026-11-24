<p align="center">
  <img src="docs/assets/logo.png" width="200" alt="pgwho — PostgreSQL monitoring platform">
</p>

<h3 align="center">PostgreSQL monitoring that points to the query, the session and the index — not just the chart.</h3>

<p align="center">
  Installed on your own server with one command. History stays in pgwho's own database;
  AI is optional and uses the provider you choose.<br>
  Free Personal edition, with sign-up · Pro and Enterprise for teams.
</p>

<p align="center">
  <a href="https://pgwho.com">Website</a> ·
  <a href="https://pgwho.com/#planos">Plans</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#security-and-what-pgwho-touches">Security</a> ·
  <a href="#support">Support</a>
</p>

<p align="center">
  <a href="https://github.com/wislanmoraes/pgwho-client/tags"><img alt="version" src="https://img.shields.io/github/v/tag/wislanmoraes/pgwho-client?label=version&sort=semver"></a>
  <img alt="self-hosted with Docker" src="https://img.shields.io/badge/self--hosted-Docker-2496ED">
</p>

<p align="center"><a href="README.md">Português</a> · <b>English</b></p>

> The pgwho interface is in Brazilian Portuguese.

---

## What you find out

| | |
|---|---|
| **Instance view**<br>Whether the instance is healthy right now: connections, cache, replication and lag, WAL, XID age and the xmin horizon, with a timeline of what changed. | **Sessions and locks**<br>Who is blocking whom, the whole blocking chain and its history, to answer "what locked up at 3 a.m.". |
| **Query Insights**<br>Which queries spend the most time and I/O in the window, and what they wait on, from `pg_stat_statements` and session sampling every 5 s. | **Emergency recorder**<br>What happened during a spike when not even the monitoring could connect: sampling runs inside the database, with `pg_cron`. |
| **Index Advisor**<br>The missing index, tested with `hypopg` before you create it; the one never used; the redundant one. | **Diagnostics and alerts**<br>Bloat, late autovacuum and unmaintained tables, with alerts when they open and when they resolve: e-mail, Telegram, Google Chat or webhook. |
| **Log Insights and plans**<br>The real plan of the slow query, captured by `auto_explain`, in a navigable tree. | **AI investigation**<br>Ask in plain language. The AI reads metrics and catalog only, with guardrails enforced outside the prompt, on the provider you choose: Anthropic, OpenAI, Gemini or compatible. |

Also: schema changes, Setup Check (tells you what is missing and hands you the command), a `psql` terminal in the browser and the health of pgwho's own server.
What each edition includes: [pgwho.com/#planos](https://pgwho.com/#planos).

## Installation

```bash
mkdir -p ~/pgwho && cd ~/pgwho
curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | bash
```

1. The installer checks Docker and the server, and asks only three things: a domain (optional, for HTTPS with an automatic certificate), the panel port and, if you want, an AI key.
2. At the end it shows the address and the **initial admin password**. Write it down: it is shown only there, and the first login asks for a new one.
3. Activate the license in **Configurações › Licença** with the `PGW-...` code or the document from the Customer Portal. The Personal edition is free: sign up at [pgwho.com](https://pgwho.com).

<details>
<summary>Prefer to read the script first?</summary>

```bash
curl -fsSLO https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh
less install.sh
bash install.sh
```
</details>

## First steps

1. In **Gerenciar instâncias**, register the PostgreSQL instance with a user that has the `pg_monitor` role.
2. Open **Setup Check**: it shows what is missing (`pg_stat_statements`, `auto_explain`, permissions) and hands you the command.
3. In about a minute, the instance view has data.

<details>
<summary>PostgreSQL on the same server as pgwho</summary>

Register the instance with host **`host.docker.internal`**. Do not use `localhost` (inside the container it is pgwho itself) nor the IP of pgwho's Docker network, which changes if the network is recreated.

On PostgreSQL:

- `listen_addresses` must include the IP of the Docker bridge on the host (`ip -4 addr show docker0`). The simplest is `'*'`, keeping port 5432 closed to the internet in the firewall. Changing it requires a PostgreSQL restart.
- `pg_hba.conf` must allow the Docker networks for the monitoring user:
  `host  all  monitor  <Docker networks range>  scram-sha-256`
  The range of pgwho's network shows with:

  ```bash
  docker network inspect $(docker inspect pgwho_backend --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}') --format '{{.Name}}: {{(index .IPAM.Config 0).Subnet}}'
  ```

  If the network is recreated, the range may change. To not depend on it, allow the whole range Docker reserves for its networks.
</details>

## Requirements

| | |
|---|---|
| System | Linux x86_64 (amd64) with Docker and the Compose plugin (`docker compose`). Also runs on Docker Desktop and WSL. |
| Recommended server | **6 CPUs, 12 GB** up to 5 instances · 8 CPUs, 24 GB up to 15 · 12 CPUs, 40 GB above that |
| Disk | At least **4 GB free** to update (new images are downloaded before the old ones are replaced) |
| Network | Outbound 443. Inbound on the panel port or, with a domain, ports 80 and 443 |
| Root mount | Linux with systemd. Without systemd, run `mount --make-rshared /` before installing and at boot. The installer checks it and stops before changing anything |

## Updating

When a new version is out, the interface shows a notice. Click **Atualizar agora** or run on the server:

```bash
cd ~/pgwho && ./update.sh
```

The update:

- downloads the latest version of the script itself and of `docker-compose.client.yml`;
- checks free disk space **before** stopping any container (tune with `PGWHO_MIN_FREE_GB`, e.g. `PGWHO_MIN_FREE_GB=6 ./update.sh`);
- swaps the images and restarts the panel only after the backend answers;
- removes old images no container uses.

From the interface you can also roll back to a previous version from the update history.

<details>
<summary>Clean reinstall (erases the monitoring history)</summary>

Run the installer again in the same folder and choose **[2] Reinstalação limpa**. The `.env` is kept, with passwords and keys, so there is nothing to reconfigure. Without a prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/wislanmoraes/pgwho-client/main/install.sh | PGWHO_FRESH=1 bash
```
</details>

## Security and what pgwho touches

- **Exposed:** only the panel. The internal database and the API stay on Docker's internal network.
- **HTTPS:** with a domain, the installer sets up HTTPS with an automatic certificate (Let's Encrypt). Without one, on a server with a public IP, it warns that the panel would be unencrypted.
- **Instance passwords:** stored encrypted with `PGWHO_ENCRYPTION_KEY`, generated in `.env`. **Back up `.env` together with the database backup**: without the key, a restored database cannot open the passwords.
- **On monitored instances:** diagnostic scripts run in read-only sessions (`default_transaction_read_only`) with `lock_timeout`, so they never queue the application behind a lock.
- **On pgwho's server:** the backend reads `/proc`, `/sys` and `/` read-only (server health screen) and uses the Docker socket (terminal and container health). The update service uses the socket too, to swap images from the interface.
- **Outbound traffic:** image downloads from `ghcr.io`, license checks at `pgwho.com` (offline activation exists) and the AI provider, if you configure one.

## Support

- Customer Portal: [pgwho.com/portal](https://pgwho.com/portal)
- Website, plans and terms: [pgwho.com](https://pgwho.com)

pgwho is commercial software; the Personal edition is free with sign-up. This repository only holds the installation and update files.
