#!/usr/bin/env python3
"""Writes the .docx fixtures next to this script. Hand-written OOXML, so no dependencies.

Each fixture isolates one feature, so a lost table or image points at one file.
Run: python3 make_docx_fixtures.py
"""
import struct
import zipfile
import zlib
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).parent
W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" ' \
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' \
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" ' \
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' \
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"'

A4_SECTION = '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>' \
             '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/></w:sectPr>'

STYLES = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles {W}>
  <w:docDefaults><w:rPrDefault><w:rPr>
    <w:rFonts w:ascii="Apple SD Gothic Neo" w:eastAsia="Apple SD Gothic Neo" w:hAnsi="Apple SD Gothic Neo"/>
    <w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>
  <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>
    <w:pPr><w:ind w:left="720"/></w:pPr></w:style>
</w:styles>'''

NUMBERING = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering {W}>
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
    <w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="◦"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="1">
    <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
</w:numbering>'''


def run(text, *, bold=False, italic=False, underline=False, color=None, size_pt=None):
    props = ''
    props += '<w:b/>' if bold else ''
    props += '<w:i/>' if italic else ''
    props += '<w:u w:val="single"/>' if underline else ''
    props += f'<w:color w:val="{color}"/>' if color else ''
    props += f'<w:sz w:val="{size_pt * 2}"/>' if size_pt else ''
    rpr = f'<w:rPr>{props}</w:rPr>' if props else ''
    return f'<w:r>{rpr}<w:t xml:space="preserve">{escape(text)}</w:t></w:r>'


def para(*runs, style=None, align=None, num=None):
    ppr = ''
    ppr += f'<w:pStyle w:val="{style}"/>' if style else ''
    ppr += f'<w:numPr><w:ilvl w:val="{num[1]}"/><w:numId w:val="{num[0]}"/></w:numPr>' if num else ''
    ppr += f'<w:jc w:val="{align}"/>' if align else ''
    body = ''.join(r if r.startswith('<w:') else run(r) for r in runs)
    return f'<w:p>{f"<w:pPr>{ppr}</w:pPr>" if ppr else ""}{body}</w:p>'


def cell(text, *, span=1, shade=None, bold=False):
    tcpr = f'<w:tcW w:w="{3000 * span}" w:type="dxa"/>'
    tcpr += f'<w:gridSpan w:val="{span}"/>' if span > 1 else ''
    tcpr += f'<w:shd w:val="clear" w:color="auto" w:fill="{shade}"/>' if shade else ''
    return f'<w:tc><w:tcPr>{tcpr}</w:tcPr>{para(run(text, bold=bold))}</w:tc>'


