-- Produção (28/10): mesma instância Evolution; avisos passam a ir para a equipe real
-- (recepção no expediente → Emilly → Tauã; alertas de sistema para o Tauã).
update public.config_bot set valor = 'null'::jsonb where chave = 'encaminhar_somente_para';
update public.equipe set ativo = false where telefone = '5511922185643';
