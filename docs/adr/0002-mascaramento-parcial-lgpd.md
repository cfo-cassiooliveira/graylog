# ADR-0002: Mascaramento parcial de dados pessoais na gravação dos logs

- **Status**: Aceito
- **Data**: 2026-11-14
- **Decisores**: Cassio Oliveira (responsável técnico)
- **Artigos da Constituição relacionados**: Art. IV.1 (LGPD), Art. IV.6 (dados pessoais), Art. VI.1 (logs no Graylog)

## Contexto

O pipeline mascarava e-mail e CPF só no campo `message`, trocando tudo por `***@***` e `***.***.***-**`. Três
problemas:

- O sink Serilog também envia `full_message` (o mesmo texto) e os campos da exceção (`ExceptionMessage`,
  `StackTrace`), e esses campos eram indexados sem máscara. Exceções de banco costumam trazer o valor
  (`duplicate key value is (...)`).
- Telefone, CNPJ e campos de login não eram tratados.
- A máscara total não deixa a operação reconhecer o titular ao investigar um incidente.

## Decisão

1. **Máscara aplicada na gravação**, no pipeline, antes da indexação. O valor original nunca chega ao OpenSearch.
2. **Formatos**:

   | Dado | Exemplo | Gravado como | Regra |
   |---|---|---|---|
   | E-mail | `ana.souza@gmail.com` | `ana***@gmail` | Até 3 caracteres (1 se tiver até 3) + `@` + primeiro rótulo do domínio; também `%40` (ADR-0007 do keycloak) |
   | Login (campos conhecidos) | `Maria.Silva` | `mar***` | Mesma regra, em minúsculas |
   | CPF | `123.456.789-09` ou `12345678909` | `***.456.789-**` | Padrão do governo federal: oculta os 3 primeiros e os 2 dígitos verificadores |
   | CNPJ formatado (numérico ou alfanumérico) | `12.345.678/0001-90` | `12.3**.***/***1-90` | 3 primeiros e 3 últimos |
   | Celular | `(11) 98765-4321` | `11*****4321` | DDD e 4 últimos |

3. **Regra para quem envia log: dado pessoal só como campo estruturado.** Quando for inevitável logar um dado
   pessoal, ele vai num campo com o nome do tipo, nunca concatenado no texto. No Serilog, isso é o message template
   `"... CPF {Cpf}"`: o valor vai no campo `Cpf` e no texto renderizado.

   | Tipo | Nomes de campo aceitos (listas do `provision.sh`) |
   |---|---|
   | CPF | `cpf`, `Cpf`, `CPF` (`LGPD_CPF_FIELDS`) |
   | CNPJ | `cnpj`, `Cnpj`, `CNPJ` (`LGPD_CNPJ_FIELDS`) |
   | Telefone (celular ou fixo) | `phone`, `Phone`, `mobilePhone`, `MobilePhone`, `mobile_phone`, `celular`, `telefone`... (`LGPD_PHONE_FIELDS`) |
   | Login ou e-mail | `username`, `UserName`, `login`, `preferred_username`, `email`, `Email`... (`LGPD_LOGIN_FIELDS`) |

4. **Duas camadas no pipeline**, geradas pelo `provision.sh` a partir dos modelos em `provisioning/rules/templates/`,
   uma regra por campo:
   - **Estágio 3, pelo campo.** O nome do campo diz o tipo, então nada é adivinhado. O campo é mascarado, e o mesmo
     valor é trocado pela máscara em todos os textos, como palavra inteira. Por isso `11987654321` num campo `Phone`
     vira `11*****4321`. Valor fora do formato do tipo vira `***`, para nunca ficar em claro.
   - **Estágio 4, pelo formato (rede de segurança).** O que vazou sem campo é reconhecido pelo formato nos textos
     (`LGPD_TEXT_FIELDS`: `message`, `full_message`, `ExceptionMessage`, `StackTrace`, `http_path`...). Aqui há
     ambiguidade: 11 dígitos sem pontuação podem ser CPF ou celular, e são mascarados como CPF, a máscara que esconde
     mais.
5. **Fora do escopo**: endereço, cidade/estado, telefone fixo e CNPJ sem pontuação (14 dígitos se confundem com
   timestamps `yyyyMMddHHmmss`; CNPJ de empresa, em geral, não é dado pessoal).

## Alternativas consideradas

| Alternativa | Prós | Contras | Motivo da rejeição |
|---|---|---|---|
| Gravar completo e mascarar só na exibição (decorators) | Valor completo disponível para investigação | O índice guarda o dado em claro: vazamento, backup e acesso direto ao OpenSearch expõem tudo. A busca por um CPF revela se ele está nos logs. Decorators não valem em widgets, exportação CSV nem notificações | Contra necessidade e segurança (LGPD, art. 6º, III e VII) |
| CPF com 3 primeiros e 3 últimos | Reconhecível | Os 2 últimos são dígitos verificadores: sobram ~1.000 candidatos. Cruzado com o padrão público `***.456.789-**`, revela o CPF inteiro | Inseguro |
| Celular com DDD + 5 primeiros (`1198765****`) | Reconhecível | Mostra 7 de 11 dígitos, além de operadora e região | O final (`4321`) é o que o titular reconhece, e o formato esconde um dígito a mais |
| Máscara total (`***@***`) | Zero dado pessoal | Impossível reconhecer o titular numa investigação | Menos útil; o parcial atende à minimização |
| Só reconhecimento por formato nos textos | Nada muda nos sistemas | Adivinha o tipo: celular sem pontuação vira CPF, login não é reconhecido | Fica só como rede de segurança |
| Ler rótulos no texto (`CPF: 123...`) | Resolve parte da ambiguidade | O rótulo depende de quem escreveu (idioma, grafia) e falta na maioria dos textos | O campo estruturado resolve com garantia |
| Hash com chave (HMAC) junto do valor mascarado | Permite achar todos os logs de uma pessoa | Chave a gerir | Adiado: sem necessidade atual. Pode ser somado depois sem mudar este formato |

## Consequências

- **Positivas**:
  - Nenhum valor completo é indexado nos campos tratados, inclusive os da exceção.
  - O formato é um só, alinhado ao Keycloak, e o titular continua reconhecível.
- **Negativas / riscos**:
  - Dado pseudonimizado continua sendo dado pessoal. Retenção de 30 dias e acesso restrito ao Graylog continuam
    obrigatórios.
  - O reconhecimento é por padrão de texto: campos fora das listas e formatos não previstos passam. Por isso a
    origem continua proibida de logar dados pessoais (Art. IV.6); o Graylog é a rede de segurança, não a única
    proteção.
  - As APIs do Legado e do Cadastro já mascaram como `***@***` antes de enviar, o que é mais restritivo. Os formatos
    convivem até essas APIs serem alinhadas.
- **Ações decorrentes**:
  - O smoke test confere cada formato, cada camada e cada campo.
  - Nome de campo novo entra na lista `LGPD_*` do seu tipo.
  - A regra do campo estruturado está no CLAUDE.md do legado, do cadastro e do keycloak e no código que envia ao
    Graylog (`LoggingSetup` do legado, `GelfMessageFactory` do keycloak).
