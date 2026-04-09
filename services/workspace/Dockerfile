FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG WORKSPACE_USER=developer
ARG WORKSPACE_UID=1000
ARG WORKSPACE_GID=1000
ARG WORKSPACE_SHELL=/bin/bash

# ── Mandatory tools (always installed) ──
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    vim \
    nano \
    unzip \
    zip \
    htop \
    net-tools \
    iputils-ping \
    openssh-server \
    ca-certificates \
    locales \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ── SSH server setup ──
RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && echo "AllowUsers ${WORKSPACE_USER}" >> /etc/ssh/sshd_config

# ── Locale ──
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# ── Dynamic user creation ──
RUN groupadd -g ${WORKSPACE_GID} ${WORKSPACE_USER} \
    && useradd -m -u ${WORKSPACE_UID} -g ${WORKSPACE_GID} -s ${WORKSPACE_SHELL} ${WORKSPACE_USER} \
    && echo "${WORKSPACE_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ── SSH directory for user ──
RUN mkdir -p /home/${WORKSPACE_USER}/.ssh \
    && chmod 700 /home/${WORKSPACE_USER}/.ssh \
    && chown ${WORKSPACE_USER}:${WORKSPACE_USER} /home/${WORKSPACE_USER}/.ssh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER ${WORKSPACE_USER}
WORKDIR /home/${WORKSPACE_USER}/workspace

# ── Git default config ──
RUN git config --global init.defaultBranch main \
    && git config --global core.autocrlf input

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]