FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/runner \
    TMPDIR=/runner \
    XDG_CACHE_HOME=/runner/.cache \
    PATH=/usr/local/bin:/usr/bin:/bin

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y openssh-client sshpass && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --gid 10001 ansible && \
    useradd --uid 10001 --gid ansible --no-create-home --home-dir /runner --shell /usr/sbin/nologin ansible

WORKDIR /opt/hunter-ansible

COPY ansible_executor/requirements.txt ./requirements.txt
RUN python -m pip install --no-cache-dir --require-hashes --requirement requirements.txt

COPY --chmod=0555 ansible_executor/hunter_ansible ./hunter_ansible
COPY --chmod=0555 ansible_executor/entrypoint.sh ./entrypoint.sh

USER 10001:10001

ENTRYPOINT ["/opt/hunter-ansible/entrypoint.sh"]
