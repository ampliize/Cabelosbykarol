import re, os, sys, json, collections
pasta = sys.argv[1]
rx = re.compile(r'^\[(\d+/\d+/\d+), (\d+:\d+:\d+\s?[AP]M)\] ([^:]+): (.*)$')
msgs = []
for f in sorted(os.listdir(pasta)):
    cur = None
    for line in open(os.path.join(pasta, f), encoding='utf-8', errors='replace'):
        line = line.rstrip('\n').replace('‎', '')
        m = rx.match(line)
        if m:
            cur = {'conv': f, 'data': m.group(1), 'hora': m.group(2), 'autor': 'salao' if m.group(3).strip() == 'Você' else 'cliente', 'texto': m.group(4)}
            msgs.append(cur)
        elif cur:
            cur['texto'] += '\n' + line
json.dump(msgs, open(sys.argv[2], 'w'), ensure_ascii=False)
c = collections.Counter(m['autor'] for m in msgs)
print(len(msgs), c)
datas = sorted(set(m['data'] for m in msgs), key=lambda d: (int(d.split('/')[2]), int(d.split('/')[0]), int(d.split('/')[1])))
print('periodo', datas[0], '->', datas[-1])
