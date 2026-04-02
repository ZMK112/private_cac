ARG NODE_TAG=22-bookworm
FROM node:${NODE_TAG}

ENV DEBIAN_FRONTEND=noninteractive

ARG SINGBOX_VERSION=1.12.14
ARG DOCKER_CLI_VERSION=29.0.1
ARG DOCKER_CLI_API_VERSION=1.52
ARG BUILD_PROXY
ARG CAC_FAKE_USER=cherny
ARG CAC_FAKE_UID=1001
ARG CAC_FAKE_GID=1001

LABEL cac.docker_cli_version="${DOCKER_CLI_VERSION}" \
      cac.docker_cli_api_version="${DOCKER_CLI_API_VERSION}"

# System packages + uv + sing-box
# BUILD_PROXY: only used for curl (uv, sing-box, claude install).
# apt-get uses direct connection (Debian mirrors don't need proxy in CI).
# For local builds behind a SOCKS5 proxy, apt can reach mirrors via the
# host's network; only external downloads (GitHub, astral.sh) need the proxy.
RUN set -eux; \
    CURL="curl ${BUILD_PROXY:+-x $BUILD_PROXY}"; \
    export ALL_PROXY="${BUILD_PROXY:-}" all_proxy="${BUILD_PROXY:-}"; \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git gosu iproute2 \
      jq fd-find locales nftables procps python3 python3-venv docker.io \
      openssh-server openssl ripgrep sqlite3 sudo tree unzip util-linux uuid-runtime zip tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *\(en_US\|en_GB\|ja_JP\|ko_KR\|zh_CN\|zh_TW\|de_DE\|fr_FR\)\.UTF-8/\1.UTF-8/' /etc/locale.gen \
    && locale-gen \
    && corepack enable \
    && $CURL -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local sh \
    && ln -sf /usr/local/uv /usr/local/bin/uv \
    && ln -sf /usr/local/uvx /usr/local/bin/uvx \
    && ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in amd64) SB_ARCH=amd64; DOCKER_ARCH=x86_64;; arm64) SB_ARCH=arm64; DOCKER_ARCH=aarch64;; *) echo "unsupported: $ARCH" >&2; exit 1;; esac \
    && $CURL -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz" \
       | tar xzO "sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}/sing-box" > /usr/local/bin/sing-box \
    && chmod +x /usr/local/bin/sing-box \
    && $CURL -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
       | tar xzO docker/docker > /usr/local/bin/docker-real \
    && chmod +x /usr/local/bin/docker-real \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && /usr/local/bin/docker-real --version | grep -F "Docker version ${DOCKER_CLI_VERSION}" >/dev/null

RUN set -eux; \
    getent group "${CAC_FAKE_GID}" >/dev/null || groupadd -g "${CAC_FAKE_GID}" "${CAC_FAKE_USER}"; \
    id -u "${CAC_FAKE_USER}" >/dev/null 2>&1 || useradd -m -u "${CAC_FAKE_UID}" -g "${CAC_FAKE_GID}" -s /bin/bash "${CAC_FAKE_USER}"; \
    usermod -aG sudo "${CAC_FAKE_USER}"; \
    mkdir -p /home/"${CAC_FAKE_USER}"/.local/bin; \
    mkdir -p /run/sshd /etc/ssh/sshd_config.d; \
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${CAC_FAKE_USER}" > /etc/sudoers.d/90-cac-runtime-user; \
    chmod 0440 /etc/sudoers.d/90-cac-runtime-user; \
    printf '%s\n' \
      'Port 22' \
      'PermitRootLogin no' \
      'PasswordAuthentication yes' \
      'KbdInteractiveAuthentication no' \
      'ChallengeResponseAuthentication no' \
      'PubkeyAuthentication no' \
      "AllowUsers ${CAC_FAKE_USER}" \
      'UsePAM yes' \
      'X11Forwarding no' \
      'PrintMotd no' \
      > /etc/ssh/sshd_config.d/cac.conf

# Claude Code CLI
# install.sh internally uses curl — needs ALL_PROXY so inner downloads also go through proxy
RUN set -eux; \
    export ALL_PROXY="${BUILD_PROXY:-}" all_proxy="${BUILD_PROXY:-}"; \
    curl ${BUILD_PROXY:+-x "$BUILD_PROXY"} -fsSL https://claude.ai/install.sh | bash; \
    test -x /root/.local/bin/claude; \
    cp /root/.local/bin/claude /usr/local/bin/claude; \
    chmod +x /usr/local/bin/claude

# cac (Claude Anti-fingerprint Cloak) — build from source
COPY src/ /tmp/cac-build/src/
COPY build.sh /tmp/cac-build/
RUN cd /tmp/cac-build && bash build.sh \
    && cp cac /usr/local/bin/cac \
    && cp fingerprint-hook.js /usr/local/bin/fingerprint-hook.js \
    && cp relay.js /usr/local/bin/relay.js \
    && chmod +x /usr/local/bin/cac \
    && rm -rf /tmp/cac-build

ENV CAC_FAKE_USER="${CAC_FAKE_USER}" \
    CAC_FAKE_UID="${CAC_FAKE_UID}" \
    CAC_FAKE_GID="${CAC_FAKE_GID}" \
    CAC_FAKE_HOME="/home/${CAC_FAKE_USER}" \
    CAC_FAKE_SHELL="/bin/bash" \
    CAC_FAKE_OS_TYPE="Linux" \
    CAC_FAKE_OS_RELEASE="6.6.31-boris" \
    CAC_FAKE_OS_VERSION="Debian GNU/Linux 12" \
    CAC_FAKE_OS_PRETTY_NAME="Debian GNU/Linux 12 (bookworm)" \
    CAC_FAKE_DISTRO_ID="debian" \
    CAC_FAKE_DISTRO_VERSION="12" \
    CAC_FAKE_PROC_VERSION="Linux version 6.6.31-boris (builder@cherny) #1 SMP PREEMPT_DYNAMIC" \
    TZ=Asia/Tokyo \
    LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8 \
    LANGUAGE=ja_JP:ja \
    HOME="/home/${CAC_FAKE_USER}" \
    USER="${CAC_FAKE_USER}" \
    LOGNAME="${CAC_FAKE_USER}" \
    SHELL="/bin/bash" \
    TERM="xterm-256color" \
    PATH="/home/${CAC_FAKE_USER}/.local/bin:/root/.local/bin:${PATH}"

RUN printf 'export PATH="%s/.local/bin:$PATH"\n' "/home/${CAC_FAKE_USER}" >> /home/"${CAC_FAKE_USER}"/.bashrc \
    && echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc

# sing-box config engine
COPY docker/lib/ /opt/ccimage/ccimage/
ENV PYTHONPATH="/opt/ccimage"

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/cac-check /usr/local/bin/cac-check
COPY docker/docker-wrapper.sh /usr/local/bin/docker
COPY docker/templates /usr/local/share/cherny
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/cac-check /usr/local/bin/docker

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
