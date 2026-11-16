# Spec 001 — Pseudonimização pesquisável de dados pessoais nos logs

- **Status**: Aprovada (decisões P1–P4 respondidas em 2026-11-14)
- **Data**: 2026-11-14 · **Autor**: Cassio Oliveira
- **Projetos**: `graylog` (pipeline, streams, documentação) · `legado` (origem .NET) · `cadastro` (origem .NET +
  endpoint e tela de pesquisa) · `keycloak` (role e OTP)
- **Decisões**: ADR-0002 (máscara) e ADR-0003 (token HMAC) deste repositório

## 1. Problema e objetivo

Os logs gravam dados pessoais só com máscara parcial (ADR-0002). A máscara protege, mas não permite responder numa
investigação "quais eventos são deste CPF/usuário?". Além disso, o valor em claro ainda trafega da aplicação ao Graylog
e só é mascarado no pipeline, e há divergências entre documentação e código levantadas na revisão (campos de texto
fora da lista, máscaras `***@***` nas APIs de client-logs, comentários desatualizados).

Objetivo: **nenhum dado pessoal em claro em lugar nenhum do caminho do log**, com **pesquisa exata por titular** feita
por pessoa autorizada, auditada, e documentação igual ao código nos 4 repositórios.

**Métricas de sucesso**

- 0 valores em claro de CPF, CNPJ, telefone, e-mail ou login em qualquer campo GELF enviado por legado e cadastro
  (teste de integração em cada origem).
- 100% dos campos das listas `LGPD_*_FIELDS` com máscara + `*_token` quando vindos de legado/cadastro.
- Pesquisa por um CPF conhecido retorna 100% dos eventos dele em legado e cadastro (smoke test ponta a ponta).
- 100% das pesquisas registradas com investigador, motivo e tokens, sem o valor pesquisado.
- 0 divergências abertas na auditoria cruzada documentação × código (tarefa X01).

## 2. Usuários e permissões

| Perfil | O que pode fazer nesta feature |
|---|---|
| Investigador (`log-investigator`, OTP obrigatório) | Gerar a consulta do Graylog para um CPF, CNPJ, telefone, e-mail ou login, informando o motivo |
| Usuário autenticado sem a role | Nada: recebe 403 e a tentativa é registrada |
| Operação/Segurança (acesso ao Graylog) | Ler logs (máscara + token) e a trilha de pesquisas no stream de auditoria |
| Desenvolvedor (só ambiente local) | Gerar a consulta com o script local, usando a chave do `.env` |

## 3. Histórias de usuário e critérios de aceite

### US-01 — Origem nunca envia dado pessoal em claro

```gherkin
Cenário: legado registra um CPF em campo estruturado
  Dado que o legado registra "Cadastro recusado para CPF {Cpf}" com Cpf = "123.456.789-09"
  Quando o evento chega ao Graylog
  Então o campo Cpf é "***.456.789-**"
  E o campo Cpf_token é o token k1 do CPF 12345678909
  E message e full_message contêm "***.456.789-**" e não contêm "123.456.789-09" nem "12345678909"

Cenário: valor fora do formato
  Dado um campo Phone com valor "abc"
  Quando o evento é registrado
  Então o campo Phone é "***" e não existe Phone_token

Cenário: e-mail e login correlacionam
  Dado um evento com UserName = "Ana.Souza@Gmail.com" e outro com Email = "ana.souza@gmail.com"
  Então os dois têm o mesmo token (UserName_token = Email_token)

Cenário: chave ausente na configuração
  Dado que a aplicação sobe sem Logging:Pseudonymization:Keys:<CurrentKeyId>
  Então a aplicação não inicia (fail fast) com mensagem técnica sem o valor da chave
```

### US-02 — Graylog como rede de segurança

```gherkin
Cenário: máscara e token prontos vindos da origem
  Dado um evento com Cpf = "***.456.789-**" e Cpf_token = "k1-…"
  Quando passa pelo pipeline
  Então os dois campos ficam inalterados

Cenário: valor em claro de origem não adaptada
  Dado um evento com Cpf = "12345678909" e sem Cpf_token
  Então Cpf vira "***.456.789-**", não há token, e o valor some dos campos de texto

Cenário: valor curto no campo não corrompe os textos
  Dado um evento com UserName = "ab" e message "tabela abc"
  Então UserName vira "***" e message continua "tabela abc"

Cenário: URL do navegador e caminho da requisição
  Dado ClientSource ou RequestPath contendo "ana.souza@gmail.com"
  Então o valor gravado contém "ana***@gmail"
```

### US-03 — Pesquisar eventos de um titular

```gherkin
Cenário: investigador gera a consulta
  Dado que entrei como "log-investigator" com OTP
  Quando abro "Pesquisa em logs", escolho "CPF", informo "123.456.789-09" e o motivo "INC-1234"
  E clico em "Gerar consulta"
  Então vejo a consulta do Graylog com os tokens de todas as chaves vigentes
  E posso copiá-la com "Copiar consulta"
  E o valor informado é apagado do formulário

Cenário: valor inválido para o tipo
  Quando informo "123" como CPF
  Então vejo "Informe um CPF com 11 dígitos." e nada é gerado nem registrado como pesquisa

Cenário: sem permissão
  Dado que entrei sem a role "log-investigator"
  Quando abro /log-search
  Então vejo "Você não tem permissão para acessar esta página." e o link "Voltar para meu perfil"
  E a API responde 403 e a tentativa fica registrada

Cenário: limite de pesquisas
  Dado que fiz 30 pesquisas na última hora
  Quando peço outra
  Então vejo "Limite de pesquisas atingido. Tente novamente mais tarde." (API 429)
```

