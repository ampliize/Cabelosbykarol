-- Base de conhecimento reescrita com as respostas do salão (22/11/2026, docs/16-PERGUNTAS-BASE-CONHECIMENTO.md).
-- Regra de ouro: a IA NÃO VENDE cabelo/alongamento — explica, convida para a avaliação gratuita e agenda;
-- foto, preço específico, compra de cabelo ou fechar → transfere.
-- Itens existentes são atualizados (mesmo id); itens novos entram como aprovados.

-- ---------------------------------------------------------------- itens existentes corrigidos
update public.kb_itens set resposta = 'Para agendar não pedimos sinal em nenhum serviço: o pagamento é no salão, no dia. A única exceção é o alongamento capilar: depois da avaliação, quando a cliente escolhe o cabelo e fecha, é pedida uma entrada de 30% do valor do cabelo. ORIENTAÇÃO: você não fecha alongamento; se ela quiser fechar ou pagar a entrada, transfira (fora_escopo) sem responder.', atualizado_em = now() where id = 6;
update public.kb_itens set resposta = 'Não precisa pagar nada antes: o pagamento é no salão, no dia (PIX, dinheiro ou cartão). Só o alongamento capilar tem entrada de 30% do valor do cabelo para fechar, depois da avaliação.', atualizado_em = now() where id = 38;
update public.kb_itens set resposta = 'Aceitamos PIX, dinheiro e cartão. No cartão de crédito dá para parcelar em até 10x sem juros, em todos os serviços.', atualizado_em = now() where id in (5, 36);
update public.kb_itens set resposta = 'Parcelamos em até 10x sem juros, somente no cartão de crédito, em todos os serviços.', atualizado_em = now() where id = 37;
update public.kb_itens set resposta = 'ORIENTAÇÃO: é negociação. Use transferir_para_humano (motivo negociacao) e não escreva nada para a cliente. Não fale de desconto nem de percentual.', atualizado_em = now() where id = 27;
update public.kb_itens set pergunta = 'Precisa de teste de mecha? Luzes, descoloração, coloração ou selagem precisam de teste?',
  resposta = 'O teste de mecha é obrigatório só para luzes e descoloração. O ideal é fazer 2 dias antes do serviço; leva em média 40 minutos e é gratuito. Só fazemos no mesmo dia se a cliente realmente não puder vir antes.', atualizado_em = now() where id = 10;
update public.kb_itens set resposta = 'Sim. O alongamento começa com uma avaliação presencial gratuita e sem compromisso, de 20 a 30 minutos, com a Karol (ou com a Emilly quando a Karol não estiver no salão). Não precisa ir com o cabelo lavado. Na avaliação vemos a técnica ideal, a cor, o comprimento e a quantidade de cabelo.', atualizado_em = now() where id = 9;
update public.kb_itens set resposta = 'Em dezembro o salão não abre nos dias 01/12, 02/12, 08/12 e 25/12. ORIENTAÇÃO: para outros feriados ou datas de fim de ano, transfira (incerteza) sem responder.', atualizado_em = now() where id = 43;
update public.kb_itens set resposta = 'Atendemos crianças, sem idade mínima, desde que venham com um responsável.', atualizado_em = now() where id = 50;
update public.kb_itens set resposta = 'Para química durante a gestação (selagem/progressiva, coloração, luzes) pedimos a liberação do médico. ORIENTAÇÃO: diga isso com carinho e ofereça agendar quando ela tiver a liberação.', atualizado_em = now() where id = 52;
update public.kb_itens set resposta = 'Fazemos penteado, maquiagem e produções para festa. Não temos estrutura para dia de noiva e não atendemos a domicílio. ORIENTAÇÃO: use consultar_servicos para preço e horário; se ela quiser pacote, transfira (negociacao) sem responder.', atualizado_em = now() where id = 47;
update public.kb_itens set resposta = 'ORIENTAÇÃO: sem pressão. Ex.: "tranquilo! se quiser já deixo seu horário reservado e, se mudar de ideia, é só avisar que a gente desmarca, sem custo nenhum". Para agendar não pedimos sinal.', atualizado_em = now() where id = 28;
update public.kb_itens set resposta = 'ORIENTAÇÃO: respeite, sem falar mal de ninguém. Convide com leveza: "se quiser conhecer, vai ser um prazer te receber". Para luzes e descoloração o teste de mecha é gratuito; para alongamento, a avaliação é gratuita.', atualizado_em = now() where id = 31;
update public.kb_itens set resposta = 'ORIENTAÇÃO: acolha. Explique que o salão faz antes, de graça, o teste de mecha (luzes e descoloração) ou a avaliação (alongamento), justamente para ver se é seguro. Ofereça agendar.', atualizado_em = now() where id = 32;
update public.kb_itens set resposta = 'Não temos estacionamento próprio nem conveniado; o estacionamento é na rua.', atualizado_em = now() where id = 4;
update public.kb_itens set resposta = 'A tolerância é de 15 minutos, para todos os serviços, inclusive os mais longos. Se o atraso passar de 20 minutos e não conseguirmos falar com você, o agendamento é cancelado. Na avaliação essa regra não se aplica.', atualizado_em = now() where id = 8;
update public.kb_itens set resposta = 'A tolerância é de 15 minutos para todos os serviços (na avaliação essa regra não se aplica); se passar de 20 minutos e não conseguirmos falar com você, o horário é cancelado. ORIENTAÇÃO: tranquilize e, se for resposta a lembrete, registrar_retorno_lembrete (atraso).', atualizado_em = now() where id = 42;
update public.kb_itens set resposta = 'ORIENTAÇÃO: na dúvida, ir com o cabelo limpo e seco, sem creme ou óleo, ajuda; para a avaliação de alongamento não precisa lavar. Para química, a profissional orienta no teste de mecha. Se ela quiser algo específico que você não sabe, transferir_para_humano (incerteza), sem escrever nada.', atualizado_em = now() where id = 54;

