-- Atualização diária completa do Belasis à meia-noite (pedido de 25/11) e correção da leitura
-- dos serviços de cada profissional.
--
-- * A leitura completa (profissionais contratadas/desligadas, serviços, preços, clientes, agenda de
--   -365/+60 dias, serviços por profissional e grade de 16 dias) passa de 05:30 para 00:00
--   (horário de Sergipe, UTC-3 → 03:00 UTC). As leituras parciais continuam ao longo do dia
--   (agenda a cada 2 e 10 min, catálogo a cada 15 min, clientes de hora em hora, horários livres a cada 30 min).
-- * Bug: "serviços por profissional" lia só a 1ª página (100 itens). Profissionais com mais de 100
--   serviços ficavam com a lista incompleta (o agente e o CRM não sabiam que ela fazia os demais).
--   Agora as páginas seguintes também são lidas, com a chave preservando o id da profissional.

do $$
declare d text;
begin
  d := pg_get_functiondef('public.belasis_registrar_resposta(bigint,integer,jsonb,text)'::regprocedure);
  if position('paginacao_prof_servicos' in d) > 0 then return; end if;
  d := replace(d,
$x$  if pg = 1 and total is not null and total > lim and v_tipo in ('servicos','profissionais','clientes','agenda') then$x$,
$x$  -- paginacao_prof_servicos: serviços de cada profissional também têm várias páginas
  if pg = 1 and total is not null and total > lim and v_tipo = 'prof_servicos' then
    for n in 2 .. least(ceil(total::numeric / lim)::int, 50) loop
      perform public.belasis_enfileirar('prof_servicos:' || split_part(v_base, ':', 2) || ':p' || n || v_suf,
                                        f.caminho, f.query || jsonb_build_object('page', n));
    end loop;
  end if;
  if pg = 1 and total is not null and total > lim and v_tipo in ('servicos','profissionais','clientes','agenda') then$x$);
  if position('paginacao_prof_servicos' in d) = 0 then
    raise exception 'belasis_registrar_resposta: trecho de paginação não encontrado';
  end if;
  execute d;
end $$;

-- Leitura completa todo dia às 00:00 de Sergipe (03:00 UTC). Mesmo nome de job: substitui o das 05:30.
select cron.schedule('belasis-sync-diario', '0 3 * * *', $$select public.belasis_iniciar_sync('completa'::text)$$);
