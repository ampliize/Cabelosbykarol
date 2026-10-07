-- Prints de 08/10: "Garanta retornos" (novo padrão), aniversário e lembretes de 3h/24h
-- (já cobertos por "feliz aniversário", "é hoje!" e "encontro marcado").
update public.config_bot
   set valor = valor || '["temos um lembrete especial para voc[eê]", "hora de renovar o seu"]'::jsonb
 where chave = 'padroes_mensagens_automaticas'
   and not valor ? 'hora de renovar o seu';
