-- Teste de fumaça dos fluxos do banco (dados fictícios 5511900000xxx, apagados no final).
-- Rodar inteiro no SQL Editor do Supabase. Resultado: uma linha por verificação com ok = true/false.

create temp table r (n serial, teste text, resultado jsonb, esperado text, ok boolean);

-- 1. Normalização de telefone
insert into r (teste, resultado, esperado) values
 ('tel_e164',     to_jsonb(public.normalizar_telefone('5511987654321')),               '"5511987654321"'),
 ('tel_mascara',  to_jsonb(public.normalizar_telefone('(11) 98765-4321')),             '"5511987654321"'),
 ('tel_sem_9',    to_jsonb(public.normalizar_telefone('551187654321')),                '"5511987654321"'),
 ('tel_jid',      to_jsonb(public.normalizar_telefone('5511987654321:12@s.whatsapp.net')), '"5511987654321"'),
 ('tel_fixo',     to_jsonb(public.normalizar_telefone('554733445566')),                '"554733445566"'),
 ('tel_exterior', coalesce(to_jsonb(public.normalizar_telefone('14155550100')), 'null'), 'null');

-- 2. Modo piloto bloqueia número fora da whitelist
insert into r (teste, resultado, esperado)
select 'piloto_bloqueia', public.registrar_mensagem_entrada('T-0', '5511900000001', false, 'text', 'oi', null, 'Teste'), 'fora_do_piloto';

update public.config_bot set valor = '["5511900000001"]' where chave = 'whitelist_piloto';

-- 3. Rajada de 2 mensagens: só a última execução processa o lote
insert into r (teste, resultado, esperado)
select 'rajada_1', public.registrar_mensagem_entrada('T-1', '5511900000001', false, 'text', 'Quero fazer progressiva', null, 'Teste'), 'processar';
insert into r (teste, resultado, esperado)
select 'rajada_2', public.registrar_mensagem_entrada('T-2', '11900000001', false, 'text', 'com a mesma moça', null, 'Teste'), 'processar';
insert into r (teste, resultado, esperado)
select 'duplicada', public.registrar_mensagem_entrada('T-2', '5511900000001', false, 'text', 'com a mesma moça'), 'duplicada';
insert into r (teste, resultado, esperado)
select 'lote_msg1', public.coletar_lote((select (resultado->>'conversa_id')::uuid from r where teste='rajada_1'),
                                        (select (resultado->>'mensagem_id')::bigint from r where teste='rajada_1')), 'false';
insert into r (teste, resultado, esperado)
select 'lote_msg2', public.coletar_lote((select (resultado->>'conversa_id')::uuid from r where teste='rajada_2'),
                                        (select (resultado->>'mensagem_id')::bigint from r where teste='rajada_2')), 'true';

-- 4. Envio do bot + eco do webhook
insert into r (teste, resultado, esperado)
select 'envio_permitido', public.verificar_envio((select (resultado->>'conversa_id')::uuid from r where teste='rajada_1')), 'true';
insert into r (teste, resultado, esperado)
select 'registrar_saida', to_jsonb(public.registrar_mensagem_saida((select (resultado->>'conversa_id')::uuid from r where teste='rajada_1'), 'Oi! A Ana tem sex 9h.')), 'id';
insert into r (teste, resultado, esperado)
select 'eco_bot', public.registrar_mensagem_entrada('T-3', '5511900000001', true, 'text', 'Oi! A Ana tem sex 9h.'), 'eco_bot';

-- 5. Humano responde pelo celular -> bot pausa; cliente escreve -> 'humano'
insert into r (teste, resultado, esperado)
select 'humano_assume', public.registrar_mensagem_entrada('T-4', '5511900000001', true, 'text', 'Oi Ju, aqui é a Karol!'), 'humano_respondeu';
insert into r (teste, resultado, esperado)
select 'cliente_pausado', public.registrar_mensagem_entrada('T-5', '5511900000001', false, 'text', 'Oi Karol'), 'humano';
insert into r (teste, resultado, esperado)
select 'envio_bloqueado', public.verificar_envio((select (resultado->>'conversa_id')::uuid from r where teste='rajada_1')), 'humano_na_conversa';

