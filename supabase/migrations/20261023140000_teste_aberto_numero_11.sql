-- Teste aberto: o agente atende qualquer número no WhatsApp da instância (agora o 11 92218-5643).
--  * modo_piloto desligado (whitelist_piloto deixa de limitar clientes)
--  * números da equipe continuam ignorados, exceto os da whitelist_piloto (para a equipe poder testar)
--  * avisos da equipe vão só para o próprio número da instância durante o teste
--  * o 79 99807-1190 deixa de ser "equipe" e pode testar como cliente
do $$
declare d text;
begin
  d := pg_get_functiondef('public.registrar_mensagem_entrada'::regproc);
  d := replace(d, $x$  if exists (select 1 from public.equipe e where e.telefone = v_tel and e.ativo)
     and not (coalesce((public.cfg('modo_piloto'))::boolean, false)
              and coalesce(public.cfg('whitelist_piloto'), '[]'::jsonb) ? v_tel) then$x$,
                  $x$  if exists (select 1 from public.equipe e where e.telefone = v_tel and e.ativo)
     and not coalesce(public.cfg('whitelist_piloto'), '[]'::jsonb) ? v_tel then$x$);
  if position($x$and not coalesce(public.cfg('whitelist_piloto'), '[]'::jsonb) ? v_tel then$x$ in d) = 0 then
    raise exception 'registrar_mensagem_entrada: trecho esperado não encontrado';
  end if;
  execute d;
end $$;

update public.config_bot set valor = 'false'::jsonb where chave = 'modo_piloto';
update public.config_bot set valor = (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements_text(valor) x where x <> '5511922185643')
 where chave = 'whitelist_piloto';
update public.config_bot set valor = '["5511922185643"]'::jsonb where chave = 'encaminhar_somente_para';
update public.equipe set ativo = false where telefone = '5579998071190';
update public.equipe set nome = 'Número do agente (teste) · Ampliize' where telefone = '5511922185643';