-- ---------------------------------------------------------------- itens novos
insert into public.kb_itens (categoria, pergunta, resposta, palavras_chave, fonte, aprovado, ativo) values
-- alongamento
('servico', 'Quanto custa o mega hair / alongamento capilar? Qual o valor? Como funciona?',
 E'✨ Seu cabelo dos sonhos começa com uma avaliação personalizada! ✨\n\nNosso serviço de alongamento capilar (Mega Hair) é totalmente personalizado, respeitando as características e necessidades de cada cliente. 💕\n\nOferecemos uma avaliação gratuita e sem compromisso, na qual analisamos seu cabelo para indicar a técnica ideal, além de definir a cor, o comprimento e o volume perfeitos para você.\n\n✨ Nossos diferenciais:\n\n✔️ Cabelos 100% humanos, selecionados e personalizados exclusivamente para você.\n\n✔️ Técnicas exclusivas, com pontos de aplicação impermeáveis à água, proporcionando mais conforto, segurança e durabilidade.\n\n✔️ Peças a partir de R$ 2.500,00.\n\n✔️ Parcelamento em até 10x sem juros.\n\n💖 Nosso objetivo é proporcionar um resultado natural, sofisticado e harmonioso, valorizando ainda mais a sua beleza!\n\n📅 Que tal agendarmos sua avaliação gratuita? Será um prazer receber você e encontrar a melhor opção para transformar seus cabelos! ✨\n\nORIENTAÇÃO: mande este texto igual (é o texto oficial do salão), uma vez, quando ela perguntar de alongamento/mega hair/valor pela primeira vez. Depois disso, se ela pedir preço específico, foto de cabelo, quiser comprar o cabelo ou fechar, transfira (fora_escopo) sem responder.',
 array['mega','mega hair','megahair','alongamento','aplique','extensao','valor','preco','quanto custa'], 'cliente', true, true),
('servico', 'Quais técnicas/métodos de alongamento vocês fazem? Qual a diferença entre elas? Qual a melhor?',
 'Trabalhamos com Invisible Bio Adesivo (fita) e Nano Inject (nossa técnica exclusiva), com manutenção a cada 30 a 60 dias e cerca de 1h30 de atendimento; Biolink, com manutenção a cada 60 a 90 dias e cerca de 1h30; Nanoponto e Micro cápsula de queratina, com manutenção a cada 60 a 90 dias e cerca de 4h; e Tic Tac. Os pontos de aplicação são impermeáveis à água. A técnica ideal para cada cliente é indicada na avaliação gratuita. ORIENTAÇÃO: explique de forma simples só o que ela perguntou e convide para a avaliação.',
 array['tecnica','metodo','fita','invisible','bio adesivo','nano inject','biolink','nanoponto','microcapsula','queratina','tic tac','diferenca'], 'cliente', true, true),
