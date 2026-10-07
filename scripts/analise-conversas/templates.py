import json, re, sys, collections
msgs = json.load(open(sys.argv[1]))
def norm(t):
    t = t.replace('⠀', ' ')
    t = re.sub(r'https?://\S+', '<URL>', t)
    t = re.sub(r'\d+', '#', t)
    t = re.sub(r'\s+', ' ', t).strip().lower()
    return t
sal = [m for m in msgs if m['autor'] == 'salao']
c = collections.Counter()
ex = {}
for m in sal:
    n = norm(m['texto'])
    # remove nome após "olá"/"oi"
    k = re.sub(r'^(ol[aá]|oi|oie)[ ,!]+[^,!.]{0,25}[,!]', r'\1 <nome>,', n)[:70]
    c[k] += 1; ex.setdefault(k, m['texto'][:300])
print('mensagens do salao:', len(sal))
for k, v in c.most_common(45):
    if v < 4: break
    print(f'{v:5d} | {k}')
