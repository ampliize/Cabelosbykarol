-- =====================================================================
-- 006 · Pendentes identificadas por ordem de chegada (id), não por horário
-- Corrige: mensagens gravadas no mesmo instante empatavam na comparação
-- de timestamp e a pendente não era reaberta na retomada.
-- =====================================================================
create or replace function public.reabrir_mensagens_pendentes(p_conversa_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ultimo_out bigint;
  v_qtd        integer;
  v_ultima     bigint;
begin
  select max(id) into v_ultimo_out
    from public.mensagens
   where conversa_id = p_conversa_id and direcao = 'out' and autor in ('humano', 'bot');

  with pend as (
    update public.mensagens
       set processada_em = null
     where conversa_id = p_conversa_id
       and direcao = 'in' and autor = 'cliente'
       and id > coalesce(v_ultimo_out, 0)
       and criado_em > now() - make_interval(hours => coalesce((public.cfg('retomada_max_horas_msg_pendente'))::int, 12))
    returning id
  )
  select count(*), max(id) into v_qtd, v_ultima from pend;

  return jsonb_build_object('pendentes', v_qtd, 'ultima_mensagem_id', v_ultima);
end;
$$;

revoke all on function public.reabrir_mensagens_pendentes(uuid) from public, anon, authenticated;
grant execute on function public.reabrir_mensagens_pendentes(uuid) to service_role;
