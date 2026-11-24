# ADR-0004: Logs do broker RabbitMQ — retenção, campos e análise LGPD

- **Status**: Aceito
- **Data**: 2026-11-23
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. IV.1 (LGPD), Art. IV.6 (dados pessoais), Art. VI.1 (logs no Graylog)

## Contexto

O `../rabbitmq` passa a enviar os logs do broker ao Graylog. O coletor (Fluent Bit) lê o arquivo JSON do RabbitMQ e
envia por GELF TCP (`graylog:12201`, rede `observability`). O que chega, depois da minimização feita na origem:

| Campo no Graylog | Origem | Conteúdo |
|---|---|---|
| `message` | `msg` do broker (via `short_message`) | Texto do log do broker |
| `level` | `level` do broker convertido para syslog numérico na origem (3 error, 4 warning, 5 notice, 6 info) | Número |
| `time` | horário do evento no broker | Texto (o `timestamp` do Graylog é o de recebimento) |
| `service_name`, `tag` | fixos `rabbitmq` | Identificação do sistema |
| `host` | fixo `rabbitmq` | Exigido pelo GELF |

`pid`, arquivo, linha e domínio do log são descartados no Fluent Bit (allowlist `time`, `level`, `msg`).

O texto pode trazer:

- **Nome de usuário** em logins recusados. Os usuários cadastrados no broker são **técnicos** (administração,
  aplicações, monitoração), criados pelo provisionamento do `../rabbitmq`; nenhuma pessoa tem usuário próprio no broker.
  Mas, num login **recusado**, o nome logado é o que o cliente digitou, que pode não existir no broker (ex.: um operador
  que digita o próprio login corporativo). Formato real no RabbitMQ 4.3 (medido por `../rabbitmq/scripts/e2e-graylog.sh`),
  **2 linhas por tentativa**: no management, `User '<u>' failed to authenticate: user '<u>' - invalid credentials` e
  `HTTP access denied: user '<u>' - invalid credentials`, ambas `warning` (4); no AMQP, a mesma linha `failed to
  authenticate` (`warning`, 4) e `Error on AMQP connection <pid> (<ip:porta> -> <ip:porta>, state: starting):`
  + quebra de linha + `PLAIN login refused: user '<u>' - invalid credentials` (`error`, 3).
- **IP:porta** dos clientes AMQP (`172.18.0.5:41234 -> 172.18.0.3:5672`): no ambiente local, endereços de containers da
  rede Docker; em produção, endereços de serviços, não de pessoas.
- Nomes de vhost, fila, exchange e conexão: identificadores técnicos (Art. I).

## Decisão

1. **Sem regra de pipeline própria.** O nível já chega numérico (o `level.lua` do Fluent Bit converte; valor
   desconhecido vira 6), então `level:<=3` funciona e a regra `30-level-name.rule` gera `level_name`. O texto não é JSON
   (não há o que extrair, ao contrário do Grafana). A regra `16-text-level-from-content` só age nas tags do
   SonarQube/PostgreSQL. A regra `15-docker-level-from-content` vale para **qualquer** mensagem com `tag` e level 3 cujo
   texto traga `[debug]`, `[info]`, `[notice]`, `[warn]`, `[error]`, `[crit]`, `[alert]` ou `[emerg]`, e troca o nível
   pelo do texto (rebaixa com `[warn]`/`[info]`/`[notice]`). Os logs do RabbitMQ têm `tag` e o texto traz valores do
   cliente: medido com log real (e2e do `../rabbitmq`), um login AMQP recusado com o usuário `e2e-nobody-...-[info]`
   chegava com level **6** em vez de 3. Por isso a regra 15 **exclui a tag `rabbitmq`** (o nível já vem certo da
   origem), com caso no smoke ("erro real com \"[info]\" vindo do cliente continua level 3") e no e2e.
2. **Usuários técnicos não são mascarados.** Não são dados pessoais (não identificam pessoa natural) e são
   necessários para investigar credencial vazada, expirada ou força bruta. Nenhum nome é acrescentado às listas
   `LGPD_*` e nenhum campo de login é criado.
   **Risco residual aceito (LGPD)**: num login recusado o nome é o que o cliente digitou; um operador pode digitar o
   próprio login corporativo (sem `@`), que fica indexado em claro por 30 a 35 dias. Aceito pelo responsável técnico
   porque o management e o AMQP só escutam em `127.0.0.1` (só operadores internos do host chegam a eles), a retenção é
   limitada (`LOG_RETENTION_DAYS`) e e-mail, CPF e celular continuam mascarados pela rede de segurança (item 3). Logins
   sem `@` **não** são mascarados (esconderiam a credencial técnica atacada). **Reavaliar** antes de o broker ser exposto
   fora do host (porta publicada fora do loopback, clientes de outras máquinas ou de pessoas).
