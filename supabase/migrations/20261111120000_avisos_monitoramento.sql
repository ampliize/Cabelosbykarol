-- Auditoria 11/11: alertas de falha (erro_sistema) ficavam sem destinatário (ninguém da equipe com
-- recebe_alertas_sistema) — em 10/11 a chave da OpenAI falhou e ninguém foi avisado.
-- * monitoramento_numeros: a Ampliize (Davy) recebe cópia de TODO aviso (transferências, dúvidas,
--   falhas, agendamentos), sem entrar na equipe (assim pode testar como cliente)
-- * erro_sistema sem ninguém marcado cai para a gerência + monitoramento

insert into public.config_bot (chave, valor, descricao) values
  ('monitoramento_numeros', '["5579998071190"]'::jsonb, 'Ampliize: recebe cópia de todos os avisos da automação (não é equipe do salão)')
on conflict (chave) do nothing;

create or replace function public.com_monitoramento(p_dest jsonb)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  select coalesce(p_dest, '[]'::jsonb) || coalesce((
    select jsonb_agg(jsonb_build_object('nome', 'Ampliize (monitoramento)', 'telefone', t))
      from jsonb_array_elements_text(case when jsonb_typeof(public.cfg('monitoramento_numeros')) = 'array'
                                          then public.cfg('monitoramento_numeros') else '[]'::jsonb end) t
     where not exists (select 1 from jsonb_array_elements(coalesce(p_dest, '[]'::jsonb)) x where x->>'telefone' = t)), '[]'::jsonb);
$function$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.destinatarios_encaminhamento(text,timestamptz)'::regprocedure);
  if position('com_monitoramento' in d) > 0 then return; end if;
  -- erro_sistema: sem ninguém marcado, vai para a gerência
  d := replace(d, $x$      from public.equipe e where e.ativo and e.recebe_alertas_sistema;
    return v_dest;$x$, $x$      from public.equipe e where e.ativo and e.recebe_alertas_sistema;
    if jsonb_array_length(v_dest) = 0 then
      select coalesce(jsonb_agg(jsonb_build_object('nome', 'Gerência', 'telefone', g)), '[]') into v_dest
        from jsonb_array_elements_text(case when jsonb_typeof(public.cfg('gerentes_notificados')) = 'array'
                                            then public.cfg('gerentes_notificados') else '[]'::jsonb end) g;
    end if;
    return public.com_monitoramento(v_dest);$x$);
  d := replace(d, $x$    v_dest := v_dest || v_ger;
  end if;
  return v_dest;$x$, $x$    v_dest := v_dest || v_ger;
  end if;
  return public.com_monitoramento(v_dest);$x$);
  if (length(d) - length(replace(d, 'com_monitoramento', ''))) / length('com_monitoramento') <> 2 then raise exception 'destinatarios: trecho não encontrado'; end if;
  execute d;
end $$;

-- os 15 alertas de 10/11 que nunca saíram (sem destinatário) ficam registrados como não enviados
update public.notificacoes_equipe set estado = 'erro', erro = 'sem destinatário (corrigido em 11/11)'
 where estado = 'pendente' and jsonb_array_length(coalesce(destinatarios, '[]'::jsonb)) = 0;
