-- Dados do Belasis mais próximos do tempo real e números honestos no painel.
-- O Belasis não tem webhook: a única forma é ler com frequência, respeitando 30 leituras/min.
--   agora    : agenda de ontem a +2 dias ............ a cada 2 min  (1–2 leituras)
--   agenda   : agenda de -30 a +90 dias ............. a cada 10 min (~12 leituras)
--   catalogo : serviços, categorias, profissionais .. a cada 15 min (~4 leituras)
--   livres   : horários livres de hoje a +3 dias .... a cada 30 min (~45 leituras)
--   clientes : cadastro de clientes .................. a cada hora  (~43 leituras)
--   completa : tudo (agenda de 1 ano, 16 dias de horários) 1x por dia
-- A fila atende primeiro a agenda do dia, para nada atrasar o que é mais urgente.

alter table public.belasis_rodadas drop constraint if exists belasis_rodadas_tipo_check;
alter table public.belasis_rodadas add constraint belasis_rodadas_tipo_check
  check (tipo in ('completa', 'catalogo', 'agenda', 'agora', 'clientes', 'livres'));

create or replace function public.belasis_iniciar_sync(p_tipo text default 'completa')
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  hoje   date := (now() at time zone 'America/Maceio')::date;
  v_suf  text := p_tipo || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  v_ini  date;
  v_fim  date;
  e      record;
  n      integer;
  d      date;
begin
  if p_tipo not in ('completa', 'catalogo', 'agenda', 'agora', 'clientes', 'livres') then
    raise exception 'tipo inválido: %', p_tipo;
  end if;
  if coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado') = 'desligado' then
    return jsonb_build_object('ok', false, 'motivo', 'belasis_desligado');
  end if;
  if exists (select 1 from public.belasis_rodadas
              where tipo = p_tipo and finalizada_em is null and iniciada_em > now() - interval '2 hours') then
    return jsonb_build_object('ok', false, 'motivo', 'ciclo_anterior_em_andamento');
  end if;

  if p_tipo = 'completa' then v_ini := hoje - 365; v_fim := hoje + 60;
  elsif p_tipo = 'agenda' then v_ini := hoje - 30; v_fim := hoje + 90;
  elsif p_tipo = 'agora' then v_ini := hoje - 1; v_fim := hoje + 2;
  end if;

  insert into public.belasis_rodadas (sufixo, tipo, janela_ini, janela_fim) values (v_suf, p_tipo, v_ini, v_fim);

  if p_tipo in ('completa', 'catalogo') then
    perform public.belasis_enfileirar('servicos:1#' || v_suf, '/inventory/services', '{"limit":100,"page":1}');
    perform public.belasis_enfileirar('profissionais:1#' || v_suf, '/employees', '{"limit":100,"page":1}');
  end if;
  if p_tipo in ('completa', 'clientes') then
    perform public.belasis_enfileirar('clientes:1#' || v_suf, '/clients', '{"limit":100,"page":1}');
  end if;
  if p_tipo in ('completa', 'agenda', 'agora') then
    perform public.belasis_enfileirar('agenda:1#' || v_suf, '/schedule_groups',
      jsonb_build_object('limit', 100, 'page', 1, 'start_date', v_ini, 'end_date', v_fim));
  end if;
  if p_tipo = 'livres' then
    for e in select id from public.belasis_profissionais
              where ativo and coalesce(profissao, '') !~* 'recep|secret' and nome <> 'Ateliê' loop
      for n in 0 .. 4 loop
        d := hoje + n;
        if extract(dow from d) not in (0, 1) then
          perform public.belasis_enfileirar('livres:' || e.id || ':' || d || '#' || v_suf,
                                            '/employees/' || e.id || '/free_times', jsonb_build_object('date', d));
        end if;
      end loop;
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'rodada', v_suf);
end;
$function$;

-- agenda do dia primeiro, depois o resto da agenda, depois o restante
create or replace function public.belasis_proximos(p_limite integer default 15)
returns setof public.belasis_fila
language sql
set search_path to ''
as $function$
  update public.belasis_fila f
     set estado = 'processando', tentativas = tentativas + 1
   where f.id in (select id from public.belasis_fila
                   where estado = 'pendente' or (estado = 'processando' and processado_em is null
                                                 and criado_em < now() - interval '10 minutes' and tentativas < 3)
                   order by (chave like '%#agora%') desc, (chave like 'agenda:%') desc, id
                   limit p_limite for update skip locked)
  returning f.*;
$function$;

do $$
begin
  perform cron.schedule('belasis-agora', '*/2 * * * *', $c$select public.belasis_iniciar_sync('agora'::text)$c$);
  perform cron.schedule('belasis-livres', '3,33 * * * *', $c$select public.belasis_iniciar_sync('livres'::text)$c$);
  perform cron.schedule('belasis-clientes', '7 * * * *', $c$select public.belasis_iniciar_sync('clientes'::text)$c$);
  perform cron.schedule('belasis-conciliar-pre', '*/2 * * * *', $c$select public.belasis_conciliar_pre_agendamentos()$c$);
end $$;

-- painel: números honestos
--  * período não conta agendamento apagado no Belasis
--  * ocupação = tempo agendado / (tempo agendado + tempo livre); dia de folga não entra (antes contava como 100%)
--  * profissionais = quem atende (sem recepção/secretaria/Ateliê)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.dashboard_belasis(integer)'::regprocedure);
  d := replace(d, $x$      from public.belasis_agendamentos where data between ini and hoje),$x$,
                  $x$      from public.belasis_agendamentos where data between ini and hoje and status <> 'removido'),$x$);
  d := replace(d, $x$'profissionais', (select count(*) from public.belasis_profissionais where ativo)),$x$,
                  $x$'profissionais', (select count(*) from public.belasis_profissionais
                                        where ativo and coalesce(profissao, '') !~* 'recep|secret' and nome <> 'Ateliê')),$x$);
  d := regexp_replace(d, $x$'ocupacao_proximos_dias', \(select .*?where ocup is not null\),$x$,
    $x$'ocupacao_proximos_dias', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'ocupacao', ocup, 'livres_h', round(livre_min / 60.0, 1)) order by ocup desc), '[]')
      from (select nome, round(100.0 * sum(ag_min) / nullif(sum(ag_min + livre_min), 0)) ocup, sum(livre_min) livre_min
              from (select public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) nome, h.data,
                           15 * (select count(*) from jsonb_array_elements(h.slots) s where s->>'label' = 'available') livre_min,
                           coalesce((select sum(extract(epoch from ((it->>'fim')::time - (it->>'inicio')::time)) / 60)
                                       from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                                      where a.data = h.data and a.status not in ('disconfirm', 'removido')
                                        and (it->>'profissional_id')::int = h.profissional_id
                                        and (it->>'fim')::time > (it->>'inicio')::time), 0) ag_min
                      from public.belasis_horarios_livres h join public.belasis_profissionais p on p.id = h.profissional_id
                     where h.data between hoje and hoje + 6 and p.ativo
                       and coalesce(p.profissao, '') !~* 'recep|secret' and p.nome <> 'Ateliê') dia
             where ag_min + livre_min > 0
             group by nome) x where ocup is not null),$x$, 's');
  if position('livres_h' in d) = 0 or position($x$hoje and status <> 'removido'$x$ in d) = 0 then
    raise exception 'dashboard_belasis: trecho esperado não encontrado';
  end if;
  execute d;
end $$;

-- respostas cruas usadas no diagnóstico de 23/10 não ficam guardadas
update public.belasis_fila set resposta = null where chave like 'raw:%';
