FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

# Install host (x86_64) build tools
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
    && rm -rf /var/lib/apt/lists/*

# Install ARM (armhf) binaries for the initramfs — these run on the Surface 2
RUN dpkg --add-architecture armhf \
    && apt-get update && apt-get install -y \
    busybox-static:armhf \
    && rm -rf /var/lib/apt/lists/*

# Extract ARM e2fsprogs without installing (conflicts with host e2fsprogs)
RUN mkdir -p /opt/armhf && cd /opt/armhf \
    && apt-get update \
    && apt-get download e2fsprogs:armhf libext2fs2:armhf libcom-err2:armhf libblkid1:armhf libuuid1:armhf libc6:armhf libgcc-s1:armhf 2>/dev/null \
    && for deb in *.deb; do dpkg-deb -x "$deb" /opt/armhf/root; done \
    && rm -f *.deb && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Copy project files into the image
COPY . /work/

# Fix Windows CRLF line endings in shell scripts
RUN apt-get update && apt-get install -y dos2unix && rm -rf /var/lib/apt/lists/* \
    && find /work/scripts -name '*.sh' -exec dos2unix {} +

ENV ARCH=arm
ENV CROSS_COMPILE=arm-linux-gnueabihf-

CMD ["bash", "/work/scripts/build.sh"]
