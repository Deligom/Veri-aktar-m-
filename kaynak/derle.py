#!/usr/bin/env python3
"""Yayınlanan dosyaları kaynaktan üretir.

kaynak/index.html içindeki /*__LIBS__*/ yerine kaynak/libs.js (QR üretme: qrcode-generator, MIT;
QR okuma: jsQR, Apache-2.0) gömülür ve sonuç kök dizindeki index.html'e yazılır.
sw.js ve manifest.webmanifest de köke kopyalanır.

Kullanım:  python3 kaynak/derle.py
"""
from pathlib import Path

kaynak = Path(__file__).resolve().parent
kok = kaynak.parent

html = (kaynak / 'index.html').read_text(encoding='utf-8')
libs = (kaynak / 'libs.js').read_text(encoding='utf-8')
assert html.count('/*__LIBS__*/') == 1, 'index.html içinde tek bir /*__LIBS__*/ olmalı'
assert '</script' not in libs, 'libs.js içinde </script geçmemeli'
(kok / 'index.html').write_text(html.replace('/*__LIBS__*/', libs), encoding='utf-8')
for ad in ('sw.js', 'manifest.webmanifest'):
    (kok / ad).write_text((kaynak / ad).read_text(encoding='utf-8'), encoding='utf-8')
print('index.html, sw.js, manifest.webmanifest güncellendi')
