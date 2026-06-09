FROM node:20

ARG TZ
ENV TZ="$TZ"

RUN apt-get update && apt-get install -y --no-install-recommends \
  less git procps sudo fzf zsh man-db unzip gnupg2 gh \
  iptables ipset iproute2 dnsutils aggregate jq nano vim \
  bubblewrap socat pipx \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir /commandhistory && touch /commandhistory/.bash_history \
  && chown -R node /commandhistory

ENV DEVCONTAINER=true

RUN mkdir -p /workspace /home/node/.claude /etc/claude-code \
  && chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

USER node

ENV PATH=$PATH:/home/node/.local/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano

RUN curl -fsSL https://claude.ai/install.sh | bash

COPY --chown=root:root managed-settings.json /etc/claude-code/managed-settings.json
COPY init-firewall.sh /usr/local/bin/

USER root
RUN chmod +x /usr/local/bin/init-firewall.sh \
  && echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

RUN GITLEAKS_VERSION=$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/') \
  && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | tar -xz -C /usr/local/bin gitleaks

USER node
