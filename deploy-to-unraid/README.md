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
4. Previews the Docker Compose Manager project that will be created on the first push
5. Stops the old container

Then tells you to run `build` and `push`.

## What build does

Builds the Docker image locally. Before building, it shows when the ImageGenius repo was
last fetched and offers to pull the latest version. This is independent of any host — you
only need to build once, then push to as many machines as you want.

## What push does

1. Pre-flight checks: verifies disk space on each host and offers to prune orphaned
   Docker images (old versions left behind by previous deploys) to free space
2. Saves the image to a compressed archive (reused across hosts)
3. Transfers it to the Unraid machine via SCP and loads it
4. Creates or updates the Docker Compose Manager project on the remote host
5. Starts the container and verifies it's running
6. Prunes old images now that the new container is confirmed running

## Other scripts

**`recreate-merge-branch.sh`** — Rebuilds the `fork-deploy` branch by resetting it to
`main` and merging all feature branches in order. Used to prepare a combined branch for
building.

## Rollback

Stop the fork container and restart the original:

```bash
ssh YOUR_UNRAID_HOST
docker stop immich-fork
docker start immich    # the original ImageGenius container
```

The migration added by our fork (AddPartnerAccessLevel) only adds a column with a default
value. Stock Immich ignores it, so no migration rollback is needed.

## ImageGenius version compatibility

The build uses two things from ImageGenius: their
[docker-immich](https://github.com/imagegenius/docker-immich) repo (Dockerfile and s6
service scripts) and their base image (`ghcr.io/imagegenius/baseimage-immich:latest`).
Neither is pinned to a specific version.

This is intentional. ImageGenius doesn't tag their commits by Immich version, so there's
no easy way to look up "which ImageGenius commit matches Immich v2.x.y". Pinning would
create a maintenance burden with no clear way to update the pin when rebasing our branches
onto a newer Immich `main`.

Instead, the script relies on two things:

1. **`patch-dockerfile.py` fails loudly if the Dockerfile format changed.** It looks for
   specific string patterns and exits with a clear error if they're missing, so a
   format mismatch won't silently produce a broken image.

2. **The ImageGenius repo is cloned once and not auto-updated.** Running `init` on a new
   host clones the repo, but running `init` again on an already-configured host skips the
   clone. This means the ImageGenius code stays at whatever version you last pulled, and
   won't drift out of sync with your fork behind your back.

**When rebasing onto a newer Immich `main`**, update the ImageGenius repo to match:

```bash
git -C deploy-to-unraid/imagegenius-docker pull
```

Then rebuild. If the Dockerfile format changed, `patch-dockerfile.py` will tell you what
broke.

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
