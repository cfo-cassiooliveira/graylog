# ADR-0003: Token pseudônimo pesquisável (HMAC-SHA256) junto da máscara parcial, gerado na origem

- **Status**: Aceito
- **Data**: 2026-11-14
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. II.1 (simplicidade), Art. IV.1, IV.2, IV.4 e IV.6 (LGPD, Keycloak,
  segredos, dados pessoais), Art. VI.1 (logs no Graylog), Art. IX.1 (contrato `/api/v1`)
- **Relação com outros ADRs**: **complementa** o ADR-0002 (não o substitui). Os formatos de máscara do ADR-0002 continuam
  valendo; este ADR soma um token pesquisável e move a pseudonimização principal para a origem.
- **Implementação**: `docs/specs/001-pseudonimizacao-logs/` deste repositório.

## Contexto

O ADR-0002 grava dados pessoais com máscara parcial (`***.456.789-**`, `11*****4321`, `mar***`, `ana***@gmail`). A
máscara serve para leitura humana, mas **não serve para investigação**: `***.456.789-**` corresponde a ~100 mil CPFs, e
`mar***` a milhares de logins. Não dá para responder com segurança "quais eventos são deste titular?". O responsável
pediu a prática de mercado: o dado não pode ficar em claro, mas precisa continuar pesquisável e correlacionável.

O ADR-0002 já previa somar um hash com chave depois, sem mudar o formato da máscara.

Restrições levantadas:

