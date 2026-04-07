FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    libncurses-dev \
    device-tree-compiler \
    gcc-arm-linux-gnueabihf \
    binutils-arm-linux-gnueabihf \
    u-boot-tools \
    cpio \
    rsync \
    xz-utils \
    python3 \
    wget \
    curl \
    kmod \
    busybox-static \
    dosfstools \
    e2fsprogs \
    parted \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

ENV ARCH=arm
ENV CROSS_COMPILE=arm-linux-gnueabihf-
