-- "Profissional" no painel e na leitura de horários = quem de fato atende:
-- ativa no Belasis e com pelo menos 5 atendimentos nos últimos 60 dias.
-- Exclui recepção, coordenação, usuário de teste e Ateliê sem lista fixa de nomes.
create or replace function public.belasis_profissionais_que_atendem()
returns setof integer
language sql
stable
set search_path to ''
as $function$
  select p.id
    from public.belasis_profissionais p
   where p.ativo and p.nome <> 'Ateliê'
     and (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
           where (it->>'profissional_id')::int = p.id and a.status <> 'removido'
             and a.data >= (now() at time zone 'America/Maceio')::date - 60) >= 5;
$function$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.dashboard_belasis(integer)'::regprocedure);
  d := replace(d, $x$(select count(*) from public.belasis_profissionais
                                        where ativo and coalesce(profissao, '') !~* 'recep|secret' and nome <> 'Ateliê')$x$,
                  $x$(select count(*) from public.belasis_profissionais_que_atendem())$x$);
  d := replace(d, $x$where h.data between hoje and hoje + 6 and p.ativo
                       and coalesce(p.profissao, '') !~* 'recep|secret' and p.nome <> 'Ateliê') dia$x$,
                  $x$where h.data between hoje and hoje + 6
                       and p.id in (select public.belasis_profissionais_que_atendem())) dia$x$);
  if position('belasis_profissionais_que_atendem' in d) = 0 or position('recep|secret' in d) > 0 then
    raise exception 'dashboard_belasis: trecho esperado não encontrado';
  end if;
  execute d;

  d := pg_get_functiondef('public.belasis_iniciar_sync(text)'::regprocedure);
  d := replace(d, $x$for e in select id from public.belasis_profissionais
              where ativo and coalesce(profissao, '') !~* 'recep|secret' and nome <> 'Ateliê' loop$x$,
                  $x$for e in select id from public.belasis_profissionais_que_atendem() id loop$x$);
  if position('belasis_profissionais_que_atendem' in d) = 0 then
    raise exception 'belasis_iniciar_sync: trecho esperado não encontrado';
  end if;
  execute d;
end $$;