- **Graylog 7.2.2** (versão do `docker-compose.yml`) **não tem HMAC** no pipeline. As funções de hash são só sem chave:
  `crc32`, `crc32c`, `md5`, `murmur3_32`, `murmur3_128`, `sha1`, `sha256`, `sha512` (código-fonte, branch 7.2:
  <https://github.com/Graylog2/graylog2-server/tree/7.2/graylog2-server/src/main/java/org/graylog/plugins/pipelineprocessor/functions/hashing>;
  ver também <https://community.graylog.org/t/hmac-hash-log-in-pipeline/19718>). Não há função que leia variável de
  ambiente nem segredo, e o texto das regras aparece na UI e na API para quem tem permissão de pipeline. Os adaptadores
  de lookup table (CSV, DSV HTTP, DNS, HTTP JSONPath) também expõem a configuração pela API.
- Espaço de valores pequeno: CPF tem 10^9 valores possíveis (9 dígitos livres + 2 verificadores), celular ~10^9.
  Um hash sem chave (`sha256(cpf)`) se inverte por força bruta em segundos ou minutos numa GPU comum.
- Hoje o valor em claro trafega da aplicação até o Graylog (GELF TCP/UDP sem TLS no ambiente local) e só é
  mascarado no pipeline.

Fontes:

- OWASP Logging Cheat Sheet: dados pessoais sensíveis "should be removed, masked, sanitized, hashed, or encrypted";
  recomenda pseudonimização quando a identidade não é necessária.
  <https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html>
- OWASP ASVS 5.0, V16.2.5: registrar dado sensível conforme o nível de proteção; certos dados "may only be logged by
  being hashed or masked, either in full or partially"; V16.4.2: logs protegidos contra acesso não autorizado.
  <https://github.com/OWASP/ASVS/blob/master/5.0/en/0x25-V16-Security-Logging-and-Error-Handling.md>
- ENISA, *Pseudonymisation techniques and best practices* (2019): hash sem chave não é recomendado para
  pseudonimização (vulnerável a dicionário/força bruta); recomenda função com chave (HMAC) quando é preciso
  correlacionar sem reverter, e tokenização/criptografia quando é preciso reverter.
  <https://www.enisa.europa.eu/publications/pseudonymisation-techniques-and-best-practices>
- NIST SP 800-122 §4.2.4 (de-identificação de PII) e NIST SP 800-188 (pseudonimização com chave mantida em separado).
  <https://csrc.nist.gov/pubs/sp/800/122/final> · <https://csrc.nist.gov/pubs/sp/800/188/final>
- PCI DSS 4.0: req. 3.4.1 (exibição mascarada: no máximo BIN + 4 últimos) e req. 3.5.1.1 (hashes do PAN devem ser
  "keyed cryptographic hashes"): o setor de pagamentos já proíbe hash sem chave para identificador de espaço pequeno.
  <https://www.pcisecuritystandards.org/document_library/>
- LGPD (Lei 13.709/2018): art. 5º III e XI, art. 12 (anonimizado não é dado pessoal, salvo se reversível com esforço
  razoável), **art. 13 §4º** (pseudonimização: perde a associação "senão pelo uso de informação adicional mantida
  separadamente pelo controlador em ambiente controlado e seguro"), art. 46 (medidas de segurança).
  <https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm>
- ANPD: Estudo Técnico sobre a Anonimização de Dados na LGPD e Nota Técnica 30/2024 (agenda regulatória, guia de
  anonimização e pseudonimização).
  <https://www.gov.br/anpd/pt-br/centrais-de-conteudo/documentos-tecnicos-orientativos/estudo_tecnico_sobre_anonimizacao_de_dados_na_lgpd___analise_juridica.pdf/@@display-file/file>
- GDPR art. 4(5) (mesma definição de pseudonimização) e considerando 26 (dado pseudonimizado continua pessoal).
  <https://eur-lex.europa.eu/eli/reg/2016/679/oj>

## Decisão

1. **Dois campos por dado pessoal**, sempre os dois, nunca o valor em claro:

   | Campo | Conteúdo | Uso |
   |---|---|---|
   | `<Campo>` (ex.: `Cpf`, `Phone`, `UserName`, `Email`) | Máscara parcial do ADR-0002 (`***.456.789-**`) | Leitura humana; nome do campo inalterado, dashboards e streams continuam funcionando |
   | `<Campo>_token` (ex.: `Cpf_token`) | `k<versão>-` + HMAC-SHA256 truncado a 128 bits, em hex minúsculo (ex.: `k1-b81c27bb…`, 35 caracteres) | Pesquisa e correlação exata |

   Vale para **CPF, CNPJ, telefone, e-mail e login** (todos os campos das listas `LGPD_*_FIELDS`).

2. **Cálculo do token**: `HMAC-SHA256(chave_kN, "<domínio>|" + valor_canônico)`, truncado aos 16 primeiros bytes.
   - Domínios: `cpf`, `cnpj`, `phone`, `login`. **E-mail e login usam o mesmo domínio `login`**: o usuário entra com
     um ou outro no mesmo campo, e a investigação de `ana.souza@gmail.com` precisa achar os dois casos.
   - Valor canônico: CPF só dígitos (11); CNPJ sem `./-`, em maiúsculas (14); telefone só dígitos, sem o `55` inicial
     quando tiver 12 ou 13 dígitos, com DDD (10 ou 11 dígitos); login/e-mail com `trim` e minúsculas (invariante).
   - Valor fora do formato do tipo: não gera token; o campo vira `***` (regra do ADR-0002).
   - Vetores de teste obrigatórios (iguais em todas as implementações) no `plan.md` da spec 001.
3. **Onde é gerado: na origem**, antes de o log sair do processo. A aplicação nunca envia o valor em claro ao Graylog:
   - **Legado (.NET 10, Serilog)**: enricher no `LoggingSetup` troca, pelas listas de nomes de campo do ADR-0002, a
     propriedade pela máscara e adiciona `<Campo>_token`. O Serilog renderiza `message`/`full_message` depois dos
     enrichers, então o texto já sai mascarado.
   - **Cadastro**: passa a enviar ao Graylog (Serilog + GELF TCP, como o legado) já com o mesmo enricher.
   - **Keycloak**: nada muda; a auditoria envia ids técnicos. O `masked_login` do ADR-0007 do keycloak é emitido pelos eventos de migração (sem token), como campo GELF próprio já no formato de máscara, e `masked_login` está em `LGPD_LOGIN_FIELDS`: o valor passa intacto quando tem a forma `abc***` ou `x***@dominio`; identificador de 1 a 3 caracteres sem `@` (ex.: `a***`) vira `***`. O smoke ainda usa evento sintético para o stream `Identidade - Migração`.
   - **nginx**: sem dado pessoal em campo estruturado; segue só com a rede de segurança do pipeline.
4. **Graylog continua como rede de segurança, só com máscara** (ADR-0002, estágios 3 e 4). O pipeline **não** gera
   token, porque não tem HMAC e qualquer chave numa regra ou lookup table ficaria visível na UI/API. As regras passam a
   aceitar, sem alterar, valores que já chegam no formato de máscara e os campos `*_token`. Valor em claro que chegar ao
   Graylog é defeito da origem: é mascarado, fica sem token e deve gerar correção na origem.
5. **Chave**: 256 bits aleatórios, **uma por ambiente, a mesma no legado e no cadastro** (correlação do mesmo titular
   entre os dois), identificada por versão (`k1`, `k2`...).
   - Configuração: `Logging:Pseudonymization:CurrentKeyId` e `Logging:Pseudonymization:Keys:<keyId>` (base64).
     Em variável de ambiente: `Logging__Pseudonymization__Keys__k1`.
   - Dev: user-secrets / `.env` fora do Git. Demais ambientes: cofre ou variável de ambiente (Art. IV.4).
   - **Nunca** no Graylog, no Keycloak, em regra de pipeline, em lookup table, em log ou na imagem.
6. **Rotação anual** (ou imediata em suspeita de vazamento). A origem passa a usar `k(N+1)`; a chave anterior fica
   configurada **só para pesquisa** até o fim da retenção dos logs (30 dias) e depois é **destruída**: os tokens antigos
   deixam de ser vinculáveis. Durante a convivência, a pesquisa considera as duas versões.
7. **Pesquisa pelo operador**:
   - **Produção/homologação: endpoint no Cadastro** (único sistema novo autenticado só pelo Keycloak, com BFF,
     papéis e OTP de admin já prontos; o Graylog é infraestrutura sem código de aplicação e o Legado está em
     desativação):
     - `POST /api/v1/log-search/queries` (POST para o valor nunca ir em URL), corpo
       `{ "dataType": "cpf|cnpj|phone|email|login", "value": "...", "caseReference": "INC-1234" }`.
     - Resposta 200: `{ "dataType", "tokens": [{ "keyId", "token" }], "graylogQuery" }`, com a consulta já montada
       sobre todos os nomes de campo do tipo e todas as chaves vigentes, ex.:
       `CPF_token:("k1-…" OR "k2-…") OR Cpf_token:(…) OR cpf_token:(…)` (ordem ordinal dos nomes). 400/401/403/429 em Problem Details.
     - Autorização: realm role **`log-investigator`** no Keycloak (policy `logs:investigate` no Cadastro), com **OTP
       obrigatório**, antiforgery e rate limit por usuário. Tela `/log-search` ("Pesquisa em logs") no frontend do
       Cadastro, porque o BFF não expõe a API fora da sessão do navegador.
       O step-up de OTP exige `acr=otp` e `auth_time` de no máximo 5 minutos, tolerando `auth_time` até 1 minuto no futuro
       (diferença de relógio entre Keycloak e BFF; `OtpStepUpRequirement` do Cadastro).
     - **Auditoria**: cada pesquisa gera um log `Information` com `audit_event: log_search_query_issued`,
       `investigator_id` (o `sub` do Keycloak, nunca o login), `data_type`, `case_reference`, os tokens gerados (campo
       `tokens`, um texto único com os tokens separados por vírgula, não lista: `ParseArrayValues=true` do sink a dividiria) e o
       `trace_id`; **nunca o valor pesquisado**. Stream `Cadastro - Pesquisa em logs (LGPD)` no Graylog. Falha de
       autorização (403) também é registrada, com `audit_event: log_search_access_denied` (com `investigator_id`,
       sem tokens). O stream aceita os dois valores de `audit_event` vindos de
       `service_name: cadastro-api` (nunca de `log_source: browser`), fica no índice do Cadastro e tem os alertas
       `Cadastro - Excesso de pesquisas em logs` (mais de 10 pesquisas do mesmo `investigator_id` em 10 minutos) e
       `Cadastro - Acessos negados à pesquisa em logs` (mais de 2 negações do mesmo `investigator_id` em 10 minutos).
       Os inputs GELF não autenticam o remetente: quem alcança a rede pode forjar eventos na trilha; em produção, input com
       TLS e mTLS e rede dedicada (CLAUDE.md do graylog). A retenção do índice é de 30 a 35 dias (mínimo 30, apagado até 35).
   - **Dev: script** `cadastro/scripts/log-search-token.sh` que lê a chave do `.env` local e imprime a mesma
     consulta. Não existe em outros ambientes.
8. **Texto livre** (`message`, `full_message`, `ExceptionMessage`, `StackTrace`, `ClientMessage`, `ClientStack`, `ClientSource`,
   `RequestPath`, `case_reference` e `http_path`, o único campo de URL do access log do nginx): só máscara, nunca
   token. Na origem, o texto renderizado do template já sai
   mascarado; o que vier em exceções de terceiros continua coberto pelo estágio 4 do pipeline. Para achar eventos de um
   titular, pesquisa-se pelo campo `*_token`, não pelo texto.
9. **Fora do escopo do reconhecimento por formato no texto livre** (complementa o item 5 do ADR-0002): **celular sem
   DDD** (8 ou 9 dígitos se confundem com ids, valores e números de pedido, e mascará-los corromperia logs técnicos).
   Ele só é protegido quando chega em campo estruturado (`LGPD_PHONE_FIELDS`), onde o tipo é conhecido.
10. **Valor fora do formato vira `***` no campo e nos textos, exceto o curto** (corrige o ADR-0002): o valor original
    é trocado em `message`/`full_message`/exceções (palavra inteira) pela máscara, quando válida, ou por `***`, quando
    fora do formato. O valor **curto** não é trocado nos textos, para não corromper palavras (ex.: `ab` em `tabela`,
    `api` em `Legado.Api`): login ou e-mail com menos de 4 caracteres (o padrão de login do Cadastro é 4–30), CPF e
    telefone com menos de 8 dígitos e CNPJ com menos de 8 caracteres alfanuméricos **no Graylog**. Na origem (legado e cadastro) a contagem é só de dígitos ASCII para CPF, CNPJ e telefone: um CNPJ alfanumérico fora do formato com menos de 8 dígitos não é trocado no texto da origem, mas é trocado no Graylog se tiver 8 ou mais caracteres alfanuméricos (divergência conhecida, só afeta valor inválido). A regra do Graylog está nos
    modelos `lgpd-*.rule.tmpl`. **Na origem** (legado e cadastro, texto do `Scope`) a regra é outra: valor fora do formato de CPF, CNPJ ou telefone com 8 ou mais dígitos ASCII é trocado por `***` no texto; login ou e-mail fora do formato (ex.: `@gmail.com`), de qualquer tamanho, **não** é trocado no texto da origem (só o campo vira `***`); o Graylog troca por `***` o login inválido com 4 ou mais caracteres.

## Alternativas consideradas

| Alternativa | Proteção | Pesquisável / correlacionável | Reversível | Gestão de chave | Motivo da rejeição |
|---|---|---|---|---|---|
| Supressão total (não logar / `***`) | Máxima | Não | Não | Nenhuma | Não atende à investigação pedida |
| Só máscara parcial (ADR-0002 atual) | Boa | Parcial: `***.456.789-**` casa ~100 mil CPFs | Não | Nenhuma | Não identifica o titular com segurança; mantida para leitura humana |
| Hash simples (`sha256(cpf)`) | **Fraca**: espaço de 10^9 se esgota por força bruta em minutos | Sim | Na prática sim | Nenhuma | Equivale a dado em claro (ENISA; PCI DSS 3.5.1.1 exige hash com chave) |
| `sha256(chave + valor)` no pipeline (chave em regra ou lookup table) | Média: construção ad hoc (não é HMAC) e chave legível na UI/API | Sim | Não | Chave exposta no Graylog | Chave fica junto dos dados; contraria a separação do art. 13 §4º |
| HMAC no pipeline via sidecar (lookup HTTP JSONPath → serviço com a chave) | Boa | Sim | Não | Chave no sidecar | Novo serviço crítico na ingestão; o valor em claro trafega até o Graylog e vai na URL do adaptador (Art. II.1, IV.6) |
| Plugin Java próprio de HMAC no Graylog | Boa | Sim | Não | Chave no servidor Graylog | Manutenção a cada versão; chave no mesmo servidor dos logs |
| **HMAC-SHA256 com chave em cofre, na origem (escolhida)** | Boa: sem a chave, força bruta é inviável | Sim, igualdade exata | Não | Uma chave por ambiente, versionada | — |
| Tokenização com cofre (tabela token ↔ valor) | Muito boa | Sim | Sim | Cofre + banco de mapeamento | Reversão desnecessária para log; cria um banco de CPFs em claro (maior risco LGPD) |
| Criptografia determinística / FPE (AES-SIV, FF1) | Boa | Sim | Sim | Chave de cifra | Reversibilidade desnecessária; quem tem a chave lê o histórico; FF1 em domínio pequeno exige cuidado (NIST SP 800-38G) |
| Endpoint de pesquisa no Legado | — | — | — | — | Sistema em desativação, com autenticação própria (ADR-0001 do legado) |
| Endpoint de pesquisa em serviço novo dedicado | — | — | — | — | Mais um serviço, CI e client no Keycloak sem ganho sobre o Cadastro (Art. II.1) |
| Script com a chave na máquina de cada operador (também em produção) | — | — | — | Chave espalhada | Quem tem a chave e acesso aos logs reidentifica por força bruta; sem trilha de quem pesquisou |

## Consequências

- **Positivas**:
  - Investigação por titular passa a ser exata (`*_token`), sem guardar o valor em claro em lugar nenhum.
  - O valor em claro não sai mais da aplicação: some do tráfego GELF, do journal e do índice.
  - Correlação entre legado e cadastro no mesmo ambiente.
  - Toda pesquisa tem dono, motivo e trilha no Graylog.
  - Destruir uma chave após a retenção torna os tokens antigos não vinculáveis.
- **Negativas / riscos**:
  - Token HMAC é **pseudonimização, não anonimização** (LGPD art. 13 §4º; GDPR considerando 26): os logs continuam
    sendo dado pessoal. Retenção de 30 dias e acesso restrito ao Graylog continuam obrigatórios.
  - Vazamento da chave + acesso aos logs = reidentificação por força bruta. Mitigação: chave só nas aplicações,
    rotação, destruição após a retenção.
  - O endpoint é um oráculo ("este CPF aparece nos logs?"): role própria, OTP, rate limit e auditoria.
  - O algoritmo é implementado duas vezes (legado e cadastro, sem pacote compartilhado): os vetores de teste comuns
    são a garantia de que os tokens coincidem.
  - As regras do pipeline precisam reconhecer valores já mascarados; sem isso, a máscara que chega da origem viraria
    `***`.
- **Ações decorrentes**: tarefas em `docs/specs/001-pseudonimizacao-logs/tasks.md`.
