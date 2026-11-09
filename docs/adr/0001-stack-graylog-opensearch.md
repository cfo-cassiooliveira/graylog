# ADR-0001: Stack Graylog 7.2 + OpenSearch 3.7 + MongoDB 8.0 em Docker

- **Status**: Aceito
- **Data**: 2026-11-09
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. VI.1 (logs no Graylog), Art. IV.4 (segredos), Art. IV.6 (dados pessoais)

## Contexto

A Constituição exige logs estruturados enviados ao **Graylog via GELF**. O legado já produz logs estruturados
(Serilog), mas não havia um Graylog para recebê-los. Precisamos de um ambiente local, em Docker, reutilizável
pelos demais projetos do `C:\Workspace` e configurado sem passos manuais na UI.

## Decisão

1. Projeto próprio em `C:\Workspace\graylog`, separado dos sistemas que logam nele.
2. **Graylog 7.2.2 + OpenSearch 3.7.0 + MongoDB 8.0.34**, versões dentro da matriz oficial de compatibilidade do
   Graylog 7.2 (OpenSearch até 3.7.x; MongoDB de 7.x a 8.2.x). Todas as imagens fixadas por **tag + digest**.
3. **OpenSearch "self-managed" em vez do Graylog Data Node**: o Data Node exige um assistente de preflight
   interativo na UI na primeira subida, o que impede o provisionamento 100% automatizado.
4. Plugin de segurança do OpenSearch **desligado**, mas o OpenSearch e o MongoDB ficam só na rede interna do
   compose (sem portas publicadas). O MongoDB tem usuário e senha. A UI/API (9000) e o GELF (12201 TCP/UDP)
   são publicados só em `127.0.0.1`.
5. **Rede Docker `observability`** (nome fixo): outros projetos entram como `external` e enviam GELF para
   `graylog:12201`. O Docker logging driver (GELF UDP) usa a porta publicada no host.
6. **Configuração como código**: um container `provisioner` (alpine + curl + jq) cria pela API REST, de forma
   idempotente, os inputs, o index set com retenção, o pipeline (incluindo o mascaramento LGPD), os streams e os
   alertas. As regras de pipeline ficam versionadas em `provisioning/rules/*.rule`.
7. **Ordem de processamento**: o pipeline roda **antes** do roteamento de streams, para que os campos derivados
   (`service_name`, `http_*`) sirvam às regras dos streams.

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Graylog Data Node | Recomendação atual da Graylog, TLS automático | Preflight interativo na 1ª subida | Impede automação total |
| OpenSearch com plugin de segurança | TLS/autenticação no índice | Certificados e senhas extras no local | Isolamento por rede basta no ambiente local |
| Content pack JSON | Importação nativa | Formato verboso e frágil entre versões | API REST + scripts é mais legível e testável |
| Configurar pela UI | Simples na primeira vez | Não reproduzível, sem revisão | Contra "configuração como código" |

## Consequências

- **Positivas**: `docker compose up -d` entrega o Graylog pronto (inputs, streams, alertas), reproduzível e versionado.
- **Negativas / riscos**: o OpenSearch sem autenticação depende do isolamento de rede. Em produção, use Data Node
  ou OpenSearch com segurança e TLS, GELF por TCP com TLS e um cofre de segredos.
- **Ações decorrentes**: novos sistemas criam seus streams no `provision.sh` e entram na rede `observability`.
