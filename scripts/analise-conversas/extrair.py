import zipfile, io, sys, os, re
outer = zipfile.ZipFile(sys.argv[1]); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
n = 0
for i, info in enumerate(outer.infolist()):
    if not info.filename.endswith('.zip'): continue
    inner = zipfile.ZipFile(io.BytesIO(outer.read(info)))
    for f in inner.infolist():
        if f.filename.lower().endswith('.txt') and f.file_size < 5_000_000:
            data = inner.read(f).decode('utf-8', 'replace')
            open(os.path.join(out, f'conv_{i:02d}.txt'), 'w').write(data)
            n += 1
    print(i, [x.filename for x in inner.infolist()][:6])
print('txt extraidos', n)
