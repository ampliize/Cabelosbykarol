// belasis-sync — leitura (somente GET) da API Belasis para o banco do agente.
// Chamada pelo pg_cron (public.belasis_disparar_sync) a cada minuto enquanto há fila.
// Autenticação: header x-cbk-secret (mesmo segredo do Vault). A chave Belasis fica
// só nos segredos das Edge Functions (BELASIS_ACCESS_TOKEN ou qualquer valor "bpk_...").
import { createClient } from "npm:@supabase/supabase-js@2";

const LOTE = 15;            // ≤ 15 requisições por execução (limite Belasis: 30/min)
const INTERVALO_MS = 1500;  // espaçamento entre chamadas

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function tokenBelasis(): string | undefined {
  const direto = Deno.env.get("BELASIS_ACCESS_TOKEN");
  if (direto) return direto.trim();
  for (const [, v] of Object.entries(Deno.env.toObject())) {
    if (typeof v === "string" && v.trim().startsWith("bpk_")) return v.trim();
  }
  return undefined;
}

Deno.serve(async (req) => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const { data: autorizado } = await db.rpc("checar_segredo_interno", {
    p_segredo: req.headers.get("x-cbk-secret") ?? "",
  });
  if (!autorizado) return json({ erro: "não autorizado" }, 401);

  const { data: cfg } = await db.from("config_bot").select("chave, valor")
    .in("chave", ["belasis_modo", "belasis_base_url"]);
  const conf = Object.fromEntries((cfg ?? []).map((c: { chave: string; valor: unknown }) => [c.chave, c.valor]));
  if (!conf.belasis_modo || conf.belasis_modo === "desligado") return json({ ok: false, motivo: "belasis_desligado" });
  const base = String(conf.belasis_base_url ?? "https://api.belasis.com.br/api/v1").replace(/\/$/, "");

  const token = tokenBelasis();
  if (!token) return json({ ok: false, motivo: "chave Belasis não encontrada nos segredos" }, 500);

  const { data: itens, error } = await db.rpc("belasis_proximos", { p_limite: LOTE });
  if (error) return json({ ok: false, erro: error.message }, 500);

  const resumo = { processados: 0, erros: 0, parou_429: false };
  const pendentes = [...(itens ?? [])];

  while (pendentes.length) {
    const it = pendentes.shift()!;
    const url = new URL(base + it.caminho);
    for (const [k, v] of Object.entries(it.query ?? {})) url.searchParams.set(k, String(v));

    const inicio = Date.now();
    let status = 0, corpo: unknown = null, erro: string | null = null;
    try {
      const r = await fetch(url, {
        method: "GET",
        headers: { "ACCESS-TOKEN": token, "Accept": "application/json" },
        signal: AbortSignal.timeout(20000),
      });
      status = r.status;
      const txt = await r.text();
      try { corpo = txt ? JSON.parse(txt) : null; } catch { corpo = null; erro = txt.slice(0, 300); }
      if (!r.ok && !erro) erro = JSON.stringify(corpo)?.slice(0, 300) ?? `HTTP ${status}`;
    } catch (e) {
      erro = String(e).slice(0, 300);
    }
    const ms = Date.now() - inicio;

    await db.rpc("belasis_registrar_resposta", { p_id: it.id, p_status: status, p_resposta: corpo, p_erro: erro });
    await db.rpc("belasis_log_get", { p_caminho: it.caminho, p_status: status, p_ms: ms, p_erro: erro });
    resumo.processados++;
    if (status < 200 || status > 299) resumo.erros++;

    if (status === 429) {
      resumo.parou_429 = true;
      break;
    }
    if (pendentes.length) await new Promise((r) => setTimeout(r, INTERVALO_MS));
  }

  // o que sobrou (por 429) volta para a fila
  if (pendentes.length) {
    await db.from("belasis_fila").update({ estado: "pendente" }).in("id", pendentes.map((p) => p.id));
  }
  return json({ ok: true, ...resumo, devolvidos: pendentes.length });
});
