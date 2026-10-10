-- O Belasis guarda o nome completo das profissionais; o agente usa só o primeiro nome.
do $$
declare
  f text;
  v_def text;
begin
  foreach f in array array['public.perfil_cliente_belasis(text)', 'public.consultar_servicos(text,integer)'] loop
    v_def := pg_get_functiondef(f::regprocedure);
    execute replace(v_def, 'p.nome', 'split_part(p.nome, '' '', 1)');
  end loop;
end $$;
