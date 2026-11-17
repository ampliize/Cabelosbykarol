-- Conversa real de 17/11 (Edilene): a cliente escreveu "Megga" e o agente respondeu
-- 'Qual é o nome certinho do serviço "Megga" (como escreve)?' — soa como correção, falta de educação.
-- Causa: consultar_servicos comparava o texto exato; "megga", "escoova" etc. não achavam nada.
-- * busca normalizada: sem acento, minúsculo e sem letras repetidas (megga → mega, escoova → escova)
-- * mais sinônimos (mega hair, megahair, fita, tic tac → alongamento; luz/mechas → luzes...)
-- * se nada bater, procura pelo serviço de nome mais parecido (pg_trgm), para erros de digitação
-- O prompt (v3.3) proíbe corrigir, citar a grafia errada ou perguntar como se escreve.

create extension if not exists pg_trgm with schema extensions;

create or replace function public.texto_busca(p text)
returns text
language sql
immutable
set search_path to ''
as $function$
  select regexp_replace(lower(extensions.unaccent(coalesce(p, ''))), '([a-z])\1+', '\1', 'g');
$function$;

create or replace function public.consultar_servicos(p_busca text, p_limite integer default 8)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  with base as (
    select t from regexp_split_to_table(public.texto_busca(p_busca), '[^a-z0-9]+') t where length(t) >= 3
  ), termos as (
    select t from base
    union
    select s.para from base join (values
        ('progresiva', 'selagem'), ('progressiva', 'selagem'), ('alisamento', 'selagem'), ('alisar', 'selagem'),
        ('mega', 'alongamento'), ('megahair', 'alongamento'), ('megaher', 'alongamento'), ('megarair', 'alongamento'),
        ('aplique', 'alongamento'), ('fita', 'alongamento'), ('tictac', 'alongamento'), ('extensao', 'alongamento'),
        ('mechas', 'luzes'), ('mecha', 'luzes'), ('luz', 'luzes'), ('reflexo', 'luzes'), ('reflexos', 'luzes'),
        ('pintar', 'coloracao'), ('tintura', 'coloracao'), ('tinta', 'coloracao'),
        ('unhas', 'manicure'), ('unha', 'manicure'), ('pe', 'pedicure'), ('pes', 'pedicure'),
        ('sobrancelhas', 'sobrancelha'), ('cilios', 'cilios')) s(de, para)
      on s.de = base.t or s.de = replace(base.t, ' ', '')
  ), cand as (
    select s.*, g.nome categoria,
           public.texto_busca(s.descricao) || ' ' || public.texto_busca(g.nome) alvo
      from public.belasis_servicos s
      left join public.belasis_grupos g on g.id = s.group_id
     where s.ativo
  ), pontos as (
    select cand.*,
           (select count(*) from termos where public.texto_busca(cand.descricao) like '%' || termos.t || '%') * 2
         + (select count(*) from termos where public.texto_busca(cand.categoria) like '%' || termos.t || '%') acertos,
           (select coalesce(max(extensions.word_similarity(termos.t, cand.alvo)), 0) from termos) parecido,
           (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
             where (it->>'servico_id')::int = cand.id and a.status not in ('disconfirm', 'removido')
               and a.data >= current_date - 120) feitos
      from cand
  ), escolhidos as (
    select * from pontos
     where acertos > 0
        or (not exists (select 1 from pontos where acertos > 0) and parecido >= 0.5)
     order by acertos desc, parecido desc, feitos desc, descricao
     limit greatest(1, least(p_limite, 15))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'servico', descricao,
           'categoria', categoria,
           'preco_tabela', case when preco_cents > 0 then 'R$ ' || replace(to_char(preco_cents / 100.0, 'FM999990.00'), '.', ',') end,
           'duracao_min', duracao_min,
           'agendamento_online', online,
           'quem_faz_so_se_a_cliente_perguntar', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) order by q.n desc)
                          from public.belasis_quem_faz(escolhidos.id) q join public.belasis_profissionais p on p.id = q.profissional_id),
           'feitos_ultimos_120_dias', feitos)
         order by acertos desc, parecido desc, feitos desc, descricao), '[]')
    from escolhidos;
$function$;

-- z e s contam como a mesma letra na busca (luses → luzes)
create or replace function public.texto_busca(p text)
returns text
language sql
immutable
set search_path to ''
as $function$
  select regexp_replace(translate(lower(extensions.unaccent(coalesce(p, ''))), 'z', 's'), '([a-z])\1+', '\1', 'g');
$function$;

-- n8n (17/11): prompt v3.3 publicado (seção 2.1: educação com erros de escrita, nome consistente, sem
-- nome técnico/parênteses, não reconfirmar o que a cliente já confirmou); descrição de consultar_servicos
-- avisa que a busca entende erros de digitação e proíbe perguntar à cliente como se escreve.
