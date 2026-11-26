-- 26/11: o salão vai funcionar em 01/12 e 02/12 (a resposta 29 do questionário, "por enquanto",
-- listava esses dias como fechados). Continuam fechados: 08/12 e 25/12.
--
-- Comanda única: os serviços do mesmo dia já iam juntos no Belasis, mas havia uma brecha. Se a
-- cliente acrescentava um serviço depois que a comanda tinha sido lançada (espera de 3 min), o
-- serviço novo virava outra comanda. Agora:
-- * a espera para montar a comanda sobe para 8 min depois do último serviço e 5 min de silêncio da
--   cliente (máximo 15 min);
-- * serviço acrescentado depois da comanda lançada NÃO cria outra comanda: fica como
--   "complemento_manual" e a equipe recebe o aviso para incluir na comanda que já existe.

update public.config_bot set valor = '["2026-12-08","2026-12-25"]'::jsonb where chave = 'dias_fechados';

update public.kb_itens
   set resposta = 'Em dezembro o salão não abre nos dias 08/12 e 25/12. Nos outros dias funciona normalmente, de terça a sábado. ORIENTAÇÃO: para outros feriados ou datas de fim de ano, transfira (incerteza) sem responder.',
       atualizado_em = now()
 where id = 43;

update public.config_bot set valor = '8'::jsonb where chave = 'comanda_espera_minutos';

create or replace function public.belasis_processar_comandas()
returns integer
language plpgsql
set search_path to ''
as $function$
declare
  g        record;
  l        public.pre_agendamentos;
  v_itens  text;
  v_n      integer := 0;
  v_esp    integer := coalesce((public.cfg('comanda_espera_minutos'))::int, 8);
begin
  for g in
    select p.conversa_id, p.data, min(p.id) lider
      from public.pre_agendamentos p
      join public.conversas c on c.id = p.conversa_id
     where p.escrita_estado = 'aguardando_comanda' and p.estado <> 'cancelado'
     group by p.conversa_id, p.data, c.ultima_msg_cliente_em
    having max(p.criado_em) < now() - make_interval(mins => v_esp)
       and (coalesce(c.ultima_msg_cliente_em, '-infinity') < now() - interval '5 minutes'
            or max(p.criado_em) < now() - interval '15 minutes')
  loop
    -- complemento_tardio: já existe comanda lançada (ou indo) para essa cliente nesse dia
    select x.* into l
      from public.pre_agendamentos x
     where x.conversa_id = g.conversa_id and x.data = g.data and x.estado <> 'cancelado'
       and x.escrita_estado in ('na_fila', 'lancado')
       and (x.belasis_agendamento_id is null
            or exists (select 1 from public.belasis_agendamentos a
                        where a.id = x.belasis_agendamento_id and a.status not in ('removido', 'disconfirm')))
     order by x.id limit 1;

    if l.id is not null then
      update public.pre_agendamentos set escrita_estado = 'complemento_manual', comanda_id = coalesce(l.comanda_id, l.id),
             atualizado_em = now()
       where conversa_id = g.conversa_id and data = g.data
         and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado';
      select string_agg(format('%s%s às %s', m.servico, coalesce(' com ' || m.profissional, ''), to_char(m.hora_inicio, 'HH24:MI')),
                        E'\n' order by m.hora_inicio, m.id)
        into v_itens
        from public.pre_agendamentos m
       where m.conversa_id = g.conversa_id and m.data = g.data and m.escrita_estado = 'complemento_manual'
         and m.estado <> 'cancelado' and m.atualizado_em > now() - interval '1 minute';
      perform public.encaminhar_seguro('pre_agendamento', g.conversa_id, 'Acrescentar na comanda já lançada',
        'A cliente pediu mais serviço para ' || public.data_curta_pt(g.data) || E':\n' || coalesce(v_itens, '?')
        || E'\nInclua na MESMA comanda que já está no Belasis (não crie outra) e confirme com a cliente.');
    else
      update public.pre_agendamentos set comanda_id = g.lider, atualizado_em = now()
       where conversa_id = g.conversa_id and data = g.data
         and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado';
      begin
        perform public.belasis_preparar_escrita(g.lider);
      exception when others then
        perform public.belasis_escrita_falhou(g.lider, 'erro interno: ' || sqlerrm);
      end;
    end if;
    l := null;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;
