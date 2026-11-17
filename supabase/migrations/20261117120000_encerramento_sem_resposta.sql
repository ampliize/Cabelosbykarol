-- Conversas reais de 17/11 (Ely): depois de encerrar ("te esperamos amanhã às 9h 💕"), o agente respondia
-- de novo a cada figurinha, "certinho", "ok"... Regra: se a cliente só mandou figurinha/reação/emoji ou um
-- agradecimento/confirmação curta, e a última mensagem do salão (agente ou equipe) não fez pergunta,
-- a conversa já está encerrada: o agente NÃO responde.
-- Não vale para resposta a mensagem automática (lembrete do Belasis): ali o "joia" é confirmação de
-- presença e o agente precisa registrar (registrar_retorno_lembrete).
-- Usado pelo n8n (CBK · Agente Core > Carregar contexto > "Só encerramento?"). p_ate_id: avalia a conversa
-- como estava até aquela mensagem (para teste com conversas reais).

create or replace function public.so_encerramento_ate(p_conversa_id uuid, p_ate_id bigint)
returns boolean
language plpgsql
stable
set search_path to ''
as $function$
declare
  m        record;
  v_lote   integer := 0;
  v_ant    public.mensagens;
  v_txt    text;
  v_vocab  constant text[] := array[
    'ok','okay','okey','oki','certo','certinho','certissimo','combinado','combinadissimo','joia','blz','beleza',
    'obrigada','obrigado','obrigadas','obrigados','obg','brigada','brigado','muito','mto','valeu','vlw','perfeito',
    'perfeita','show','top','otimo','otima','maravilha','ta','bom','amem','sim','isso','entendi','ate','amanha',
    'logo','mais','tchau','beijos','beijo','bjs','bj','entao','tudo','demais','ah','ai','gratidao','grata','grato',
    'de','nada','e','agradeco','lindo','linda','amei','deus','abencoe'];
  w        text;
begin
  for m in select id, autor, tipo, texto, criado_em from public.mensagens
            where conversa_id = p_conversa_id and (p_ate_id is null or id <= p_ate_id)
            order by id desc limit 15 loop
    if m.autor <> 'cliente' then select * into v_ant from public.mensagens where id = m.id; exit; end if;
    v_lote := v_lote + 1;
    if m.tipo in ('sticker', 'outro') and coalesce(m.texto, '') = '' then continue; end if;
    if m.tipo <> 'text' then return false; end if;
    -- sem acentos, minúsculo, só letras e espaços (emojis e pontuação somem)
    v_txt := lower(translate(coalesce(m.texto, ''), 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
                                                    'aaaaaeeeeiiiiooooouuuucaaaaaeeeeiiiiooooouuuuc'));
    v_txt := btrim(regexp_replace(regexp_replace(v_txt, '[^a-z ]', ' ', 'g'), '\s+', ' ', 'g'));
    if v_txt = '' then continue; end if;                                 -- só emoji/pontuação
    if array_length(string_to_array(v_txt, ' '), 1) > 7 then return false; end if;
    foreach w in array string_to_array(v_txt, ' ') loop
      if w ~ '^(k+|rs+|ha(ha)+|he(he)+|o+k+|aff|hum+|uhum|aham)$' then continue; end if;
      if not (w = any (v_vocab)) then return false; end if;
    end loop;
  end loop;

  return v_lote > 0
     and v_ant.id is not null
     and v_ant.autor in ('bot', 'humano')                               -- não é resposta a lembrete automático
     and position('?' in coalesce(v_ant.texto, '')) = 0                 -- a última mensagem do salão não perguntou nada
     and v_ant.criado_em > coalesce((select criado_em from public.mensagens where id = p_ate_id), now()) - interval '24 hours';
end;
$function$;

create or replace function public.so_encerramento(p_conversa_id uuid)
returns boolean
language sql
stable
set search_path to ''
as $function$ select public.so_encerramento_ate(p_conversa_id, null) $function$;

-- n8n (17/11): CBK · Agente Core > "Carregar contexto" traz so_encerramento; novo nó If "Precisa responder?"
-- só chama o agente quando so_encerramento não é true. Prompt v3.2 (docs/15-PROMPT-AGENTE-V3.md) publicado:
-- continuidade quando a equipe estava conversando (0.1), encerramento sem repetir, data de hoje, cancelamento seguro.
-- Regras de volta da IA mantidas: equipe conversando → volta após 5 min sem a equipe escrever;
-- transferência feita pelo agente → só volta pelo botão "Devolver ao agente" (20261114120000).
