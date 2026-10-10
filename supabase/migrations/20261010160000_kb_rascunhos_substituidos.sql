-- Preços e lista de profissionais tirados das conversas (rascunho) foram substituídos
-- pelo catálogo real do Belasis (consultar_servicos).
update public.kb_itens set ativo = false, atualizado_em = now()
 where fonte = 'historico_whatsapp' and aprovado = false and (categoria = 'preco' or pergunta like 'Quais profissionais%');
