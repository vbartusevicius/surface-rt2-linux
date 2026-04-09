FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Build tools + disk image creation tools
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
    dosfstools \
    e2fsprogs \
    parted \
    file \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY . /work/

# Fix Windows CRLF line endings in shell scripts
RUN find /work/scripts -name '*.sh' -exec dos2unix {} +

ENV ARCH=arm
ENV CROSS_COMPILE=arm-linux-gnueabihf-

# Usage: docker run --rm --privileged -v "$PWD/output:/work/output" surface2-build <command>
# Commands: prebuilt, image, dtb, kernel, full
ENTRYPOINT ["bash", "/work/scripts/build.sh"]
CMD []
