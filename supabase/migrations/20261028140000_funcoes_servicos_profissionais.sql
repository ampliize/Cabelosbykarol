-- Planilha "ajuste_IA" (28/10): quem faz cada serviço, função de cada profissional e lista da vez.
-- Regras: o agente NUNCA oferece nome de profissional; pergunta se a cliente tem preferência.
-- Sem preferência → profissional da vez entre as aptas para o serviço (prioritária primeiro, se livre).
-- Emilly e Vitória (recepção) e Tauã não atendem; Eli, Vitória.mani e Jessica são manicures.
-- Ampliize (Davy - Teste) só recebe agendamento quando a cliente pede por ela (nunca entra na lista da vez).

create table if not exists public.belasis_profissional_funcoes (
  profissional_id integer primary key,
  funcao text not null check (funcao in ('cabeleireira', 'manicure', 'recepcao', 'atelie', 'teste')),
  atualizado_em timestamptz not null default now()
);
alter table public.belasis_profissional_funcoes enable row level security;

create table if not exists public.belasis_servico_regras (
  servico_id integer primary key,
  quem text not null check (quem in ('cabeleireiras', 'manicures', 'unica')),
  profissional_id integer,            -- quando quem = 'unica'
  prioritaria_sem_preferencia integer, -- sem preferência: esta vem primeiro (se livre); depois, a da vez
  nome_planilha text,
  atualizado_em timestamptz not null default now()
);
alter table public.belasis_servico_regras enable row level security;

insert into public.belasis_profissional_funcoes (profissional_id, funcao) values
  (37416, 'cabeleireira'), (79947, 'cabeleireira'), (76591, 'cabeleireira'), (93478, 'cabeleireira'),
  (53001, 'cabeleireira'), (168851, 'cabeleireira'), (156895, 'cabeleireira'), (144451, 'cabeleireira'),
  (145692, 'cabeleireira'),
  (102329, 'manicure'), (92559, 'manicure'), (158248, 'manicure'),
  (78182, 'recepcao'), (168525, 'recepcao'), (37414, 'recepcao'),
  (128725, 'atelie'), (172890, 'teste')
on conflict (profissional_id) do update set funcao = excluded.funcao, atualizado_em = now();

