-- =====================================================================
-- 004 · Validação mais rígida de telefone brasileiro
-- Corrige: número estrangeiro de 11 dígitos (ex.: EUA 14155550100) era
-- tratado como DDD + celular brasileiro.
-- Regras: DDD 11–99; celular (9 dígitos) começa com 9; fixo/antigo (8) com 2–9.
-- =====================================================================
create or replace function public.normalizar_telefone(p text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  d text;
begin
  d := regexp_replace(split_part(split_part(coalesce(p, ''), '@', 1), ':', 1), '\D', '', 'g');
  if length(d) in (10, 11) then
    d := '55' || d;
  end if;
  if left(d, 2) <> '55' or length(d) not in (12, 13) then
    return null;
  end if;
  -- DDD válido (11–99)
  if substr(d, 3, 1) = '0' then
    return null;
  end if;
  if length(d) = 13 then
    -- celular: 9 dígitos começando com 9
    if substr(d, 5, 1) <> '9' then
      return null;
    end if;
  else
    -- 8 dígitos: fixo (2–5) ou celular antigo sem o 9º dígito (6–9)
    if substr(d, 5, 1) not in ('2','3','4','5','6','7','8','9') then
      return null;
    end if;
    if substr(d, 5, 1) in ('6','7','8','9') then
      d := left(d, 4) || '9' || substr(d, 5);
    end if;
  end if;
  return d;
end;
$$;

revoke all on function public.normalizar_telefone(text) from public, anon, authenticated;
grant execute on function public.normalizar_telefone(text) to service_role;
