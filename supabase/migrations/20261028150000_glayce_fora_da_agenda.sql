-- Glayce: responsabilidade interna, nunca recebe agendamento (fica fora da lista da vez e dos serviços)
update public.belasis_profissional_funcoes set funcao = 'recepcao', atualizado_em = now() where profissional_id = 145692;