with planilha (nome, quem, profissional_id, prioritaria) as (values
  ('Escova Infusion Truss', 'cabeleireiras', null, null),
  ('Hidratação Smith Aloe Vera', 'cabeleireiras', null, null),
  ('Hidratação Tutano e Caviar Mirra', 'cabeleireiras', null, null),
  ('Reconstrução Smith Shock10', 'cabeleireiras', null, null),
  ('Reconstrução 3D Fusion London', 'cabeleireiras', null, null),
  ('Reparação NetMask Truss', 'cabeleireiras', null, null),
  ('Hidratação Proteina do Leite Mirra', 'cabeleireiras', null, null),
  ('Intense Repair Kpro', 'cabeleireiras', null, null),
  ('Tratamento Terrena Detox e Fortalecimento', 'cabeleireiras', null, null),
  ('Fast Repair Truss', 'cabeleireiras', null, null),
  ('Tratamento Infusion Truss', 'cabeleireiras', null, null),
  ('Fusion CMC Mirra', 'cabeleireiras', null, null),
  ('Ultra Hydration mirra', 'cabeleireiras', null, null),
  ('Blond Damage Truss', 'cabeleireiras', null, null),
  ('Nano Force Tratamento Maison visage', 'cabeleireiras', null, null),
  ('Keratin Restore Truss', 'cabeleireiras', null, null),
  ('Tratamento Stop No Metal Truss', 'cabeleireiras', null, null),
  ('Hidratação Mirra Ouro', 'cabeleireiras', null, null),
  ('Blends de óleos essenciais', 'cabeleireiras', null, null),
  ('Caviar intense Kpro', 'cabeleireiras', null, null),
  ('Selagem Londom Argila', 'cabeleireiras', null, null),
  ('Coloração Capa Truss', 'cabeleireiras', null, null),
  ('Luzes / Mechas', 'unica', 37416, null),
  ('Selagem Formol', 'cabeleireiras', null, null),
  ('Coloração Kpro 10 minutos raiz', 'cabeleireiras', null, null),
  ('Botox Sem formol Smith', 'cabeleireiras', null, null),
  ('Coloração Fios Brancos Gloss Raiz', 'cabeleireiras', null, null),
  ('Selagem Orgânica 4D Smith', 'cabeleireiras', null, null),
  ('retoque coloração', 'cabeleireiras', null, null),
  ('Coloração Kpro Completa', 'cabeleireiras', null, null),
  ('Matização Gloss 3D + Escova', 'cabeleireiras', null, null),
  ('Retoque selagem', 'cabeleireiras', null, null),
  ('Luzes franja', 'unica', 37416, null),
  ('Coloração TRUSS Completa', 'cabeleireiras', null, null),
  ('Luzes Capa', 'unica', 37416, null),
  ('Coloração Truss Raiz', 'cabeleireiras', null, null),
  ('Selagem Capa London Argila', 'cabeleireiras', null, null),
  ('Selagem Capa Formol', 'cabeleireiras', null, null),
  ('Serviço Pedicure', 'manicures', null, null),
  ('Esmaltação em Gel com Blindagem', 'manicures', null, null),
  ('Serviço de manicure', 'manicures', null, null),
  ('Blindagem de Unha', 'manicures', null, null),
  ('Decoração / Francesinha', 'manicures', null, null),
  ('Aplicação unha avulsa em gel', 'unica', 92559, null),
  ('Manutenção Alongamento de Unha', 'unica', 92559, null),
  ('Spa dos Pés (com pedicure)', 'manicures', null, null),
  ('Alongamento de Unha com Esmaltação em Gel', 'unica', 92559, null),
  ('Esmaltação', 'manicures', null, null),
  ('Banho de gel', 'manicures', null, null),
  ('Retirada de gel', 'unica', 92559, null),
  ('retirada alongamento Mista', 'cabeleireiras', null, null),
  ('Manutenção Mista Bio + Nano ou Micro Alongamento', 'cabeleireiras', null, 37416),
  ('Invisible Bio Adesivo Manutenção', 'cabeleireiras', null, 37416),
  ('Retirada de Bio Adesivo', 'cabeleireiras', null, null),
  ('Biolink Manutenção Alongamento', 'cabeleireiras', null, 37416),
  ('Micro Capsula de Queratina Manutenção Alongamento', 'cabeleireiras', null, null),
  ('Retirada Biolink', 'cabeleireiras', null, null),
  ('Aplicação M.C queratina', 'cabeleireiras', null, null),
  ('Recolocação fita Bio Adesivo', 'cabeleireiras', null, null),
  ('Recolocação Biolink', 'cabeleireiras', null, null),
  ('Escova Lisa / Modelada', 'cabeleireiras', null, null),
  ('Prancha no cabelo', 'cabeleireiras', null, null),
  ('Lavagem com Massagem Capilar', 'cabeleireiras', null, null),
  ('Corte Pontas', 'unica', 37416, null),
  ('Lavagem com shampoo especial', 'cabeleireiras', null, null),
  ('Babyliss Cabelo', 'cabeleireiras', null, null),
  ('Corte Feminino', 'unica', 37416, null),
  ('Aplicação Coloração + Escova', 'cabeleireiras', null, null),
  ('Aplicação de Hidratação', 'cabeleireiras', null, null),
  ('Corte Franja', 'unica', 37416, null),
  ('Nutrição All Soft Redken', 'cabeleireiras', null, null),
  ('Ritual Résistance Thérapiste Kérastase', 'cabeleireiras', null, null),
  ('Tratamento CPR Senscience (4 passos)', 'cabeleireiras', null, null),
  ('Hidratação Loreal Absolut', 'cabeleireiras', null, null),
  ('Avaliação para outros Serviços', 'unica', 37416, null),
  ('Avaliação alongamento Capilar', 'unica', 37416, null),
  ('Teste de Mecha Luzes', 'unica', 37416, null),
  ('Designer de sobrancelhas SEM henna', 'unica', 76591, null),
  ('Designer de sobrancelhas COM henna', 'unica', 76591, null),
  ('Confecção BioLink', 'unica', 128725, null),
  ('Confecção Invisible Bio Adesivo', 'unica', 128725, null),
  ('Produção completa', 'unica', 37416, null),
  ('Maquiagem + cílios', 'unica', 37416, null),
  ('Alongamento Capilar', 'unica', 37416, null)
)
insert into public.belasis_servico_regras (servico_id, quem, profissional_id, prioritaria_sem_preferencia, nome_planilha)
select distinct on (s.id) s.id, p.quem, p.profissional_id, p.prioritaria, p.nome
  from planilha p
  join public.belasis_servicos s
    on lower(extensions.unaccent(btrim(s.descricao))) = lower(extensions.unaccent(btrim(p.nome)))