('servico', 'Que cabelo vocês usam? É humano? Tem de que tamanho e de que cor? Quantas gramas?',
 'Sempre 100% humano e brasileiro, do Sul ou regional. Trabalhamos a partir de 40 cm (dá para adaptar se ela preferir menor). A cor é personalizada: ela escolhe o cabelo e a gente personaliza no tom do cabelo dela ou no tom que ela desejar. A quantidade de gramas ideal só conseguimos definir na avaliação presencial.',
 array['cabelo humano','tamanho','comprimento','cm','cor','tom','gramas','loiro','castanho','brasileiro'], 'cliente', true, true),
('servico', 'Vocês vendem cabelo? Quero comprar só o cabelo / cabelo avulso / tem cabelo de 60, 70 cm?',
 'ORIENTAÇÃO: vendemos, mas você não vende cabelo e os valores só são passados na avaliação. Transfira (fora_escopo) sem responder.',
 array['vender cabelo','comprar cabelo','cabelo avulso','so o cabelo','estoque'], 'cliente', true, true),
('servico', 'Quero fechar o alongamento / comprar / fazer o pagamento da entrada / mandar foto do cabelo que quero',
 'ORIENTAÇÃO: você não vende alongamento. Transfira sem responder: pagamento ou fechamento (fora_escopo); foto (orcamento_visual).',
 array['fechar','comprar','entrada','pagamento','foto','quero fechar'], 'cliente', true, true),
('servico', 'Em quanto tempo o cabelo fica pronto? Qual o prazo para aplicar?',
 'Pedimos 2 dias para preparar o cabelo depois que o alongamento é fechado.',
 array['prazo','quanto tempo','pronto','preparar','confeccao'], 'cliente', true, true),
('servico', 'Fazem manutenção em alongamento colocado em outro salão? Aproveitam o meu cabelo? Quanto custa refazer a fita?',
 'Fazemos sim, se for de uma das técnicas que trabalhamos. Na manutenção usamos o cabelo que ela já tem. Se precisar refazer a confecção, depende da técnica: Nano Inject R$ 5 por grama, Biolink R$ 4 por grama, Tic Tac R$ 4 por grama e Nanoponto R$ 3 por grama. Na micro cápsula de queratina a confecção já está inclusa na manutenção (R$ 470 até 200 g).',
 array['outro salao','outra profissional','meu cabelo','refazer','fita','confeccao','por grama'], 'cliente', true, true),
('servico', 'Quanto custa a manutenção do alongamento? O que está incluso? De quanto em quanto tempo? Quanto tempo demora?',
 'A manutenção do bio adesivo é R$ 370 até 200 g de cabelo, já com retirada, higienização e escova do alongamento, lavagem e escova do seu cabelo. A da micro cápsula de queratina é R$ 470 até 200 g, com a confecção inclusa. Intervalo: Invisible e Nano Inject a cada 30 a 60 dias; Biolink, Nanoponto e Micro cápsula a cada 60 a 90 dias. Duração: cerca de 1h30 (Invisible, Nano Inject, Biolink) ou 4h (Nanoponto e Micro cápsula), dependendo da quantidade de cabelo. ORIENTAÇÃO: para outras técnicas use consultar_servicos; se ela tiver mais de 200 g de cabelo, transfira (fora_escopo) sem responder.',
 array['manutencao','incluso','inclui','intervalo','quanto tempo','200g','gramas'], 'cliente', true, true),
('servico', 'Quanto custa a retirada do alongamento? Retiram de outro salão?',
 'Se ela não for aplicar de novo: Nano Inject, Invisible e Biolink R$ 120; Nanoponto e Micro cápsula de queratina R$ 200. Se ela retirar num dia para aplicar em outro (por exemplo, para fazer selagem ou coloração em outro lugar), cobramos R$ 70 no dia da retirada e o valor da manutenção no dia da aplicação. Retiramos alongamento de outro salão se for de uma técnica que trabalhamos.',
 array['retirada','retirar','tirar','remover'], 'cliente', true, true),
('servico', 'Quero trocar de método / trocar de técnica. Quanto custa?',
 'Depende da técnica escolhida. Confecção: Nano Inject R$ 5 por grama, Biolink R$ 4 por grama, Nanoponto R$ 3 por grama; na Micro cápsula de queratina a confecção já está inclusa na manutenção (R$ 470 até 200 g). ORIENTAÇÃO: indique a avaliação gratuita para definir a técnica.',
 array['trocar metodo','troca de metodo','trocar tecnica','mudar tecnica'], 'cliente', true, true),
