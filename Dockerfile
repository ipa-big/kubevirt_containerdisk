FROM ubuntu:26.04

RUN apt update && apt install -y ca-certificates curl qemu-utils xz-utils wget

RUN install -m 0755 -d /etc/apt/keyrings
RUN curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc

RUN tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

RUN apt update && apt install -y docker-cli docker-buildx-plugin

RUN mkdir -p /build
COPY build.sh /build/build.sh
COPY raspios-lite/Dockerfile /build/Dockerfile

WORKDIR /build

CMD ["/bin/bash", "/build/build.sh"]
