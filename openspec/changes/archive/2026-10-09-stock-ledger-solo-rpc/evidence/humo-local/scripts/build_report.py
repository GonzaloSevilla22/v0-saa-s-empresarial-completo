# Genera REPORTE.md desde logs/10_resultados.jsonl (la tabla sale de los datos, no se transcribe a mano).
import json, re, io, os
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rows = [json.loads(l) for l in open(f'{H}/logs/10_resultados.jsonl', encoding='utf8') if l.strip()]
key = lambda r: (int(re.match(r'\d+', r['step']).group()), re.sub(r'\d+', '', r['step']))
rows.sort(key=key)
esc = lambda s: str(s).replace('|', chr(92) + '|').replace('\n', ' ')
def shots(s):
    out = []
    for n in [x.strip() for x in s.split(',') if x.strip()]:
        out.append(f'[{n}](screenshots/{n})' if n.endswith('.png') else f'[{n}](logs/{n})')
    return '<br>'.join(out)
head = '| Paso | Acción | Esperado | Observado | Resultado | Captura / log |\n|---|---|---|---|---|---|\n'
tab = head + '\n'.join(f"| {r['step']} | {esc(r['action'])} | {esc(r['expected'])} | {esc(r['observed'])} | **{r['result']}** | {shots(r['shots'])} |" for r in rows)
npass = sum(r['result'] == 'PASS' for r in rows)
open(f'{H}/logs/_tabla_resultados.md', 'w', encoding='utf8').write(tab + '\n')
print(len(rows), npass)
