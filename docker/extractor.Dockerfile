FROM alpine:3.21

# Extractor/tooling stage ONLY. This Alpine image carves the embedded OCI rootfs
# out of the UniFi OS Server installer and imports it into the docker daemon.
# The runtime image is built FROM that carved rootfs, never from Alpine.
RUN apk add --no-cache \
        bash curl jq tar xz gzip file coreutils findutils \
        python3 py3-pip skopeo \
    && pip install --no-cache-dir --break-system-packages binwalk

COPY scripts/carve-oci.sh /usr/local/bin/carve-oci
RUN chmod +x /usr/local/bin/carve-oci

ENTRYPOINT ["/bin/bash"]