('servico', 'Quanto tempo dura o alongamento? Tem garantia? A fita soltou / caiu',
 'O cabelo dura em média de 1 a 2 anos, dependendo dos cuidados. Se uma fita cair ou soltar até 45 dias depois da manutenção, ela pode vir recolocar. Depois de 45 dias, o ideal é fazer a manutenção; se ela não quiser, a recolocação custa R$ 5 por centímetro de fita. Dica: escovar ajuda a fita a fixar no cabelo. ORIENTAÇÃO: para recolocação, siga o fluxo normal de agendamento.',
 array['dura','durabilidade','garantia','fita caiu','soltou','caindo','recolocar'], 'cliente', true, true),
('servico', 'Posso mandar foto para saber o valor do alongamento / ter uma base de preço?',
 'ORIENTAÇÃO: não peça foto. Indique primeiro a avaliação presencial gratuita. Se ela insistir em uma base de valor pelo WhatsApp ou mandar foto, transfira (orcamento_visual) sem responder.',
 array['foto','mandar foto','base de valor','orcamento'], 'cliente', true, true),
('servico', 'Quanto custa preenchimento?',
 'O preenchimento é feito com alongamento capilar e precisa de avaliação para passar o orçamento. ORIENTAÇÃO: ofereça a avaliação gratuita.',
 array['preenchimento','preencher','volume'], 'cliente', true, true),
('servico', 'Como cuidar do alongamento? Como lavar, secar, dormir, ir à praia ou piscina?',
 'Temos um guia com todos os cuidados (lavagem, secagem, hidratação, escovação, como dormir, praia e piscina): https://canva.link/qzyhkcc5mn4lzdy',
 array['cuidados','lavar','secar','dormir','praia','piscina','guia'], 'cliente', true, true),
-- química e tratamentos
('servico', 'Quanto custa luzes / coloração / descoloração?',
 'Luzes, descoloração e coloração fora da cor natural precisam de avaliação ou teste de mecha. Nas luzes, o valor de tabela é só das luzes; os tratamentos pré e pós-química, quando necessários, são à parte. O teste de mecha mostra a resistência do cabelo e se chega no tom que ela quer. ORIENTAÇÃO: pode dizer o valor de tabela das luzes como "a partir de" (consultar_servicos), explicando que tratamentos são à parte, e ofereça o teste de mecha.',
 array['luzes','mechas','coloracao','descoloracao','tintura','cor','loiro'], 'cliente', true, true),
('servico', 'Quanto custa a selagem / progressiva? Quais selagens vocês têm?',
 'Selagem orgânica 4D Smith: raiz R$ 280, da raiz às pontas R$ 330. Selagem London: raiz R$ 300, da raiz às pontas R$ 350. Selagem com formol: raiz R$ 250, da raiz às pontas R$ 300. Liso Perfeito: R$ 340.',
 array['selagem','progressiva','alisamento','liso perfeito','formol','organica','smith','london'], 'cliente', true, true),
('servico', 'Fazem botox capilar?',
 'O botox tem o mesmo resultado da selagem orgânica, que é o que indicamos: London (raiz R$ 300, da raiz às pontas R$ 350) ou 4D Smith (raiz R$ 280, da raiz às pontas R$ 330).',
 array['botox','btx'], 'cliente', true, true),
('servico', 'Terapia capilar / queda de cabelo / tratamento do couro cabeludo / microagulhamento / fotobiomodelação',
 'A terapia capilar é feita pela Patrícia, com uma avaliação antes para ver qual procedimento é indicado. Valores por sessão: fotobiomodelação R$ 250 (cronograma de 4 sessões), blend de óleos + eletroterapia R$ 250 (2 sessões) e microagulhamento R$ 350 (4 sessões). ORIENTAÇÃO: ofereça a avaliação com a Patrícia.',
 array['terapia capilar','queda','couro cabeludo','microagulhamento','fotobiomodelacao','eletroterapia','tricologia'], 'cliente', true, true),
-- unhas, estética, produtos
('servico', 'Quanto custa manicure / pedicure / esmaltação em gel / alongamento de unha?',
 'Manicure tradicional R$ 35, pedicure tradicional R$ 35, esmaltação em gel R$ 90 e aplicação de alongamento de unha R$ 180.',
 array['manicure','pedicure','unha','gel','esmaltacao','alongamento de unha','pe e mao'], 'cliente', true, true),
