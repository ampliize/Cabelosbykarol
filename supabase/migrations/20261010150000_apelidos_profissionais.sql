-- Apelidos usados pelas clientes (conversas reais e mensagens do Belasis: "Paty", "Lari Aux", "Eli.mani").
alter table public.belasis_profissionais add column if not exists apelido text;

update public.belasis_profissionais set apelido = 'Paty'  where nome ilike 'Patricia %';
update public.belasis_profissionais set apelido = 'Lari'  where nome ilike 'Erika Larissa%';
update public.belasis_profissionais set apelido = 'Eli'   where nome ilike 'Elielma %';
update public.belasis_profissionais set apelido = 'Thais' where nome ilike 'Thaislane %';

do $$
declare
  f text;
  v_def text;
begin
  foreach f in array array['public.perfil_cliente_belasis(text)', 'public.consultar_servicos(text,integer)'] loop
    v_def := pg_get_functiondef(f::regprocedure);
    execute replace(v_def, 'split_part(p.nome, '' '', 1)', 'coalesce(p.apelido, split_part(p.nome, '' '', 1))');
  end loop;
end $$;
