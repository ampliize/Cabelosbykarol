-- Dado real: a API Belasis devolve "duration" em SEGUNDOS (ex.: 5400 = 90 min),
-- e não em minutos como diz a documentação. Corrige a leitura e o que já foi gravado.
do $$
declare
  v_def text := pg_get_functiondef('public.belasis_registrar_resposta(bigint,integer,jsonb,text)'::regprocedure);
begin
  if position('(x->>''duration'')::int,' in v_def) = 0 then
    raise exception 'trecho de duration não encontrado';
  end if;
  execute replace(v_def, '(x->>''duration'')::int,', '((x->>''duration'')::int / 60),');
end $$;

update public.belasis_servicos set duracao_min = duracao_min / 60 where duracao_min >= 300;

-- Preço no formato brasileiro (R$ 180,00).
do $$
declare
  v_def text := pg_get_functiondef('public.consultar_servicos(text,integer)'::regprocedure);
begin
  execute replace(v_def, 'to_char(preco_cents / 100.0, ''FM"R$ "999G990D00'')',
                  '''R$ '' || replace(to_char(preco_cents / 100.0, ''FM999990.00''), ''.'', '','')');
end $$;
