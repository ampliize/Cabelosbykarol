-- =====================================================================
-- Modelos reais das mensagens automáticas do salão (Belasis), extraídos de
-- 53 conversas exportadas (07–10/2026) e dos prints enviados pelo cliente.
-- Validação: 2.029 de 5.871 mensagens do salão reconhecidas, sem falso
-- positivo em mensagens digitadas pela equipe (docs/11).
--
-- O Belasis insere o caractere invisível U+2800 (⠀) no lugar de espaços
-- para variar o texto: normalizamos antes de comparar.
-- =====================================================================

update public.config_bot set valor = '[
  "aqui [eé] do sal[aã]o (cabelos by )?(da )?karol",
  "passando para lembrar e confirmar seu hor[aá]rio",
  "percebemos que j[aá] faz(em)? [0-9]+ dias",
  "j[aá] faz um tempinho que voc[eê] n[aã]o vem",
  "amanh[aã] temos um encontro marcado",
  "foi um prazer cuidar de voc[eê]",
  "[eé] hoje!.{0,40}passando s[oó] para lembrar",
  "seu hor[aá]rio no cabelos by karol est[aá] confirmado",
  "como v[aã]o as unhas divinas",
  "como est[aã]o seus lindos cabelos",
  "seu agendamento para o dia .* est[aá] ok",
  "seu agendamento no cabelos by karol foi atualizado",
  "seu agendamento de .{0,60} foi cancelado",
  "agradecemos sua presen[cç]a",
  "hoje faz(em)? [0-9]+ dias que voc[eê] fez",
  "j[aá] faz(em)? [0-9]+ dias que voc[eê] comprou",
  "seu alongamento est[aá] (incr[ií]vel|pronto)",
  "guia de cuidados",
  "passamos para agradecer por ter escolhido",
  "bem[- ]vind[ao] [aà] nossa fam[ií]lia",
  "deixe sua avalia[cç][aã]o no google|g\\.page/r/",
  "sentimos sua falta por aqui",
  "karol e (toda )?(a )?equipe cabelos by karol",
  "feliz anivers[aá]rio|parab[eé]ns pelo (seu )?anivers",
  "cashback",
  "^(🔔|❓|⚠️|🚨|⏰|📅|✅) \\*"
]'::jsonb
 where chave = 'padroes_mensagens_automaticas';

insert into public.config_bot (chave, valor, descricao) values
  ('link_avaliacao_google', '"https://g.page/r/CQD-JH61bXyVpEB0/review"', 'Link para a cliente avaliar o salão no Google')
on conflict (chave) do update set valor = excluded.valor;

do $$
declare
  v_def text := pg_get_functiondef('public.registrar_mensagem_entrada(text,text,boolean,text,text,text,text,text,jsonb)'::regprocedure);
  v_old text := 'where v_texto ~* pad';
  v_new text := 'where regexp_replace(v_texto, ''[[:space:]'' || chr(10240) || '']+'', '' '', ''g'') ~* pad';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'trecho dos padrões não encontrado em registrar_mensagem_entrada';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$$;

-- Trava: um regex inválido em padroes_mensagens_automaticas quebraria o registro de
-- todas as mensagens enviadas pelo salão. Valida antes de salvar.
create or replace function public.tg_validar_padroes()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  p text;
begin
  if new.chave = 'padroes_mensagens_automaticas' then
    for p in select jsonb_array_elements_text(coalesce(new.valor, '[]'::jsonb)) loop
      begin
        perform '' ~* p;
      exception when others then
        raise exception 'Padrão inválido em padroes_mensagens_automaticas: % (%)', p, sqlerrm;
      end;
    end loop;
  end if;
  return new;
end;
$$;

create trigger config_bot_validar_padroes before insert or update on public.config_bot
  for each row execute function public.tg_validar_padroes();
