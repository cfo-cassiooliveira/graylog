# Imagem mínima para o provisionamento via API REST (curl + jq). Alpine 3.22 fixado por digest.
FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
RUN apk add --no-cache curl jq bash
WORKDIR /provisioning
COPY --chmod=755 provision.sh ./
COPY rules/ ./rules/
USER nobody
ENTRYPOINT ["/provisioning/provision.sh"]
