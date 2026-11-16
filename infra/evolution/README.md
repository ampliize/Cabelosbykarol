# Evolution API — correção do atraso nas mensagens

## O problema (diagnosticado em 13 e 16/11/2026)
A instância aparece **conectada**, mas as mensagens chegam em **lotes a cada ~50 min**, com atraso
crescente (3 h, 24 h…). A causa é um bug do Baileys 7.0.0-rc.9, que vem dentro da Evolution v2.3.7:
- o WhatsApp passou a enviar stories de alguns contatos como um aviso `<status>` solto;
- o Baileys não confirma esse aviso (ack), e o servidor do WhatsApp segura todas as mensagens novas;
- ~50 min depois o WhatsApp derruba a conexão (`Stream Errored (ack)`), a Evolution reconecta,
  recebe o mesmo `<status>` e o ciclo recomeça.

Reiniciar ou ler o QR de novo só resolve por algumas horas. Relatos e correção proposta:
- https://github.com/evolution-foundation/evolution-api/issues/2778
- https://github.com/evolution-foundation/evolution-api/pull/2785 (ainda não lançado)
- https://github.com/WhiskeySockets/Baileys/issues/2858 e PR #2883 (ainda não lançado)

## A correção
`Dockerfile` = imagem oficial `evoapicloud/evolution-api:v2.3.7` + o remendo
`patch-baileys-status.cjs` (embutido em base64). O remendo:
1. confirma (ack) o `<status>` sem processar o conteúdo;
2. trata `<status>` também na fila de mensagens offline;
3. impede que um erro numa mensagem da fila offline trave a fila inteira.

O build **falha** se a imagem não tiver exatamente o Baileys 7.0.0-rc.9 e os trechos esperados.
Assim um remendo errado nunca vai para produção. Testado em 16/11: a imagem monta, o Baileys
carrega e o remendo está presente em `/evolution/node_modules/baileys/lib/Socket/messages-recv.js`.

## Como aplicar no Easypanel
1. Abra o projeto > serviço da **Evolution** > **Source**.
2. Troque de "Docker Image" para **Dockerfile** e cole o conteúdo inteiro de `Dockerfile`.
3. Não mexa em variáveis de ambiente, volumes nem domínio. Clique em **Deploy**.
4. Em **Deployments/Logs**, confira a linha `remendado: /evolution/node_modules/baileys/...`.
5. Confira que existe **um só** serviço da Evolution, com **1 réplica**.
6. Se a instância ficar desconectada, conecte pelo card WhatsApp do CRM (QR Code).

Para conferir que resolveu: por algumas horas, os logs não devem ter `stream errored out` com
`ack class="status"`, e as mensagens devem aparecer no CRM na hora.

## Cuidados
- **Não use a tag `latest`**: desde 06/05/2026 ela aponta para a 2.4.0-rc1, versão de teste que
  exige ativação de licença (a API responde 503 `LICENSE_REQUIRED` sem ela).
- Quando sair uma versão oficial com a correção (2.3.8 ou posterior), volte para a imagem oficial
  e remova este Dockerfile. Se a nova versão não tiver o Baileys rc.9, o build deste Dockerfile
  falha de propósito.
- Para desfazer: volte o Source para Docker Image `evoapicloud/evolution-api:v2.3.7` e faça Deploy.
