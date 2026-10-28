-- Primeiro teste real (28/10): cliente manda a ideia picotada e a IA respondia a primeira parte.
-- Espera a cliente terminar: cada mensagem nova reinicia a janela (era 4 s, agora 12 s).
update public.config_bot set valor = '12'::jsonb where chave = 'janela_agrupamento_segundos';
-- n8n (CBK · Agente Core): o agente recebe todas as mensagens da cliente desde a última resposta
-- (mesmo assunto → 1 mensagem; assuntos diferentes → no máximo 2) e, se chegar mensagem nova
-- enquanto ele pensa, a resposta antiga é descartada e a execução seguinte responde tudo junto.
