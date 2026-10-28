-- Teste real 28/10 (tarde):
-- 1) o salão não atende público masculino
-- 2) sem vaga para todas: não perguntar preferência quando só uma tem horário ("tenho com a X, pode ser?");
--    profissional pedida sem vaga → "infelizmente ela não tem vaga, mas tenho com a Y"
-- 3) encerramento simples (prompt no n8n)

update public.kb_itens set resposta = 'Não atendemos público masculino: o salão atende só mulheres. ORIENTAÇÃO: responda isso com gentileza, numa frase.'
 where fonte = 'ampliize' and pergunta like 'Atendem homem?%';

do $$
declare d text;
begin
  d := pg_get_functiondef('public.agendar_whatsapp(uuid,text,date,time,text,text,text,boolean,text,date,boolean,boolean)'::regprocedure);
  if position('so_uma_livre' in d) > 0 then return; end if;

  d := replace(d, $x$  v_unica integer;
$x$, $x$  v_unica integer;
  v_livres jsonb;
$x$);

  d := replace(d, $x$  if v_prof is null and not p_sem_preferencia and not p_complemento then
    return jsonb_build_object('ok', false, 'erro', 'perguntar_profissional',$x$,
  $x$  if v_prof is null and not p_sem_preferencia and not p_complemento then
    v_livres := public.belasis_livres_no_horario(v_serv, p_data, p_hora);
    if jsonb_array_length(v_livres) = 1 then
      return jsonb_build_object('ok', false, 'erro', 'so_uma_livre', 'profissional_livre', v_livres->>0,
        'orientacao', 'Nesse horário só tem vaga com a ' || (v_livres->>0) || '. Não pergunte preferência: diga que tem horário com ela e pergunte se pode marcar. Se a cliente aceitar, chame agendar com profissional=' || (v_livres->>0) || '.');
    elsif jsonb_array_length(v_livres) = 0 then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Ninguém tem vaga nesse horário. Sugira o próximo horário livre (primeiro de livres_no_dia), sem perguntar preferência.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 30, p_hora) -> 'mais_proximos');
    end if;
    return jsonb_build_object('ok', false, 'erro', 'perguntar_profissional',$x$);

  d := replace(d, $x$'orientacao', 'Esse horário não está livre com essa profissional. Pergunte se ela prefere outro horário com a mesma profissional (ofereça 2 ou 3 de livres_com_ela) ou se pode ser com outra profissional nesse horário (sem citar nomes; se aceitar, chame de novo com sem_preferencia=true). Nunca agende com outra sem ela aceitar.',$x$,
  $x$'orientacao', 'Diga que infelizmente essa profissional não tem vaga nesse horário. Se veio outra_livre_nesse_horario, ofereça essa pelo nome ("mas tenho com a X, pode ser?"); senão, sugira o próximo horário livre com ela (primeiro de livres_com_ela). Não pergunte preferência. Só agende com outra se a cliente aceitar.',$x$);

  d := replace(d, $x$'tem_outra_livre_nesse_horario', v_unica is null and jsonb_array_length(public.belasis_livres_no_horario(v_serv, p_data, p_hora)) > 0);$x$,
  $x$'outra_livre_nesse_horario', case when v_unica is null then public.belasis_livres_no_horario(v_serv, p_data, p_hora) ->> 0 end);$x$);

  if position('so_uma_livre' in d) = 0 or position('v_livres jsonb' in d) = 0
     or position('outra_livre_nesse_horario' in d) = 0 or position('infelizmente' in d) = 0 then
    raise exception 'agendar_whatsapp: trecho não encontrado';
  end if;
  execute d;
end $$;

-- n8n (CBK · Agente Core): prompt com ENCERRAMENTO (sem reconfirmar, resposta curta), PÚBLICO (só mulheres),
-- PROFISSIONAIS (agendar sem profissional primeiro: so_uma_livre / perguntar_profissional / horario_ocupado).
