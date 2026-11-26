-- 26/11: "quero o mesmo da semana passada" / "com a mesma profissional". O perfil da cliente já trazia
-- as 5 últimas visitas (serviço + profissional), mas o agente não sabia usar. Aqui:
-- * cada serviço das últimas visitas diz se a profissional ainda atende (profissional_ainda_atende);
-- * profissional_mais_frequente considera só quem ainda atende.
-- O prompt (v3.7) ensina o agente a ler esse histórico.

do $$
declare d text;
begin
  d := pg_get_functiondef('public.perfil_cliente_belasis(text)'::regprocedure);
  if position('profissional_ainda_atende' in d) > 0 then return; end if;
  d := replace(d,
$x$'servicos', (select jsonb_agg(jsonb_build_object('servico', s.descricao, 'profissional', public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome)))$x$,
$x$'servicos', (select jsonb_agg(jsonb_build_object('servico', s.descricao, 'profissional', public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome), 'profissional_ainda_atende', coalesce(p.ativo, false)))$x$);
  d := replace(d,
$x$jsonb_array_elements(a.itens) it join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int
         where a.cliente_id = c.id and a.status not in ('disconfirm', 'removido')$x$,
$x$jsonb_array_elements(a.itens) it join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int
         where a.cliente_id = c.id and a.status not in ('disconfirm', 'removido') and p.ativo$x$);
  if position('profissional_ainda_atende' in d) = 0 or position('removido'') and p.ativo' in d) = 0 then
    raise exception 'perfil_cliente_belasis: trechos não encontrados';
  end if;
  execute d;
end $$;
