-- 26/11: profissional desligada pelo salão continuava "ativa" na API do Belasis (lista /employees e
-- cadastro /employees/{id} devolvem active=true), então seguia no CRM e na agenda do agente.
-- Nova config `profissionais_desligadas` (ids do Belasis, como texto): quem está na lista fica
-- inativa aqui em toda leitura, mesmo que o Belasis ainda a mostre como ativa. Tudo que usa
-- belasis_profissionais.ativo (CRM, quem faz, horários livres, agendar) passa a ignorá-la.

insert into public.config_bot (chave, valor, descricao)
values ('profissionais_desligadas', '["76591"]'::jsonb,
        'Ids do Belasis de profissionais desligadas: ficam inativas no CRM e no agente mesmo se o Belasis ainda mostrar ativas')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao, atualizado_em = now();

do $$
declare d text;
begin
  d := pg_get_functiondef('public.belasis_registrar_resposta(bigint,integer,jsonb,text)'::regprocedure);
  if position('profissionais_desligadas' in d) > 0 then return; end if;
  d := replace(d,
$x$           coalesce((x->>'active')::boolean, true), now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set nome = excluded.nome, apelido_belasis = excluded.apelido_belasis,$x$,
$x$           coalesce((x->>'active')::boolean, true)
             and not (coalesce(public.cfg('profissionais_desligadas'), '[]'::jsonb) ? (x->>'id')), now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set nome = excluded.nome, apelido_belasis = excluded.apelido_belasis,$x$);
  d := replace(d,
$x$                where coalesce((value->>'active')::boolean, true)
                  and coalesce(value->>'profession', '') !~* 'recep' loop$x$,
$x$                where coalesce((value->>'active')::boolean, true)
                  and not (coalesce(public.cfg('profissionais_desligadas'), '[]'::jsonb) ? (value->>'id'))
                  and coalesce(value->>'profession', '') !~* 'recep' loop$x$);
  if (length(d) - length(replace(d, 'profissionais_desligadas', ''))) / length('profissionais_desligadas') <> 2 then
    raise exception 'belasis_registrar_resposta: trechos de profissionais não encontrados';
  end if;
  execute d;
end $$;

update public.belasis_profissionais set ativo = false, atualizado_em = now()
 where coalesce(public.cfg('profissionais_desligadas'), '[]'::jsonb) ? id::text and ativo;