order by s.id
on conflict (servico_id) do update set quem = excluded.quem, profissional_id = excluded.profissional_id,
  prioritaria_sem_preferencia = excluded.prioritaria_sem_preferencia, nome_planilha = excluded.nome_planilha, atualizado_em = now();

-- serviços da agenda que não estão na planilha: padrão pela categoria (editável na tabela)
insert into public.belasis_servico_regras (servico_id, quem, profissional_id, nome_planilha)
select s.id,
  case when s.descricao ~* 'luzes|morena ilum|corte|tricoscopia' or g.nome ~* 'personaliza' then 'unica'
       when g.nome ~* 'estética|estetica' then 'unica'
       when g.nome ~* 'confec' then 'unica'
       when g.nome ~* 'mãos|maos' then 'manicures'
       else 'cabeleireiras' end,
  case when s.descricao ~* 'luzes|morena ilum|corte|tricoscopia' or g.nome ~* 'personaliza' then 37416
       when g.nome ~* 'estética|estetica' then 76591
       when g.nome ~* 'confec' then 128725 end,
  null
from public.belasis_servicos s left join public.belasis_grupos g on g.id = s.group_id
where s.ativo and coalesce(g.nome,'') !~* 'produtos'
  and not exists (select 1 from public.belasis_servico_regras r where r.servico_id = s.id)
on conflict (servico_id) do nothing;

-- quem pode fazer o serviço (nunca recepção; a profissional de teste só quando pedida pelo nome)
create or replace function public.belasis_aptas(p_servico_id integer)
returns setof integer
language sql
stable
set search_path to ''
as $function$
  with r as (select * from public.belasis_servico_regras where servico_id = p_servico_id)
  select p.id from public.belasis_profissionais p
   where p.ativo and (
     exists (select 1 from r where r.quem = 'unica' and r.profissional_id = p.id)
     or exists (select 1 from r join public.belasis_profissional_funcoes f on f.profissional_id = p.id
                 where (r.quem = 'cabeleireiras' and f.funcao = 'cabeleireira') or (r.quem = 'manicures' and f.funcao = 'manicure'))
     or (not exists (select 1 from r) and p.id in (
           select (it->>'profissional_id')::int from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
            where (it->>'servico_id')::int = p_servico_id and a.status not in ('disconfirm', 'removido')
              and a.data >= (now() at time zone 'America/Maceio')::date - 365)
         and not exists (select 1 from public.belasis_profissional_funcoes f
                          where f.profissional_id = p.id and f.funcao in ('recepcao', 'atelie', 'teste'))));
$function$;

create or replace function public.belasis_quem_faz(p_servico_id integer)
returns table (profissional_id integer, n bigint)
language sql
stable
set search_path to ''
as $function$
  select ap.id, (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                  where (it->>'servico_id')::int = p_servico_id and (it->>'profissional_id')::int = ap.id
                    and a.status not in ('disconfirm', 'removido')
                    and a.data >= (now() at time zone 'America/Maceio')::date - 365)
    from public.belasis_aptas(p_servico_id) ap(id)
   order by 2 desc;
$function$;

-- profissional da vez: prioritária do serviço (planilha) primeiro; depois quem tem menos atendimentos no dia;
-- depois quem recebeu agendamento pelo WhatsApp há mais tempo
create or replace function public.belasis_lista_da_vez(p_servico_id integer, p_data date)
returns table (profissional_id integer, ordem integer)
language sql
stable
set search_path to ''
as $function$
  with pri as (select prioritaria_sem_preferencia pid from public.belasis_servico_regras
                where servico_id = p_servico_id and prioritaria_sem_preferencia is not null)
  select q.profissional_id, (row_number() over (order by
           (q.profissional_id in (select pid from pri)) desc,
           (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
             where a.data = p_data and a.status not in ('disconfirm', 'removido')
               and (it->>'profissional_id')::int = q.profissional_id),
           (select max(pa.criado_em) from public.pre_agendamentos pa where pa.profissional_id = q.profissional_id) nulls first,
           q.n desc))::int
    from public.belasis_quem_faz(p_servico_id) q;
$function$;

-- horários: nunca devolve nome de profissional (o agente não oferece nomes)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.belasis_horarios_disponiveis(text,date,text,integer,time)'::regprocedure);
  if position('x - ''profissional''' in d) = 0 then
    d := replace(d, $x$'horarios_livres', v_res,$x$,
                    $x$'horarios_livres', (select coalesce(jsonb_agg(x - 'profissional'), '[]') from jsonb_array_elements(v_res) x),$x$);
    d := replace(d, $x$jsonb_agg(x order by dif)$x$, $x$jsonb_agg(x - 'profissional' order by dif)$x$);
    if position('x - ''profissional''' in d) = 0 then raise exception 'horarios: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

