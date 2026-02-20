#!/usr/bin/env python3
"""Patch the ImageGenius Dockerfile to use local source instead of downloading from GitHub.

Changes made:
  1. Adds 'COPY immich-source/ /tmp/immich/' before the main RUN command
  2. Removes the block that detects the latest version, downloads the tarball,
     and extracts it (the curl + tar commands)

Usage: python3 patch-dockerfile.py <path-to-Dockerfile>
"""

import re
import sys


def patch(content: str) -> str:
    # 1. Replace the "download immich" echo with a COPY instruction + a new echo.
    #    The original starts the RUN with:
    #      RUN \
    #        echo "**** download immich ****" && \
    #    We insert COPY before the RUN and change the echo text.
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

    # 2. Remove the download block:
    #      if [ -z ${IMMICH_VERSION} ]; then \
    #        IMMICH_VERSION=$(curl ...); \
    #      fi && \
    #      curl -o /tmp/immich.tar.gz ... && \
    #      tar xf /tmp/immich.tar.gz ... --strip-components=1 && \
    #
    #    This regex matches from "if [ -z ${IMMICH_VERSION}" through the line
    #    ending with "--strip-components=1 && \"
    pattern = (
        r'  if \[ -z \$\{IMMICH_VERSION\} \].*?--strip-components=1 && \\\n'
    )
    result, count = re.subn(pattern, '', content, count=1, flags=re.DOTALL)
    if count == 0:
        print("ERROR: Could not find the IMMICH_VERSION/curl/tar block to remove.", file=sys.stderr)
        print("The ImageGenius Dockerfile format may have changed.", file=sys.stderr)
        sys.exit(1)
    content = result

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

    print("Dockerfile patched successfully.")


if __name__ == '__main__':
    main()
