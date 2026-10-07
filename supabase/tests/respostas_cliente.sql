-- Teste: respostas do cliente (horário, encaminhamento por prioridade, silêncio 20h-06h,
-- piloto com números da equipe, base de conhecimento).
-- Termina com RAISE EXCEPTION (desfaz tudo); esperado: "RESULTADO 15 de 15 ok".
do $$
declare res jsonb := '[]'; r jsonb; n int; d jsonb;
  ter10 timestamptz := '2026-10-13 10:00-03'; ter21 timestamptz := '2026-10-13 21:00-03';
  seg10 timestamptz := '2026-10-12 10:00-03';
begin
  d := public.destinatarios_encaminhamento('transferencia', ter10);
  res := res || jsonb_build_object('t','expediente_vai_vitoria','ok', d->0->>'telefone'='5579998134284' and jsonb_array_length(d)=1);
  d := public.destinatarios_encaminhamento('transferencia', ter21);
  res := res || jsonb_build_object('t','noite_vai_emilly','ok', d->0->>'telefone'='5579999216161' and jsonb_array_length(d)=1);
  d := public.destinatarios_encaminhamento('transferencia', seg10);
  res := res || jsonb_build_object('t','segunda_fechado_vai_emilly','ok', d->0->>'telefone'='5579999216161');
  d := public.destinatarios_encaminhamento('sem_resposta_humana', ter10);
  res := res || jsonb_build_object('t','escala_para_emilly','ok', d->0->>'telefone'='5579999216161' and jsonb_array_length(d)=1);
  d := public.destinatarios_encaminhamento('sem_resposta_humana', ter21);
  res := res || jsonb_build_object('t','escala_noite_para_taua','ok', d->0->>'telefone'='5579981256494');
  d := public.destinatarios_encaminhamento('erro_sistema', ter10);
  res := res || jsonb_build_object('t','erro_taua_ampliize','ok', jsonb_array_length(d)=2 and d @> '[{"telefone":"5579981256494"},{"telefone":"5511922185643"}]');
  res := res || jsonb_build_object('t','silencio_21h','ok', not public.pode_iniciar_conversa(ter21));
  res := res || jsonb_build_object('t','silencio_0559','ok', not public.pode_iniciar_conversa('2026-10-13 05:59-03'));
  res := res || jsonb_build_object('t','pode_0600_domingo','ok', public.pode_iniciar_conversa('2026-10-11 06:00-03'));
  res := res || jsonb_build_object('t','salao_fecha_18h','ok', public.salao_aberto('2026-10-13 17:59-03') and not public.salao_aberto('2026-10-13 18:00-03'));
  r := public.registrar_mensagem_entrada('P-1','5579999216161',false,'text','Oi, queria marcar escova',null,'Emilly');
  res := res || jsonb_build_object('t','emilly_testa_como_cliente','ok', r->>'acao'='processar');
  r := public.registrar_mensagem_entrada('P-2','5579998134284',false,'text','oi',null,'Vitoria');
  res := res || jsonb_build_object('t','vitoria_ignorada','ok', r->>'motivo'='numero_equipe');
  r := public.registrar_mensagem_entrada('P-3','5579999216161',true,'text','🔔 *Conversa transferida para a equipe*'||chr(10)||'👤 Ju');
  res := res || jsonb_build_object('t','aviso_equipe_nao_pausa','ok', r->>'motivo'='mensagem_automatica');
  select count(*) into n from public.buscar_kb('tem estacionamento', null, 5) where resposta like '%estacionamento%';
  res := res || jsonb_build_object('t','kb_estacionamento','ok', n>=1);
  select count(*) into n from public.buscar_kb('coloração precisa teste', null, 5) where resposta like '%teste de mecha%';
  res := res || jsonb_build_object('t','kb_teste_mecha','ok', n>=1);
  select count(*) filter (where (x->>'ok')::boolean) into n from jsonb_array_elements(res) x;
  raise exception 'RESULTADO % de % ok: %', n, jsonb_array_length(res),
    (select jsonb_agg(x->>'t') from jsonb_array_elements(res) x where not (x->>'ok')::boolean);
end $$;