('servico', 'Manutenção do alongamento de unha: quanto custa e de quanto em quanto tempo?',
 'A manutenção é em média a cada 25 dias: até 25 dias R$ 110; depois de 25 dias R$ 130; alongamento feito por outra profissional R$ 130.',
 array['manutencao unha','alongamento de unha','unha gel','fibra'], 'cliente', true, true),
('servico', 'Com quantos dias de antecedência preciso marcar?',
 'Não dá para prever, a agenda varia bastante. ORIENTAÇÃO: consulte consultar_horarios e ofereça os horários livres.',
 array['antecedencia','quantos dias antes','marcar antes'], 'cliente', true, true),
('servico', 'Vocês vendem produtos? Shampoo, máscara, óleo, perfume?',
 'Vendemos produtos para cabelo e perfume para o corpo. ORIENTAÇÃO: se você souber exatamente o produto e o valor, pode informar; se não, transfira (incerteza) sem responder.',
 array['produto','shampoo','mascara','oleo','perfume','vende','ml'], 'cliente', true, true),
-- regras e pedidos
('politica', 'Faltei sem avisar, tem multa ou cobrança?',
 'Não, não há cobrança. ORIENTAÇÃO: acolha e ofereça remarcar.',
 array['faltei','falta','multa','cobranca','nao fui'], 'cliente', true, true),
('politica', 'Posso levar acompanhante? Posso levar meu filho? Posso levar meu pet / cachorro?',
 'Pode sim levar acompanhante. Pet também, desde que não seja agressivo.',
 array['acompanhante','levar','filho','pet','cachorro','animal'], 'cliente', true, true),
('politica', 'Tem lista de espera? Me avisa se abrir vaga',
 'Temos lista de espera. ORIENTAÇÃO: quando não houver vaga no dia que ela quer, ofereça a lista de espera; se ela aceitar, transfira (agenda) com o serviço e o dia desejados, sem responder.',
 array['lista de espera','abrir vaga','desistencia','encaixe'], 'cliente', true, true),
('politica', 'Tem vale-presente / gift card / pacote?',
 'Não trabalhamos com vale-presente. ORIENTAÇÃO: pacote é negociação; transfira (negociacao) sem responder.',
 array['vale presente','gift card','presente','pacote'], 'cliente', true, true),
('politica', 'Paguei a entrada e quero cancelar / desistir. Devolve?',
 'ORIENTAÇÃO: precisa ser avaliado pela Karol. Transfira (fora_escopo) sem responder.',
 array['devolver','reembolso','desistir','cancelar entrada','estorno'], 'cliente', true, true),
('politica', 'Preciso de nota fiscal / recibo',
 'Pode pedir sim. ORIENTAÇÃO: transfira (fora_escopo) sem responder; a equipe envia pelo WhatsApp do salão.',
 array['nota fiscal','recibo','nf','comprovante de pagamento'], 'cliente', true, true),
('geral', 'Me manda as fotos de antes e depois / as fotos que tiraram',
 'ORIENTAÇÃO: transfira (pedido_cliente) sem responder; a recepção envia as fotos.',
 array['fotos','antes e depois','foto do resultado'], 'cliente', true, true),
('geral', 'Qual o Instagram do salão? E da profissional?',
 'Nosso Instagram é @cabelosbykarolfonseca. ORIENTAÇÃO: se ela pedir o Instagram de uma profissional, transfira (pedido_cliente) sem responder.',
 array['instagram','insta','@','perfil'], 'cliente', true, true),
('geral', 'Mensagem com código de atendimento (ex.: "meu atendimento é 201289")',
 'ORIENTAÇÃO: o código indica que a cliente veio pelo link do Instagram. Atenda normalmente, sem comentar o código.',
 array['atendimento e','codigo','201289','vim pelo instagram','link'], 'cliente', true, true),
('geral', 'Currículo, vaga de emprego, curso, fornecedor, parceria, influenciadora',
 'ORIENTAÇÃO: transfira (fora_escopo) sem responder.',
 array['curriculo','vaga','emprego','trabalhar','curso','fornecedor','parceria','influenciadora','permuta'], 'cliente', true, true),
('geral', 'Mandei foto pedindo orçamento de cor / tom / mechas',
 'ORIENTAÇÃO: orçamento por foto sempre vai para a equipe. Transfira (orcamento_visual) sem responder.',
 array['foto','orcamento','tom','cor da foto','referencia'], 'cliente', true, true);
