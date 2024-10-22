FROM ubuntu:20.04
ARG TERRAFORM_VERSION=1.3.2
ARG TERRAGRUNT_VERSION=0.68.4
ARG VAULT_VERSION=1.17.6
ARG YTT_VERSION=0.48.0
ARG KAPP_VERSION=0.60.0
ARG NETBIRD_VERSION=0.30.2
ARG KUBECTL_VERSION=1.24.6

# Update apt and Install dependencies
   
RUN apt-get update && apt install curl gnupg software-properties-common -y && add-apt-repository ppa:rmescandon/yq -y \ 
    && curl -sSL https://pkgs.netbird.io/debian/public.key | gpg --yes --dearmor --output /usr/share/keyrings/netbird-archive-keyring.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' | tee /etc/apt/sources.list.d/netbird.list \
    && apt update && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y \
    tzdata \
    dnsutils \
    git \
    jq \
    yq \
    libssl-dev \
    openvpn \
    python3 \
    python3-pip \
    screen \
    vim \
    wget \
    zip \
    mysql-client \
    netbird=${NETBIRD_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# Install tools and configure the environment
RUN wget -q https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip -O /tmp/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && unzip /tmp/terraform_${TERRAFORM_VERSION}_linux_amd64.zip -d /bin/ \
    && rm /tmp/terraform_${TERRAFORM_VERSION}_linux_amd64.zip
RUN wget -q https://github.com/gruntwork-io/terragrunt/releases/download/v${TERRAGRUNT_VERSION}/terragrunt_linux_amd64 -O /bin/terragrunt \
    && chmod +x /bin/terragrunt
RUN wget -q https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip -O /tmp/vault_${VAULT_VERSION}_linux_amd64.zip \
    && unzip /tmp/vault_${VAULT_VERSION}_linux_amd64.zip -d /bin/ \
    && rm /tmp/vault_${VAULT_VERSION}_linux_amd64.zip
RUN wget -q https://github.com/carvel-dev/ytt/releases/download/v${YTT_VERSION}/ytt-linux-amd64 -O /tmp/ytt-linux-amd64 \
    && mv /tmp/ytt-linux-amd64 /bin/ytt \
    && chmod +x /bin/ytt
RUN wget -q https://github.com/carvel-dev/kapp/releases/download/v${KAPP_VERSION}/kapp-linux-amd64 -O /tmp/kapp-linux-amd64 \
    && mv /tmp/kapp-linux-amd64 /bin/kapp \
    && chmod +x /bin/kapp
RUN wget -q https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl -O /bin/kubectl \
    && chmod +x /bin/kubectl   

RUN pip3 install --upgrade pip \
    && mkdir /workdir && cd /workdir \
    && mkdir keys \
    && python3 -m pip install ansible==5.7.1 netaddr kubernetes awscli openshift>=0.6 setuptools>=40.3.0 \
    && ansible-galaxy collection install community.kubernetes

COPY . iac-run-dir