3. **Rede de segurança mantida**: o texto vai no `message`, que já está em `LGPD_TEXT_FIELDS`. Se alguém criar no broker
   um usuário com e-mail, CPF ou celular como nome, o valor é mascarado no texto pelo formato (smoke: "usuário em forma
   de e-mail"). Regra para o `../rabbitmq`: usuários do broker são sempre técnicos, nunca nome/e-mail de pessoa.
4. **IP de cliente mantido**: é endereço de serviço, não de titular. Se um dia clientes de pessoas (ex.: navegador via
   Web STOMP/MQTT) acessarem o broker direto, a decisão é revista antes.
5. **Index set `RabbitMQ`** (prefixo `rabbitmq`), com a mesma retenção dos demais (`LOG_RETENTION_DAYS`: mínimo 30
   dias, apagado até 35). Não há dado pessoal que exija prazo menor, e 30 dias cobrem a investigação de incidentes
   do broker (alarmes de memória/disco, partições, falhas de autenticação). Mantém um único parâmetro de retenção.
6. **Stream `RabbitMQ - Infra`** (`service_name:rabbitmq`, removido do stream padrão) e dois alertas:
   - `RabbitMQ - Erros no broker` (prioridade 2): **5 ou mais** mensagens `level<=3` em 5 minutos, **sem** os logins
     recusados. Erros isolados são comuns no broker (cliente que derruba a conexão, handshake expirado) e não indicam
     incidente; vários na mesma janela indicam problema persistente. O login AMQP recusado gera uma linha `error`
     (`PLAIN login refused ... invalid credentials`) e fica fora (`NOT message:"invalid credentials"`) para não disparar
     dois alertas pelo mesmo motivo.
   - `RabbitMQ - Falhas de login em massa` (prioridade 3): **mais de 20** tentativas recusadas em 5 minutos, mesmo
     limiar de `Keycloak/Legado - Falhas de login em massa`. A consulta é `message:"failed to authenticate"`, que aparece
     **uma vez por tentativa** nos dois protocolos; `invalid credentials` aparece duas vezes por tentativa e dispararia
     com 11 tentativas (corrigido em 2026-11-24 após a medição real).
7. **Sem alerta de silêncio** (ausência de logs): o projeto não tem esse tipo de alerta (o `ensure_event` só cria
   condição "maior que") e o broker em operação normal, no nível `info`, pode passar longos períodos sem logar, o que
   geraria alarme falso. A disponibilidade do broker e do coletor é vigiada pelas métricas/health checks do
   `../rabbitmq` e do `../grafana`.

## Consequências

- O smoke test envia mensagens no formato real do Fluent Bit e prova roteamento, nível numérico, `time` preservado,
  usuário técnico legível, e-mail mascarado, configuração dos alertas e que a consulta de cada alerta passa do limiar.
- O e2e real `../rabbitmq/scripts/e2e-graylog.sh` (só local) prova o caminho broker -> Fluent Bit -> Graylog com logins
  recusados reais: stream único, níveis, texto e contagem das consultas dos alertas. O smoke daqui usa o mesmo formato.
- **Risco residual aceito (LGPD, item 2)**: login digitado por engano num login recusado fica em claro por 30 a 35 dias;
  condição: broker só em `127.0.0.1` com operadores internos. Reavaliar quando o broker for exposto fora do host.
- Campo novo vindo do coletor (fora de `time`, `level`, `msg`) exige revisão deste ADR e caso no smoke.

## Alternativas consideradas

- **Mascarar o usuário em todo login recusado** (regex no texto do RabbitMQ): rejeitada; não é dado pessoal e
  esconderia qual credencial técnica está sendo atacada.
- **Retenção menor (ex.: 7 dias)**: rejeitada; sem dado pessoal não há motivo de LGPD e a investigação de incidentes
  intermitentes precisa de histórico. Um segundo parâmetro de retenção complicaria a operação.
- **Alerta a cada erro (limiar 0, como SonarQube/Keycloak)**: rejeitada; o broker registra como erro eventos causados
  pelos clientes, o que geraria alarme a cada reconexão.
