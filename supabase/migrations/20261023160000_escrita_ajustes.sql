-- Ajustes da escrita automática (23/10), aplicados após o primeiro teste real:
--  * novos tipos de aviso aceitos pela tabela
--  * aviso nunca derruba o registro da escrita (encaminhar_seguro)
--  * dia da semana em português nos avisos ("24/10 (Sáb)")
alter table public.notificacoes_equipe drop constraint if exists notificacoes_equipe_tipo_check;
alter table public.notificacoes_equipe add constraint notificacoes_equipe_tipo_check check (tipo in (
  'transferencia', 'duvida_agente', 'problema_atendimento', 'erro_sistema', 'sem_resposta_humana',
  'pre_agendamento', 'retorno_lembrete', 'pre_agendamento_lancado', 'pre_agendamento_falhou'));

create or replace function public.encaminhar_seguro(p_tipo text, p_conversa_id uuid, p_motivo text, p_resumo text, p_mensagem_cliente text default null)
returns void
language plpgsql
set search_path to ''
as $function$
begin
  perform public.encaminhar_para_responsavel(p_tipo, p_conversa_id, p_motivo, p_resumo, p_mensagem_cliente);
exception when others then
  raise warning 'encaminhar_seguro(%): %', p_tipo, sqlerrm;
end;
$function$;

create or replace function public.data_curta_pt(p_data date)
returns text
language sql
immutable
set search_path to ''
as $function$
  select to_char(p_data, 'DD/MM') || ' (' || (array['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'])[extract(dow from p_data)::int + 1] || ')';
$function$;

do $$
declare d text; f text;
begin
  foreach f in array array['public.belasis_registrar_escrita(public.belasis_fila,integer,jsonb,text)', 'public.belasis_escrita_falhou(bigint,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, 'perform public.encaminhar_para_responsavel(', 'perform public.encaminhar_seguro(');
    execute d;
  end loop;
  foreach f in array array[
    'public.belasis_registrar_escrita(public.belasis_fila,integer,jsonb,text)',
    'public.belasis_escrita_falhou(bigint,text)',
    'public.criar_pre_agendamento(uuid,text,date,time without time zone,text,integer,integer,time without time zone,text,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, $x$to_char(p.data, 'DD/MM (TMDy)')$x$, 'public.data_curta_pt(p.data)');
    d := replace(d, $x$to_char(p_data, 'DD/MM (TMDy)')$x$, 'public.data_curta_pt(p_data)');
    execute d;
  end loop;
end $$;
