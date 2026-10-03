import sys, re
from pypdf import PdfReader
R='C:/Users/Usuario/Desktop/EIE/scratchpad-remitos-compra/pdf/'
def txt(f): return "\n".join(p.extract_text() for p in PdfReader(R+f).pages)
res=[]
def chk(n, ok, d=''):
    res.append(ok); print(('PASS ' if ok else 'FAIL ')+n, d[:140])
a=txt('remito-compra-sin-precios.pdf'); b=txt('remito-compra-con-precios.pdf'); c=txt('remito-compra-anulado.pdf')
for name,t in (('sin precios',a),('con precios',b)):
    chk(f'{name}: titulo REMITO DE COMPRA', 'REMITO DE COMPRA' in t.upper())
    chk(f'{name}: numero RC-', re.search(r'RC-\d{8}',t) is not None)
    chk(f'{name}: Recibido de + proveedor', 'Recibido de' in t and 'Proveedor Demo QA' in t)
    chk(f'{name}: remito del proveedor N 0004-00005555', '0004-00005555' in t)
    chk(f'{name}: Ingresa a + sucursal destino', 'Ingresa a' in t and 'Casa Central' in t)
    chk(f'{name}: cantidades con unidad (kg)', re.search(r'1[,.]5\d* ?kg',t) is not None, t[t.find('Harina'):t.find('Harina')+80].replace('\n',' '))
    chk(f'{name}: bloque de firma', 'Firma' in t and ('Aclaraci' in t) and 'DNI' in t)
    chk(f'{name}: leyenda no valido como factura', 'no válido como factura' in t or 'no valido como factura' in t.lower())
chk('sin precios: NO imprime precios ni total', '$' not in a and 'Total' not in a, a[-200:].replace('\n',' '))
chk('con precios: imprime precio, subtotal y total (1.5 x 700 = 1.050,00)', '$' in b and ('1.050' in b or '1050' in b), b[-260:].replace('\n',' '))
chk('anulado: sello ANULADO', 'ANULADO' in c.upper())
chk('sin precios: sin sello ANULADO (remito vigente)', 'ANULADO' not in a.upper())
sys.exit(0 if all(res) else 1)
