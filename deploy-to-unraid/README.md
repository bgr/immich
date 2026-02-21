# Deploy Immich Fork to Unraid

Scripts for deploying this Immich fork to an Unraid machine that previously ran the
[ImageGenius single-container Immich image](https://github.com/imagegenius/docker-immich).

The script builds a custom ImageGenius-compatible image with our code changes and deploys
it via Docker Compose Manager so it integrates with Unraid's web UI. The original container
is stopped but not deleted, allowing easy rollback.

## How it works

The [ImageGenius image](https://github.com/imagegenius/docker-immich) uses s6-overlay
to run 3 processes in one container:

1. **API server** — `node dist/main` with `IMMICH_WORKERS_INCLUDE=api` (port 8080)
2. **Microservices** — `node dist/main` with `IMMICH_WORKERS_INCLUDE=microservices`
3. **Machine learning** — `python3 -m immich_ml` (port 3003)

The script clones the ImageGenius repo, patches their Dockerfile to `COPY` our source
instead of downloading from GitHub, and builds a drop-in replacement image. It expects
the Unraid machine to also have separate Postgres and Redis containers on the same
Docker network.

Volume mounts (same as the original ImageGenius container):

| Container Path | Purpose |
|---------------|---------|
| `/config` | ML model cache |
| `/photos` | Main media library |
| `/photos/thumbs` | Thumbnails (can be on a separate share) |
| `/import` | External library import |
| `/libraries` | Libraries (Docker volume) |

## Prerequisites

- SSH access to your Unraid machine (key-based, no password prompts)
- Docker installed on your local machine (for building the image)
- Docker Compose Manager plugin installed on Unraid
- The Unraid machine currently runs `ghcr.io/imagegenius/immich`

## Usage

**First-time setup** for each Unraid machine (discovers config, creates compose project):

```bash
./deploy.sh init unrd1       # creates .env.unrd1
./deploy.sh init tower       # creates .env.tower
```

**Build** the Docker image (once, from current source):

```bash
./deploy.sh build
```

**Push** the image to Unraid and restart the container:

```bash
./deploy.sh push unrd1       # push to a specific host
./deploy.sh push             # push to all configured hosts
```

All commands walk you through each step and ask for confirmation. Pass `--yes` to skip
confirmations (useful when run by automation or Claude Code).

## What init does

1. Reads config from the running ImageGenius container and generates `.env.<name>`
2. Clones the ImageGenius docker repo (for the s6-overlay service scripts)
3. Backs up the database on Unraid
4. Creates a Docker Compose Manager project on Unraid
5. Stops the old container

Then tells you to run `build` and `push`.

## What build does

Builds the Docker image locally. This is independent of any host — you only need
to build once, then push to as many machines as you want.

## What push does

1. Saves the image to a compressed archive (reused across hosts)
2. Transfers it to the Unraid machine via SCP
3. Loads the image and restarts the container

## Rollback

Stop the fork container and restart the original:

```bash
ssh YOUR_UNRAID_HOST
docker stop immich-fork
docker start immich    # the original ImageGenius container
```

The migration added by our fork (AddPartnerAccessLevel) only adds a column with a default
value. Stock Immich ignores it, so no migration rollback is needed.

## Troubleshooting

### Installing Docker on WSL2

Install Docker Engine (not Docker Desktop):

```bash
# Add Docker's official GPG key and repo (see https://docs.docker.com/engine/install/)
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
```

You don't need `docker-compose-plugin` locally — docker compose only runs on the
Unraid machine.

### Permission denied on Docker socket

If `docker info` shows "permission denied while trying to connect to the Docker daemon
socket", your user isn't in the `docker` group:

```bash
sudo usermod -aG docker $USER
```

Then start a new shell (close and reopen your terminal, or `newgrp docker`).

### Starting Docker on WSL2 without systemd

WSL2 doesn't use systemd by default. `sudo systemctl start docker` won't work.
Use the SysV init script instead:

```bash
sudo service docker start
```

If that doesn't work, start the daemon directly:

```bash
sudo dockerd > /tmp/dockerd.log 2>&1 &
```

### Docker fails with iptables/addrtype errors on WSL2

If `dockerd` crashes with an error like:

```
failed to start daemon: Error initializing network controller:
  failed to append jump rules ... Couldn't load match `addrtype': No such file or directory
```

The default `nf_tables` iptables backend doesn't work on some WSL2 kernels.
Switch to the legacy backend:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

Make sure `/etc/docker/daemon.json` is empty or doesn't have `"iptables": false`
(that would disable networking for builds):

```bash
sudo mkdir -p /etc/docker
echo '{}' | sudo tee /etc/docker/daemon.json
```

Then restart Docker:

```bash
sudo service docker restart
```

Verify it's running:

```bash
docker info
```