-- catálogo: nomes só para quando a cliente perguntar
do $$
declare d text;
begin
  d := pg_get_functiondef('public.consultar_servicos(text,integer)'::regprocedure);
  if position('quem_faz_so_se_a_cliente_perguntar' in d) = 0 then
    d := replace(d, $x$'quem_faz', (select$x$, $x$'quem_faz_so_se_a_cliente_perguntar', (select$x$);
    if position('quem_faz_so_se_a_cliente_perguntar' in d) = 0 then raise exception 'consultar_servicos: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

create or replace function public.agendar_whatsapp(p_conversa_id uuid, p_servico text, p_data date, p_hora time,
  p_profissional text default null, p_confirmacao text default null, p_observacao text default null,
  p_sem_preferencia boolean default false, p_nome_completo text default null, p_nascimento date default null,
  p_remarcar boolean default false, p_complemento boolean default false)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v_fuso  text := coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
  v_quando timestamptz := (p_data + p_hora) at time zone v_fuso;
  v_serv  integer := public.belasis_resolver_servico(p_servico);
  v_dur   integer;
  v_pid   integer;
  v_livre boolean;
  v_nome  text;
  v_res   jsonb;
  v_ant_id integer;
  v_ant_data date;
  v_ant_ini text;
  v_fim   time;
  v_sug   jsonb := '[]';
  v_unica integer;
  r       record;
  v_prof  text := nullif(btrim(coalesce(p_profissional, '')), '');
begin
  if v_quando < now() then
    return jsonb_build_object('ok', false, 'erro', 'data_no_passado', 'orientacao', 'Esse horário já passou. Pergunte outro.');
  end if;
  if not public.salao_aberto(v_quando) then
    return jsonb_build_object('ok', false, 'erro', 'fora_do_horario',
      'orientacao', 'O salão funciona de terça a sábado, das 9h às 18h. Peça outro dia/horário.');
  end if;
  if v_serv is null then
    return jsonb_build_object('ok', false, 'erro', 'servico_nao_encontrado',
      'orientacao', 'Não achei esse serviço no catálogo. Use consultar_servicos e confirme com a cliente qual é.');
  end if;
  select coalesce(duracao_min, 60) into v_dur from public.belasis_servicos where id = v_serv;
  select profissional_id into v_unica from public.belasis_servico_regras where servico_id = v_serv and quem = 'unica';

  if not p_complemento and not public.hora_mencionada(p_conversa_id, p_hora) then
    return jsonb_build_object('ok', false, 'erro', 'hora_nao_informada',
      'orientacao', 'A cliente ainda não escolheu o horário. Pergunte que horário ela prefere (pode usar consultar_horarios e sugerir 2 ou 3). Não escolha por ela.');
  end if;

  -- serviço que só uma profissional faz: não precisa perguntar preferência
  if v_prof is null and v_unica is not null then
    select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_prof from public.belasis_profissionais where id = v_unica and ativo;
  end if;

  if v_prof is null and not p_sem_preferencia and not p_complemento then
    return jsonb_build_object('ok', false, 'erro', 'perguntar_profissional',
      'orientacao', 'Pergunte só "tem preferência de profissional?". Não cite nenhum nome. Se ela não tiver preferência, chame de novo com sem_preferencia=true (o salão segue a profissional da vez).');
  end if;

  if not exists (select 1 from public.belasis_clientes_da_conversa(p_conversa_id)) then
    if nullif(btrim(coalesce(p_nome_completo, '')), '') is null
       and coalesce((select btrim(nome) from public.conversas where id = p_conversa_id), '') !~ '\S+\s+\S+' then
      return jsonb_build_object('ok', false, 'erro', 'precisa_cadastro',
        'orientacao', 'Ela ainda não tem cadastro no salão. Pergunte, numa mensagem só e com leveza, o nome completo e a data de nascimento (pra fazer o cadastro e ela receber a confirmação). Se ela disser que já é cliente, peça o nome completo do cadastro.');
    end if;
    if nullif(btrim(coalesce(p_nome_completo, '')), '') is not null then
      update public.conversas set nome = initcap(btrim(p_nome_completo)), nascimento = coalesce(p_nascimento, nascimento)
       where id = p_conversa_id;
    end if;
  end if;

  if v_prof is not null then
    v_pid := public.belasis_resolver_profissional(v_prof);
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrada',
        'orientacao', 'Não achei essa profissional. Pergunte de novo o nome ou se ela pode ser atendida pela profissional da vez. Não cite nomes.');
    end if;
    if v_pid not in (select public.belasis_aptas(v_serv))
       and not exists (select 1 from public.belasis_profissional_funcoes f where f.profissional_id = v_pid and f.funcao = 'teste') then
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_faz',
        'orientacao', case when v_unica is not null
          then 'Esse serviço é feito só pela ' || (select public.belasis_nome_curto(apelido, apelido_belasis, nome) from public.belasis_profissionais where id = v_unica) || '. Diga isso com leveza e pergunte se pode ser com ela.'
          else 'Essa profissional não faz esse serviço. Diga com leveza e pergunte se ela tem outra preferência ou se pode ser com a profissional da vez. Não cite nomes.' end);
    end if;
    v_livre := public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur);
    if v_livre = false then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Esse horário não está livre com essa profissional. Pergunte se ela prefere outro horário com a mesma profissional (ofereça 2 ou 3 de livres_com_ela) ou se pode ser com outra profissional nesse horário (sem citar nomes; se aceitar, chame de novo com sem_preferencia=true). Nunca agende com outra sem ela aceitar.',
        'livres_com_ela', public.belasis_horarios_disponiveis(p_servico, p_data, v_prof, 30, p_hora) -> 'mais_proximos',
        'tem_outra_livre_nesse_horario', v_unica is null and jsonb_array_length(public.belasis_livres_no_horario(v_serv, p_data, p_hora)) > 0);
    end if;
  else
    for r in select l.profissional_id from public.belasis_lista_da_vez(v_serv, p_data) l order by l.ordem loop
      v_livre := public.belasis_profissional_livre(r.profissional_id, p_data, p_hora, v_dur);
      if v_livre is distinct from false then v_pid := r.profissional_id; exit; end if;
    end loop;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', case when exists (select 1 from public.belasis_quem_faz(v_serv)) then 'horario_ocupado' else 'sem_profissional' end,
        'orientacao', 'Ninguém livre nesse horário para esse serviço. Ofereça 2 ou 3 horários de livres_no_dia, sem citar nomes.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 30, p_hora) -> 'mais_proximos');
    end if;
  end if;

  if p_remarcar then
    select x.id, x.data, x.inicio into v_ant_id, v_ant_data, v_ant_ini from public.belasis_proximo_agendamento(p_conversa_id) x;
  end if;

  select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_nome from public.belasis_profissionais where id = v_pid;
  v_fim := (p_hora + make_interval(mins => v_dur))::time;
  v_res := public.criar_pre_agendamento(p_conversa_id, p_servico, p_data, p_hora, v_nome, v_serv, v_pid,
                                        v_fim, p_confirmacao, p_observacao);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;

  if v_ant_id is not null then
    perform public.belasis_enfileirar_cancelamento(v_ant_id, p_conversa_id, 'remarcação pelo WhatsApp');
  end if;

  -- venda casada: só serviço que tem alguém livre logo depois
  if not p_complemento then
    select coalesce(jsonb_agg(jsonb_build_object('servico', c->>'servico', 'hora', public.hora_curta(v_fim))), '[]') into v_sug
      from jsonb_array_elements(public.belasis_complementos(v_serv)) c
     where jsonb_array_length(public.belasis_livres_no_horario(public.belasis_resolver_servico(c->>'servico'), p_data, v_fim)) > 0;
  end if;

  return jsonb_build_object('ok', true, 'agendado', true,
    'servico', (select descricao from public.belasis_servicos where id = v_serv),
    'profissional', v_nome, 'dia', public.data_curta_pt(p_data), 'hora', public.hora_curta(p_hora),
    'termina', public.hora_curta(v_fim),
    'remarcado_de', case when v_ant_id is not null then public.data_curta_pt(v_ant_data) || ' às ' || public.hora_curta(v_ant_ini::time) end,
    'sugestao_complemento', v_sug,
    'orientacao', 'Diga que está agendado (dia, hora e profissional), curto e natural. Se houver sugestao_complemento, ofereça UMA, leve, sem preço e sem nome de profissional, para logo depois. Se ela topar, pergunte se tem preferência de profissional; sem preferência, chame agendar com complemento=true e sem_preferencia=true.');
end;
$function$;

-- n8n (CBK · Agente Core, 28/10): prompt "PROFISSIONAIS" — nunca oferecer nome; perguntar preferência;
-- sem preferência = profissional da vez; memória não sugere profissional de costume.
