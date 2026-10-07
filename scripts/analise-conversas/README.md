# Análise das conversas exportadas do WhatsApp

Os dados das clientes **nunca** entram no repositório (ver `.gitignore`). Rode localmente:

```bash
python3 -I extrair.py Conversas.zip /tmp/conversas_txt      # zip de zips do export → chat.txt
python3 -I parse.py /tmp/conversas_txt /tmp/msgs.json      # mensagens com autor salão/cliente
python3 -I templates.py /tmp/msgs.json                     # modelos repetidos (mensagens automáticas)
```

Resultados e decisões: [docs/11-ANALISE-CONVERSAS.md](../../docs/11-ANALISE-CONVERSAS.md).
