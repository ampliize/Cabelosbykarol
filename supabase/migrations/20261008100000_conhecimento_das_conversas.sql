-- =====================================================================
-- Conhecimento extraído das conversas reais (docs/11).
-- Preços e equipe entram como RASCUNHO (aprovado = false): o agente só usa
-- depois que o salão validar no painel/planilha.
-- =====================================================================

-- Resposta a lembrete agora cobre "cliente avisou atraso".
create or replace function public.registrar_retorno_lembrete(
  p_conversa_id uuid,
  p_resposta    text,      -- confirmou | nao_vai | quer_remarcar | atraso
  p_detalhe     text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_resp  text := lower(coalesce(p_resposta, ''));
  v_acao  text;
begin
  v_acao := case v_resp
    when 'confirmou'     then 'Cliente CONFIRMOU presença → marcar como confirmado no Belasis.'
    when 'nao_vai'       then 'Cliente NÃO vai comparecer → cancelar/liberar o horário no Belasis.'
    when 'quer_remarcar' then 'Cliente quer REMARCAR → o agente está coletando a nova preferência.'
    when 'atraso'        then 'Cliente avisou ATRASO → avisar a profissional (tolerância 15 min; cancela após 20 min sem resposta).'
    else null end;
  if v_acao is null then
    return jsonb_build_object('ok', false, 'erro', 'resposta deve ser confirmou, nao_vai, quer_remarcar ou atraso');
  end if;

  return jsonb_build_object('ok', true) || public.encaminhar_para_responsavel(
    'retorno_lembrete', p_conversa_id, 'Resposta a mensagem do salão',
    v_acao || coalesce(E'\n' || p_detalhe, ''), null);
end;
$$;

-- Aprovado (informação pública do próprio salão)
insert into public.kb_itens (categoria, pergunta, resposta, palavras_chave, fonte, aprovado) values
  ('geral', 'Como avaliar o salão no Google?',
   'Pode avaliar aqui: https://g.page/r/CQD-JH61bXyVpEB0/review — ajuda muito a gente!',
   '{avaliar,avaliacao,google,review,estrelas}', 'cliente', true);

-- RASCUNHO para validação do salão (valores citados nas conversas de jul–out/2026)
insert into public.kb_itens (categoria, pergunta, resposta, palavras_chave, fonte, aprovado) values
  ('preco', 'Quanto custa a escova?', 'A escova (lisa ou modelada) é R$ 75.', '{escova,lisa,modelada,preco,valor}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa aplicar hidratação?', 'Aplicação com o seu produto: R$ 30. Hidratação L''Oréal com produto do salão: R$ 145.', '{hidratacao,aplicacao,loreal,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa a manutenção do alongamento capilar?', 'A manutenção do alongamento (Invisible Bio Adesivo) é R$ 370.', '{manutencao,alongamento,"bio adesivo",invisible,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa a selagem?', 'A selagem é R$ 300 (precisa de teste de mecha gratuito antes).', '{selagem,formol,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custam as luzes?', 'Luzes: R$ 690 (precisa de teste de mecha gratuito antes).', '{luzes,mechas,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa a matização?', 'Matização: R$ 150.', '{matizacao,matizar,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa unha em gel?', 'Esmaltação em gel (mão): R$ 90. Uma unha avulsa: R$ 20. Remoção: R$ 25.', '{gel,esmaltacao,unha,remocao,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa o pé?', 'Pedicure (pé normal): R$ 32.', '{pe,pedicure,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa alongamento de unha?', 'Aplicação de alongamento de unha: R$ 180. Manutenção: R$ 110.', '{alongamento,unha,fibra,manutencao,preco}', 'historico_whatsapp', false),
  ('preco', 'Quanto custa design de sobrancelha com henna?', 'Design com henna: R$ 65.', '{sobrancelha,design,henna,preco}', 'historico_whatsapp', false),
  ('geral', 'Quais profissionais atendem no salão?',
   'Cabelo: Patrícia (Paty), Larissa (Lari), Thamires, Adley, Moisés, Thais e Karol. Unhas: Eli, Vitória e Jessica.',
   '{profissional,profissionais,quem,cabeleireira,manicure,equipe}', 'historico_whatsapp', false),
  ('geral', 'Vocês vendem produtos?',
   'Vendemos sim, como o Óleo Perfumado Sérum Hair Karol. Se quiser, a gente pode até mandar entregar.',
   '{produto,produtos,oleo,serum,comprar,vende,entrega}', 'historico_whatsapp', false);
