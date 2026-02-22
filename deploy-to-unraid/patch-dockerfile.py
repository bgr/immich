#!/usr/bin/env python3
"""Patch the ImageGenius Dockerfile for local source and faster rebuilds.

Changes made:
  1. Replaces the GitHub tarball download with COPY of local source
  2. Splits the monolithic RUN into two layers:
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
    # 3. Split the monolithic RUN into two: deps install vs code build.
    #
    #    We split right before "**** setup plugins (mise) ****" because
    #    everything before that is dependency installation (apt, node, pnpm)
    #    which only changes when the base image or Node version changes.
    #    Everything from plugins onward is building our code.
    #
    #    Original (single RUN):
    #      ... apt-get install ... && \
    #      echo "**** setup pnpm ****" && \
    #      npm install --global corepack@latest && \
    #      corepack enable pnpm && \
    #      echo "**** setup plugins (mise) ****" && \
    #      ...
    #
    #    After split:
    #      ... corepack enable pnpm
    #      # --- end of deps layer ---
    #
    #      RUN \
    #        echo "**** setup plugins (mise) ****" && \
    #      ...
    # -----------------------------------------------------------------------

    # Find the split point: the line with "setup plugins (mise)"
    split_marker = '  echo "**** setup plugins (mise) ****" && \\\n'
    if split_marker not in content:
        print("ERROR: Could not find the 'setup plugins' marker to split RUN.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)

    # The line before the split marker ends with "&& \" — we need to remove
    # that continuation to end the first RUN, then start a new RUN.
    # The line before is: "  corepack enable pnpm && \"
    old_split = (
        '  corepack enable pnpm && \\\n'
        '  echo "**** setup plugins (mise) ****" && \\\n'
    )
    new_split = (
        '  corepack enable pnpm\n'
        '\n'
        '# --- Code build layer (rebuilds on source changes) ---\n'
        'RUN \\\n'
        '  echo "**** setup plugins (mise) ****" && \\\n'
    )
    if old_split not in content:
        print("ERROR: Could not find the expected split point around 'corepack enable pnpm'.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old_split, new_split, 1)

    # -----------------------------------------------------------------------
    # 4. Move COPY immich-source/ to between the two RUN layers.
    #
    #    The COPY must come after deps install (so it doesn't invalidate
    #    that cache) and before the build RUN (which needs the source).
    # -----------------------------------------------------------------------

    # Replace the full COPY with just .nvmrc (needed by deps layer for Node
    # version detection). The full source COPY goes before the build layer.
    content = content.replace(
        'COPY immich-source/ /tmp/immich/\n\n',
        'COPY immich-source/server/.nvmrc /tmp/immich/server/.nvmrc\n\n',
        1
    )

    # Insert the full source COPY between the two RUN layers
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
    if content.count('RUN \\') < 2:
        print("ERROR: Expected at least 2 RUN instructions after splitting.", file=sys.stderr)
        sys.exit(1)

    print("Dockerfile patched successfully.")


if __name__ == '__main__':
    main()