def table(rows):
    border = ''.join(f'<w:{side} w:val="single" w:sz="4" w:space="0" w:color="000000"/>'
                     for side in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'))
    grid = '<w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>'
    body = ''.join(f'<w:tr>{"".join(r)}</w:tr>' for r in rows)
    return f'<w:tbl><w:tblPr><w:tblW w:w="9000" w:type="dxa"/><w:tblBorders>{border}</w:tblBorders></w:tblPr>{grid}{body}</w:tbl>'


def image(rel_id, width_in, height_in):
    cx, cy = int(width_in * 914400), int(height_in * 914400)
    return f'''<w:r><w:drawing><wp:inline><wp:extent cx="{cx}" cy="{cy}"/><wp:docPr id="1" name="Picture 1"/>
<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>
<pic:nvPicPr><pic:cNvPr id="1" name="image1.png"/><pic:cNvPicPr/></pic:nvPicPr>
<pic:blipFill><a:blip r:embed="{rel_id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>'''


def png(width, height, rgb):
    """A solid-color PNG with a 4px black border, so a stretched or cropped image is visible."""
    rows = b''
    for y in range(height):
        row = b'\x00'
        for x in range(width):
            edge = x < 4 or y < 4 or x >= width - 4 or y >= height - 4
            row += b'\x00\x00\x00' if edge else bytes(rgb)
        rows += row

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def write_docx(name, body, *, media=None, parts=None, section=A4_SECTION):
    """`parts` maps a relationship id to (kind, filename, xml), e.g. ('header', 'header1.xml', ...)."""
    rels = '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' \
           '<Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
    for rel_id, filename, _ in media or []:
        rels += f'<Relationship Id="{rel_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/{filename}"/>'
    overrides = ''
    for rel_id, (kind, filename, _) in (parts or {}).items():
        rels += f'<Relationship Id="{rel_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/{kind}" Target="{filename}"/>'
        overrides += f'<Override PartName="/word/{filename}" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.{kind}+xml"/>'
    with zipfile.ZipFile(HERE / name, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml', f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Default Extension="png" ContentType="image/png"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
{overrides}
</Types>''')
        z.writestr('_rels/.rels', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''')
        z.writestr('word/_rels/document.xml.rels', f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">{rels}</Relationships>''')
        z.writestr('word/styles.xml', STYLES)
        z.writestr('word/numbering.xml', NUMBERING)
        for _, filename, data in media or []:
            z.writestr(f'word/media/{filename}', data)
        for _, filename, xml in (parts or {}).values():
            z.writestr(f'word/{filename}', xml)
        z.writestr('word/document.xml', f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document {W}><w:body>{body}{section}</w:body></w:document>''')


write_docx('formatting.docx', ''.join([
    para('주간 회의록', style='Heading1'),
    para(run('굵게', bold=True), ' · ', run('기울임', italic=True), ' · ', run('밑줄', underline=True),
         ' · ', run('주황색', color='FF5A1F'), ' · ', run('20pt 글자', size_pt=20)),
    para('가운데 정렬된 문단', align='center'),
    para('오른쪽 정렬된 문단', align='right'),
    para('English and 한국어 mixed in one paragraph, with numbers 1,234.56 and symbols ※ → ①.'),
    # Word often splits words into runs and puts a lone space in its own run.
    para('int', ' ', 'buffer[100];'),
]))

write_docx('table.docx', ''.join([
    para('TABLE-BEFORE'),
    table([
        [cell('항목', shade='D9D9D9', bold=True), cell('담당', shade='D9D9D9', bold=True), cell('기한', shade='D9D9D9', bold=True)],
        [cell('디자인 시안'), cell('지수'), cell('11/6')],
        [cell('엔진 스파이크'), cell('민호'), cell('11/15')],
        [cell('병합된 셀: 세 칸을 가로지르는 비고', span=3)],
    ]),
    para('TABLE-AFTER'),
]))

write_docx('lists.docx', ''.join([
    para('글머리 기호'),
    para('첫째 항목', num=(1, 0)),
    para('둘째 항목', num=(1, 0)),
    para('들여쓴 하위 항목', num=(1, 1)),
    para('번호 목록'),
    para('준비', num=(2, 0)),
    para('실행', num=(2, 0)),
    para('정리', num=(2, 0)),
]))

write_docx('image.docx', ''.join([
    para('IMAGE-BEFORE'),
    f'<w:p>{image("rIdImage1", 3, 1.5)}</w:p>',
    para('IMAGE-AFTER: 위 그림은 주황색 사각형(3×1.5인치, 검은 테두리)'),
]), media=[('rIdImage1', 'image1.png', png(300, 150, (0xFF, 0x5A, 0x1F)))])

write_docx('pagebreak.docx', ''.join([
    para('PAGE-ONE'),
    '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
    para('PAGE-TWO'),
]))

write_docx('long.docx', ''.join(
    para(f'문단 {i}. 긴 문서가 여러 쪽으로 나뉘는지 확인하는 문장입니다. ' * 2) for i in range(1, 201)
))

# A PAGE field whose cached result is a stale "99", as Word leaves it in saved files.
PAGE_FIELD = ('<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
              '<w:r><w:instrText xml:space="preserve"> PAGE  \\* MERGEFORMAT </w:instrText></w:r>'
              '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>99</w:t></w:r>'
              '<w:r><w:fldChar w:fldCharType="end"/></w:r>')
# Word's header template pins text to the right margin with an absolute tab.
HEADER = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:hdr {W}><w:p>'
          '<w:r><w:ptab w:relativeTo="margin" w:alignment="right" w:leader="none"/></w:r>'
          f'{run("HEADER-TEXT")}</w:p></w:hdr>')
FOOTER = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr {W}><w:p>{run("Page ")}{PAGE_FIELD}</w:p></w:ftr>'
write_docx('header-footer.docx', ''.join([
    para('BODY-ONE'),
    '<w:p><w:r><w:br w:type="page"/></w:r></w:p>',
    para('BODY-TWO'),
]), parts={
    'rIdHeader1': ('header', 'header1.xml', HEADER),
    'rIdFooter1': ('footer', 'footer1.xml', FOOTER),
}, section=A4_SECTION.replace(
    '<w:sectPr>',
    '<w:sectPr><w:headerReference w:type="default" r:id="rIdHeader1"/><w:footerReference w:type="default" r:id="rIdFooter1"/>',
))

print('\n'.join(sorted(p.name for p in HERE.glob('*.docx'))))