-- 6. Comando /bot devolve a conversa
insert into r (teste, resultado, esperado)
select 'comando_bot', public.registrar_mensagem_entrada('T-6', '5511900000001', true, 'text', '/bot'), 'bot_reativado';
insert into r (teste, resultado, esperado)
select 'cliente_volta_bot', public.registrar_mensagem_entrada('T-7', '5511900000001', false, 'text', 'Quanto custa?'), 'processar';

-- 7. Handoff: status muda e permite só a mensagem de despedida
insert into public.equipe (nome, telefone, papel, recebe_handoff) values ('Recepção Teste', '5511900000009', 'recepcao', true);
insert into r (teste, resultado, esperado)
select 'handoff', public.iniciar_handoff((select (resultado->>'conversa_id')::uuid from r where teste='rajada_1'), 'reclamacao', 'Cliente insatisfeita'), 'destinatarios';
insert into r (teste, resultado, esperado)
select 'envio_pos_handoff', public.verificar_envio((select (resultado->>'conversa_id')::uuid from r where teste='rajada_1')), 'true';
insert into r (teste, resultado, esperado)
select 'numero_equipe', public.registrar_mensagem_entrada('T-8', '5511900000009', false, 'text', 'teste'), 'numero_equipe';

-- 8. Idempotência de escrita no Belasis
insert into r (teste, resultado, esperado)
select 'acao_1', public.reservar_acao_belasis('teste-key-1', (select (resultado->>'conversa_id')::uuid from r where teste='rajada_1'),
                                              'criar_agendamento', '{"x":1}', 'Pode'), 'executar_true';
select public.concluir_acao_belasis((select (resultado->>'acao_id')::bigint from r where teste='acao_1'), true, 201, '{"id":999}', 999);
insert into r (teste, resultado, esperado)
select 'acao_repetida', public.reservar_acao_belasis('teste-key-1', null, 'criar_agendamento', '{"x":1}', 'Pode'), 'executar_false';

-- 9. Limitador de vazão
insert into r (teste, resultado, esperado) select 'cota_1', public.reservar_cota('teste', 2), 'true';
insert into r (teste, resultado, esperado) select 'cota_2', public.reservar_cota('teste', 2), 'true';
insert into r (teste, resultado, esperado) select 'cota_3', public.reservar_cota('teste', 2), 'false';

-- 10. Base de conhecimento
insert into public.kb_itens (categoria, pergunta, resposta, palavras_chave, aprovado)
values ('preco', 'Quanto custa a progressiva?', 'A partir de R$ 250, depende do comprimento.', '{progressiva,alisamento}', true);
insert into r (teste, resultado, esperado)
select 'kb_busca', (select jsonb_agg(to_jsonb(b)) from public.buscar_kb('qual o preço da progressíva') b), 'progressiva';

-- Avaliação
update r set ok = case
  when esperado in ('true','false') and resultado ? 'processar' then (resultado->>'processar') = esperado
  when esperado in ('true','false') and resultado ? 'permitido' then (resultado->>'permitido') = esperado
  when esperado = 'executar_true'  then (resultado->>'executar')::boolean
  when esperado = 'executar_false' then not (resultado->>'executar')::boolean
  when esperado = 'id'             then jsonb_typeof(resultado) = 'number'
  when esperado = 'destinatarios'  then jsonb_array_length(resultado->'destinatarios') = 1
  when esperado = 'progressiva'    then resultado::text ilike '%progressiva%'
  when esperado in ('processar','humano','ignorar') then resultado->>'acao' = esperado
  when resultado ? 'motivo'        then resultado->>'motivo' = esperado
  else resultado::text = esperado
end;

-- Limpeza
delete from public.conversas where telefone like '55119000000%';
delete from public.equipe where telefone like '55119000000%';
delete from public.acoes_belasis where idempotency_key like 'teste-key-%';
delete from public.kb_itens where pergunta = 'Quanto custa a progressiva?';
delete from public.rate_limit where recurso in ('teste', 'whatsapp_envio');
update public.config_bot set valor = '[]' where chave = 'whitelist_piloto';

select n, teste, ok, esperado, resultado from r order by n;
