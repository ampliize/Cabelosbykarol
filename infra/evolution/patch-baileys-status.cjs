// Remendo do Baileys 7.0.0-rc.9 (Evolution API v2.3.7): o WhatsApp passou a entregar stories como um
// nó <status> solto. O Baileys não tem tratamento para ele, nunca confirma o recebimento (ack) e o
// servidor do WhatsApp segura todas as mensagens novas da sessão. ~50 min depois derruba a conexão
// ("Stream Errored (ack)"), a Evolution reconecta, recebe o mesmo <status> e o ciclo recomeça —
// as mensagens chegam em lotes, com atraso cada vez maior.
// Correção igual à proposta oficial (Baileys PR #2883 / Evolution PR #2785, ainda não lançadas):
//   1. confirma (ack) o <status> sem processar o conteúdo;
//   2. trata <status> também na fila de mensagens offline;
//   3. um erro numa mensagem da fila offline não trava mais a fila inteira.
// Falha o build se o arquivo não for exatamente o esperado (assim nunca aplica remendo errado).
'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const VERSAO = '7.0.0-rc.9';
const MARCA = '[cbk-patch-status]';

function arquivos() {
  if (process.env.BAILEYS_FILE) return [process.env.BAILEYS_FILE];
  const out = execSync("find / -path /proc -prune -o -path '*/node_modules/baileys/lib/Socket/messages-recv.js' -print 2>/dev/null || true").toString().trim();
  return out ? out.split('\n') : [];
}

function trocar(src, de, para, nome) {
  const n = src.split(de).length - 1;
  if (n !== 1) throw new Error(`trecho "${nome}" encontrado ${n} vezes (esperado 1)`);
  return src.replace(de, para);
}

const lista = arquivos();
if (!lista.length) throw new Error('messages-recv.js do Baileys não encontrado');
for (const f of lista) {
  const pkg = JSON.parse(fs.readFileSync(path.join(f, '..', '..', '..', 'package.json'), 'utf8'));
  if (pkg.version !== VERSAO) throw new Error(`${f}: Baileys ${pkg.version}, remendo feito para ${VERSAO}`);
  let src = fs.readFileSync(f, 'utf8');
  if (src.includes(MARCA)) { console.log('já remendado:', f); continue; }

  src = trocar(src,
    '    const makeOfflineNodeProcessor = () => {\n',
    `    // ${MARCA} confirma o <status> (stories) para o WhatsApp não segurar as mensagens da sessão
    const handleStatus = async (node) => {
        try {
            await sendMessageAck(node);
        }
        catch (err) {
            onUnexpectedError(err, 'acking status');
        }
    };
    const makeOfflineNodeProcessor = () => {\n`, 'makeOfflineNodeProcessor');

  src = trocar(src,
    "            ['notification', handleNotification]\n        ]);",
    "            ['notification', handleNotification],\n            ['status', handleStatus]\n        ]);", 'nodeProcessorMap');

  src = trocar(src,
    '                    await nodeProcessor(node);\n',
    `                    try {
                        await nodeProcessor(node);
                    }
                    catch (err) {
                        onUnexpectedError(err, 'processing offline node');
                    }\n`, 'nodeProcessor');

  src = trocar(src,
    "    ws.on('CB:ack,class:message', (node) => {\n",
    `    ws.on('CB:status', async (node) => {
        await processNode('status', node, 'acking status', handleStatus);
    });
    ws.on('CB:ack,class:message', (node) => {\n`, 'CB:ack');

  fs.writeFileSync(f + '.orig', fs.readFileSync(f));
  fs.writeFileSync(f, src);
  execSync(`node --check "${f}"`, { stdio: 'inherit' });
  console.log('remendado:', f);
}
