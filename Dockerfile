# Build upstream Paperclip from a pinned ref.
#
# Upstream v2026.916.x requires Node >= 24.11 and its server build compiles a
# native Rust runner binary (packages/paperclip-runner) via
# `@paperclipai/server build` -> prepare:runner-vendor -> cargo build. So the
# build stage carries a pinned, checksum-verified rustup (mirrors the upstream
# paperclipai/paperclip Dockerfile); the compiler version itself comes from the
# repo's own packages/paperclip-runner/rust-toolchain.toml.
FROM node:24-bookworm AS paperclip-build
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gcc \
    libc6-dev \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) rustTarget="x86_64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_AMD64" ;; \
      arm64) rustTarget="aarch64-unknown-linux-gnu"; sha256="$RUSTUP_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustTarget}/rustup-init"; \
    echo "${sha256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none; \
    rm /tmp/rustup-init

ARG PAPERCLIP_REPO=https://github.com/paperclipai/paperclip.git
ARG PAPERCLIP_REF=v2026.916.1

WORKDIR /paperclip
RUN git clone --depth 1 --branch "${PAPERCLIP_REF}" "${PAPERCLIP_REPO}" .
# Install the runner's pinned compiler (rustup reads rust-toolchain.toml).
# Older refs without a runner package skip this and build JS-only.
RUN if [ -f packages/paperclip-runner/rust-toolchain.toml ]; then \
      (cd packages/paperclip-runner && rustup show); \
    fi
RUN pnpm install --frozen-lockfile
RUN pnpm --filter @paperclipai/ui build
RUN pnpm --filter @paperclipai/plugin-sdk build
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN pnpm --filter @paperclipai/server build
RUN test -f server/dist/index.js
# Rust build artifacts are vendored into server/dist; drop the intermediate
# target dir (GBs) before the copy into the runtime image.
RUN rm -rf packages/paperclip-runner/runner/target

# Runtime image (direct Paperclip server, no wrapper).
FROM node:24-bookworm
ENV NODE_ENV=production
ENV CLAUDE_CODE_BUBBLEWRAP=1
# Match upstream production image defaults (paperclipai/paperclip Dockerfile) so
# agent tooling, OpenCode, and config paths behave the same in containers.
ENV HOME=/paperclip \
    PAPERCLIP_INSTANCE_ID=default \
    PAPERCLIP_CONFIG=/paperclip/instances/default/config.json \
    OPENCODE_ALLOW_ALL_MODELS=true

# tini as PID 1 (upstream does the same): agent runs spawn git/claude/esbuild/sh
# descendants that outlive their leader; without an init they accumulate as
# zombies until the cgroup pid limit is hit and every fork() fails.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    python3 \
    python3-venv \
    ripgrep \
    tini \
    && rm -rf /var/lib/apt/lists/*
RUN corepack enable

WORKDIR /app
COPY --from=paperclip-build /paperclip /app

WORKDIR /wrapper
COPY package.json /wrapper/package.json
RUN npm install --omit=dev && npm cache clean --force
COPY src /wrapper/src
COPY scripts/entrypoint.sh /wrapper/entrypoint.sh
COPY scripts/bootstrap-ceo.mjs /wrapper/template/bootstrap-ceo.mjs
RUN chmod +x /wrapper/entrypoint.sh

# Optional local adapters/tools parity with upstream Dockerfile.
RUN npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai
RUN npm install --global --omit=dev tsx

# Hermes Agent for Paperclip's built-in hermes_local adapter, which forks the
# `hermes` CLI as a child process on this host — so it must be on PATH here.
# Pinned venv keeps it isolated from any system Python packages.
ARG HERMES_AGENT_VERSION=0.18.2
RUN python3 -m venv /opt/hermes \
    && /opt/hermes/bin/pip install --no-cache-dir "hermes-agent==${HERMES_AGENT_VERSION}" \
    && ln -s /opt/hermes/bin/hermes /usr/local/bin/hermes \
    && hermes --version
RUN mkdir -p /paperclip \
    && chown -R node:node /app /paperclip /wrapper

# Railway sets PORT at runtime and this process binds to it.
# Entrypoint runs as root (under tini), fixes /paperclip volume permissions,
# then execs as node.
EXPOSE 3100
ENTRYPOINT ["/usr/bin/tini", "--", "/wrapper/entrypoint.sh"]
CMD ["node", "/wrapper/src/server.js"]
