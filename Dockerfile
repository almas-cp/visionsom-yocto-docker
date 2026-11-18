# =============================================================================
# Yocto Scarthgap Build Environment
# Target: VisionSOM-STM32MP1 + LoRaWAN + Azure IoT Edge
# Base:   Ubuntu 22.04 LTS (required by Yocto Scarthgap)
# =============================================================================
FROM ubuntu:22.04

LABEL maintainer="your-team@example.com"
LABEL description="Yocto Scarthgap build host for VisionSOM-STM32MP1"
LABEL yocto.release="scarthgap"
LABEL openstlinux.tag="openstlinux-6.6-yocto-scarthgap-mpu-v24.12.05"

# -----------------------------------------------------------------------------
# Prevent interactive prompts during package install
# -----------------------------------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# -----------------------------------------------------------------------------
# Install all packages required by Yocto Scarthgap (Ubuntu 22.04 list)
# https://docs.yoctoproject.org/scarthgap/ref-manual/system-requirements.html
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core build tools
    build-essential \
    gcc \
    g++ \
    make \
    cmake \
    # Source control
    git \
    git-lfs \
    curl \
    wget \
    # repo tool dependencies
    python3 \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    # BitBake / OE dependencies
    gawk \
    diffstat \
    unzip \
    texinfo \
    chrpath \
    socat \
    cpio \
    python3-pexpect \
    python3-git \
    python3-jinja2 \
    python3-subunit \
    xz-utils \
    debianutils \
    iputils-ping \
    # Image/filesystem tools
    zstd \
    liblz4-tool \
    file \
    libacl1 \
    # Display / SDL (for QEMU builds if needed)
    libsdl1.2-dev \
    xterm \
    # Mesa
    libegl1-mesa \
    mesa-common-dev \
    # Locale
    locales \
    # Misc tools
    vim \
    nano \
    less \
    bzip2 \
    lz4 \
    pigz \
    # pylint for BitBake checks
    pylint \
    # Needed by repo
    ca-certificates \
    gnupg \
    lsb-release \
    bsdmainutils \
    gcc-multilib \
    libgmp-dev \
    libmpc-dev \
    libssl-dev \
    libusb-1.0-0 \
    # pseudo (used by OE do_rootfs)
    libglib2.0-dev \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# Set up locale (en_US.UTF-8 required by BitBake)
# -----------------------------------------------------------------------------
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# -----------------------------------------------------------------------------
# Install repo tool
# -----------------------------------------------------------------------------
RUN curl -o /usr/local/bin/repo \
      https://storage.googleapis.com/git-repo-downloads/repo \
    && chmod a+x /usr/local/bin/repo

# -----------------------------------------------------------------------------
# Create a non-root user (BitBake refuses to run as root)
# -----------------------------------------------------------------------------
ARG UID=1000
ARG GID=1000
ARG USERNAME=yocto

RUN groupadd -g ${GID} ${USERNAME} \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# -----------------------------------------------------------------------------
# Set up git config for repo (required by repo init)
# -----------------------------------------------------------------------------
RUN git config --system user.email "yocto@build.local" \
    && git config --system user.name "Yocto Builder" \
    && git config --system color.ui false

# -----------------------------------------------------------------------------
# Directory layout inside the container
#
#   /yocto/         ← mounted from host (bind mount) — source + build output
#     st-yocto/     ← repo workspace, created by init.sh
#       layers/     ← all meta layers
#       build-*/    ← BitBake build directories (sstate, tmp, deploy)
#
#   /yocto/sstate-cache/   ← shared sstate cache (mount from host for speed)
#   /yocto/downloads/      ← shared downloads cache (mount from host)
#
# -----------------------------------------------------------------------------
RUN mkdir -p /yocto/sstate-cache /yocto/downloads \
    && chown -R ${USERNAME}:${USERNAME} /yocto

VOLUME ["/yocto"]

# -----------------------------------------------------------------------------
# Copy helper scripts into the image
# -----------------------------------------------------------------------------
COPY --chown=${USERNAME}:${USERNAME} scripts/ /home/${USERNAME}/scripts/
RUN chmod +x /home/${USERNAME}/scripts/*.sh

# -----------------------------------------------------------------------------
# Copy the ported LoRaWAN layer into the image so it's always available.
# The init script copies it into the repo workspace on first run.
# -----------------------------------------------------------------------------
COPY --chown=${USERNAME}:${USERNAME} \
    layers/meta-st-stm32mpu-app-lorawan-scarthgap/ \
    /home/${USERNAME}/layers/meta-st-stm32mpu-app-lorawan/

# -----------------------------------------------------------------------------
# Switch to the non-root build user
# -----------------------------------------------------------------------------
USER ${USERNAME}
WORKDIR /yocto

# Default shell entry — run init.sh for first-time setup,
# or bitbake.sh to trigger a build directly.
CMD ["/bin/bash"]
