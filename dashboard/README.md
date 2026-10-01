# Painel do Agente

Página única (`index.html`) que lê `dashboard_dados(dias)` no Supabase.

- **Demonstração (dados fictícios):** abra `index.html?demo=1`.
- **Acesso real:** login por código enviado ao e-mail. Só entra quem estiver em `painel_usuarios`:

```sql
insert into painel_usuarios (email, nome) values ('karol@exemplo.com', 'Karol');
```

O e-mail também precisa existir em Supabase → Authentication → Users (botão "Invite user"),
porque o login não cria usuários novos.

**Publicar:** é um site estático (`index.html` + `config.js`). Pode ir para Vercel, Netlify,
Cloudflare Pages, Lovable ou qualquer hospedagem. Em Supabase → Authentication → URL Configuration,
adicione a URL publicada.

**O que mostra:** conversas, % resolvidas só pelo agente, agendamentos, transferências,
% respondidas pela equipe dentro de 3 min, encaminhamentos ao responsável (e se foram entregues),
conversas que estão com a equipe agora e quando o agente volta, motivos de transferência,
horários de pico, tempo de resposta do agente, erros e uso de IA. Atualiza sozinho a cada minuto.
