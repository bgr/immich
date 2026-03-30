#!/usr/bin/env python3
"""Patch the ImageGenius Dockerfile for local source and faster rebuilds.

Changes made:
  1. Replaces the GitHub tarball download with COPY of local source
  2. Pins Node.js version if the .nvmrc version isn't on NodeSource yet
  3. Uses bundled libvips instead of the base image's system libvips
     (avoids pkg-config conflicts from the base image's resolute-repo libs)
  4. Splits the monolithic RUN into two layers:
     - Layer 1 (cached): apt repos, apt install, pnpm setup — only reruns
       if the base image or Node version changes
     - Layer 2 (rebuilds on code change): plugins, server, web, CLI, ML builds
  This means code-only changes skip the slow dependency installation step.

Usage: python3 patch-dockerfile.py <path-to-Dockerfile>
"""

import re
import sys


def patch(content: str) -> str:
    # -----------------------------------------------------------------------
    # 1. Replace the "download immich" echo with COPY of local source
    # -----------------------------------------------------------------------
    old = (
        'RUN \\\n'
        '  echo "**** download immich ****" && \\\n'
    )
    new = (
        'COPY immich-source/ /tmp/immich/\n'
        '\n'
        'RUN \\\n'
        '  echo "**** using local source ****" && \\\n'
    )
    if old not in content:
        print("ERROR: Could not find the 'download immich' block to replace.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new, 1)

    # -----------------------------------------------------------------------
    # 2. Remove the download block (IMMICH_VERSION detection + curl + tar)
    # -----------------------------------------------------------------------
    pattern = (
        r'  if \[ -z \$\{IMMICH_VERSION\} \].*?--strip-components=1 && \\\n'
    )
    result, count = re.subn(pattern, '', content, count=1, flags=re.DOTALL)
    if count == 0:
        print("ERROR: Could not find the IMMICH_VERSION/curl/tar block to remove.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)
    content = result

    # -----------------------------------------------------------------------
    # 2b. Pin Node.js to latest available NodeSource version.
    #     The .nvmrc may specify a patch version that NodeSource doesn't have
    #     yet (e.g. 24.13.1 when only 24.13.0 is published).
    # -----------------------------------------------------------------------
    content = content.replace(
        '  if [ -z "${NODEJS_VERSION}" ]; then \\\n'
        '    NODEJS_VERSION="$(cat /tmp/immich/server/.nvmrc)" && \\\n'
        '    echo "**** detected node version ${NODEJS_VERSION} ****"; \\\n'
        '  fi && \\\n',
        '  NODEJS_VERSION="24.13.0" && \\\n'
        '  echo "**** using pinned node version ${NODEJS_VERSION} ****" && \\\n',
    )

    # -----------------------------------------------------------------------
    # 2c. Use bundled libvips instead of the system one.
    #     The base image compiles libvips from source against libraries from
    #     Ubuntu "resolute" (a newer release), then removes the resolute repo.
    #     This leaves the system vips linked against libs whose -dev packages
    #     can't be installed, so sharp can't compile against it.
    #     Fix: use sharp's bundled libvips for everything.
    # -----------------------------------------------------------------------
    content = content.replace(
        'SHARP_FORCE_GLOBAL_LIBVIPS="true" \\\n',
        'SHARP_FORCE_GLOBAL_LIBVIPS="false" \\\n',
    )
    content = content.replace(
        'SHARP_FORCE_GLOBAL_LIBVIPS=true pnpm \\\n',
        'SHARP_IGNORE_GLOBAL_LIBVIPS=true pnpm \\\n',
    )
    # Drop --no-optional so the bundled sharp native bindings are kept
    content = content.replace(
        '    --no-optional \\\n'
        '    --force \\\n'
        '    deploy /app/immich/server',
        '    --force \\\n'
        '    deploy /app/immich/server',
    )

    # -----------------------------------------------------------------------
    # 2d. Remove librsvg2-dev from the install list.
    #     It was only needed for compiling sharp against the system libvips.
    #     With bundled vips (2c above), it's no longer needed, and it causes
    #     an apt conflict (pulls libwebp-dev 1.3.x vs held libwebp7 1.5.x).
    # -----------------------------------------------------------------------
    content = content.replace('    librsvg2-dev \\\n', '')

    # -----------------------------------------------------------------------
    # 3. Split the monolithic RUN into two: deps install vs code build.
    # -----------------------------------------------------------------------

    # Find the split point: the line with "setup plugins (mise)"
    split_marker = '  echo "**** setup plugins (mise) ****" && \\\n'
    if split_marker not in content:
        print("ERROR: Could not find the 'setup plugins' marker to split RUN.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)

    old_split = (
        '  corepack enable pnpm && \\\n'
        '  echo "**** setup plugins (mise) ****" && \\\n'
    )
    new_split = (
        '  corepack enable pnpm\n'
        '\n'
        '# --- Code build layer (rebuilds on source changes) ---\n'
        'RUN --mount=type=secret,id=github_token \\\n'
        '  if [ -f /run/secrets/github_token ]; then export GITHUB_TOKEN=$(cat /run/secrets/github_token); fi && \\\n'
        '  echo "**** setup plugins (mise) ****" && \\\n'
    )
    if old_split not in content:
        print("ERROR: Could not find the expected split point around 'corepack enable pnpm'.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old_split, new_split, 1)

    # -----------------------------------------------------------------------
    # 4. Move COPY immich-source/ to between the two RUN layers.
    # -----------------------------------------------------------------------

    content = content.replace(
        'COPY immich-source/ /tmp/immich/\n\n',
        'COPY immich-source/server/.nvmrc /tmp/immich/server/.nvmrc\n\n',
        1
    )

    content = content.replace(
        '# --- Code build layer (rebuilds on source changes) ---\n',
        'COPY immich-source/ /tmp/immich/\n'
        '\n'
        '# --- Code build layer (rebuilds on source changes) ---\n',
        1
    )

    return content


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <Dockerfile-path>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]

    with open(path, 'r') as f:
        content = f.read()

    content = patch(content)

    with open(path, 'w') as f:
        f.write(content)

    # Sanity checks
    if 'COPY immich-source/' not in content:
        print("ERROR: COPY instruction not found after patching.", file=sys.stderr)
        sys.exit(1)
    if 'github.com/immich-app/immich/archive' in content:
        print("ERROR: GitHub download URL still present after patching.", file=sys.stderr)
        sys.exit(1)
    if content.count('\nRUN ') < 2:
        print("ERROR: Expected at least 2 RUN instructions after splitting.", file=sys.stderr)
        sys.exit(1)

    print("Dockerfile patched successfully.")


if __name__ == '__main__':
    main()