### US-04 — Trilha de auditoria

```gherkin
Cenário: pesquisa registrada
  Quando um investigador gera uma consulta
  Então o stream "Cadastro - Pesquisa em logs (LGPD)" recebe um evento com investigator_id, data_type,
       case_reference e os tokens
  E o evento não contém o valor pesquisado nem sua máscara
```

### US-05 — Rotação de chave

```gherkin
Cenário: convivência de duas chaves
  Dado CurrentKeyId = "k2" e a chave "k1" ainda configurada
  Quando a origem registra um CPF
  Então o token começa com "k2-"
  E a consulta gerada para esse CPF contém os tokens "k1-…" e "k2-…"
```

### US-06 — Documentação igual ao código

```gherkin
Cenário: auditoria cruzada
  Quando a revisão compara README, CLAUDE.md, ADRs e comentários com o código dos 4 repositórios
  Então cada afirmação sobre formatos, campos, streams e fluxos tem um teste ou smoke que a comprova
  Ou é corrigida/removida
```

## 3b. Experiência do usuário (tela `/log-search` do Cadastro)

**Jornada**: Cadastro (menu do usuário, item "Pesquisa em logs", visível só com a role) → escolhe o tipo → informa o
valor e o motivo → "Gerar consulta" → copia a consulta → cola na busca do Graylog.

| Estado | Comportamento |
|---|---|
| Carregando | Botão "Gerar consulta" desabilitado com spinner; campos bloqueados |
| Vazio (inicial) | Formulário com dica: "Informe o dado da pessoa e o motivo. O valor não é registrado; só o token e o motivo." |
| Erro | Validação: foco no primeiro campo inválido + mensagem do campo. Falha geral: "Não foi possível gerar a consulta agora. Tente novamente em instantes." + "Tentar de novo" (dados preservados). 403: tela de sem permissão. 429: mensagem de limite |
| Sucesso | Cartão com a consulta em fonte monoespaçada, "Copiar consulta" (feedback "Consulta copiada."), lista de chaves usadas e aviso: "A consulta encontra só eventos com o campo *_token (legado e cadastro). Textos antigos e outras fontes têm só a máscara." O campo do valor é limpo |

**Microtextos** (via `$localize`)

| Elemento | Texto |
|---|---|
| Título | "Pesquisa em logs" |
| Tipo | "Tipo de dado": "CPF", "CNPJ", "Celular/telefone", "E-mail", "Login" |
| Valor | "Valor" — ajuda por tipo, ex.: "Com ou sem pontuação." |
| Motivo | "Referência do caso" — ajuda: "Número do incidente ou chamado (ex.: INC-1234)." |
| Erros | "Informe um CPF com 11 dígitos." · "Informe um CNPJ com 14 caracteres." · "Informe o telefone com DDD." · "Informe um e-mail válido." · "Informe o login." · "Informe a referência do caso." |
| Botões | "Gerar consulta" · "Copiar consulta" · "Nova pesquisa" |

**Acessibilidade e prevenção de erro**: labels associados, erros com `aria-describedby` e `role="alert"`; valor com
`autocomplete="off"`, sem guardar em histórico/estado global; o valor nunca vai para URL, `localStorage` nem
`AppLogger`. Ordem de tabulação: tipo → valor → referência → botão. Tela interna (sem SEO).

**Matriz**: mobile (formulário em coluna, consulta com quebra de linha e rolagem horizontal no bloco de código),
tablet e desktop (formulário à esquerda, resultado à direita a partir de 1024px).

## 4. Regras de negócio

1. Formatos de máscara: ADR-0002. Token, domínios, canônico e chaves: ADR-0003.
2. E-mail e login geram o mesmo token (domínio `login`).
3. A referência do caso é obrigatória: 3 a 40 caracteres `[A-Za-z0-9._/-]`, e passa pelo mascarador antes de ser
   registrada.
4. Limite: 30 pesquisas por investigador por hora.
5. A consulta cobre todos os nomes de campo do tipo (mesmas listas `LGPD_*_FIELDS`) e todas as chaves configuradas.
6. Celular sem DDD em texto livre: fora do escopo (ADR-0003, item 9).

## 5. Requisitos não funcionais

- **LGPD**: logs continuam dado pessoal (pseudonimizado); retenção de 30 dias mantida.
- **Segurança**: chave de 256 bits fora do repositório; OTP para a role; antiforgery; Problem Details sem eco do valor.
- **Desempenho**: enricher com custo < 50 µs por evento com dado pessoal (HMAC em memória, sem I/O).
- **Compatibilidade**: nomes de campo atuais preservados (só soma `*_token`); dashboards e streams sem mudança.

## 6. Fora de escopo

- Token no Keycloak (auditoria segue com ids técnicos e `masked_login` do ADR-0007 do keycloak).
- Reprocessar logs antigos para gerar token.
- Pesquisa direto dentro do Graylog (plugin, decorator ou lookup table).
- Cofre corporativo (a spec usa variável de ambiente/user-secrets; o cofre de produção é escolha da infraestrutura).

## 7. Premissas

- O debugger termina as correções em andamento em `provision.sh`, `smoke-test.sh` e regras antes da onda que toca o
  graylog.
- O Cadastro passa a enviar logs ao Graylog nesta spec (pré-requisito da auditoria).
- Retenção do stream de auditoria: mesma do índice do Cadastro (30 dias) até decisão em contrário (pergunta aberta).
