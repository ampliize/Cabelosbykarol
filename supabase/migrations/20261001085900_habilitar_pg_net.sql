-- 005a · pg_net (HTTP a partir do banco) — usado pela retomada automática para acionar o n8n.
-- Aplicada separada: criar a extensão dentro de uma migration maior estoura o tempo do apply.
create extension if not exists pg_net;
