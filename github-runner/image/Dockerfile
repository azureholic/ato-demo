ARG RUNNER_BASE_IMAGE
FROM ${RUNNER_BASE_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl jq git gnupg python3 python-is-python3 python3-venv python3-pip python3-cryptography \
    && curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/microsoft.deb \
    && dpkg -i /tmp/microsoft.deb && rm /tmp/microsoft.deb \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-azure-cli.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-azure-cli.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends azure-cli powershell \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
ARG AZD_VERSION=1.37.3
RUN curl -fsSL "https://github.com/Azure/azure-dev/releases/download/azd_${AZD_VERSION}/azd-linux-amd64.tar.gz" -o /tmp/azd.tar.gz \
    && tar -xzf /tmp/azd.tar.gz -C /tmp \
    && install /tmp/azd-linux-amd64 /usr/local/bin/azd \
    && rm /tmp/azd.tar.gz /tmp/azd-linux-amd64 \
    && az bicep install --version v0.48.1
COPY github-actions-runner/entrypoint.sh /home/runner/entrypoint.sh
COPY github-actions-runner/register.py /home/runner/register.py
RUN chmod 755 /home/runner/entrypoint.sh && chown runner:runner /home/runner/entrypoint.sh /home/runner/register.py
USER runner
WORKDIR /home/runner
ENV PATH="/home/runner/.local/bin:${PATH}"
RUN az bicep install --version v0.48.1
ENTRYPOINT ["/home/runner/entrypoint.sh"]
