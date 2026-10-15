-- Piloto: mensagens de quem não está na whitelist_piloto não são gravadas.
-- O número de teste pode ser um celular pessoal; conversas particulares não devem entrar no banco.
do $$
declare d text;
begin
  select pg_get_functiondef('public.registrar_mensagem_entrada'::regproc) into d;
  if position('o número de teste pode ter' in d) > 0 then
    return;
  end if;
  d := replace(d, $x$    return jsonb_build_object('acao', 'ignorar', 'motivo', 'numero_equipe');
  end if;
$x$, $x$    return jsonb_build_object('acao', 'ignorar', 'motivo', 'numero_equipe');
  end if;

  -- piloto: quem não está na lista não é gravado (o número de teste pode ter conversas pessoais)
  if coalesce((public.cfg('modo_piloto'))::boolean, false)
     and not coalesce(public.cfg('whitelist_piloto'), '[]'::jsonb) ? v_tel then
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'fora_do_piloto');
  end if;
$x$);
  if position('o número de teste pode ter' in d) = 0 then
    raise exception 'registrar_mensagem_entrada: trecho esperado não encontrado';
  end if;
  execute d;
end $$;
