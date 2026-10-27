#!/usr/bin/env python3
"""Turn The BEAM Book HTML (English original + Chinese translation) into the
data the web UI bundles for knowledge cards and the built-in book reader.

    python3 scripts/beambook/extract.py \
        --zh "The BEAM Book_ ... .zh-CN.html" \
        --en "The BEAM Book_ ... .html" \
        --files "The BEAM Book_ ..._files"

Both HTML files are Asciidoctor output saved from the browser; they share
section ids, so a card or a link points at the same place in either
language. Writes web/src/beambook/data/ (run from anywhere). Needs
beautifulsoup4 and Pillow.

The book is by Erik Stenman and licensed CC BY 4.0; the Chinese translation
is by Bycc. See docs/third-party/beam-book.md.
"""
import argparse
import copy
import json
import os
import re
import shutil
import sys

from bs4 import BeautifulSoup, NavigableString, Tag
from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
WEB = os.path.join(ROOT, 'web', 'src', 'beambook')
OUT = os.path.join(WEB, 'data')

KEEP_ATTRS = {'class', 'id', 'href', 'src', 'alt', 'width', 'height', 'colspan', 'rowspan', 'data-lang', 'start', 'type'}
SECT = re.compile(r'^sect[0-5]$')
# Characters of Chinese text a card takes from each section before it stops
# at the next block boundary (the English card takes the same blocks).
CARD_BUDGET = 700


def load(path):
    with open(path, encoding='utf-8') as f:
        return BeautifulSoup(f.read(), 'html.parser')


def text(el):
    return re.sub(r'\s+', ' ', el.get_text(' ', strip=True)).strip()


def is_section(el):
    return isinstance(el, Tag) and any(SECT.match(c) for c in el.get('class', []))


CJK = re.compile('[\u2e80-\u9fff\u3000-\u303f\uff00-\uffef]')
LINE_BREAK = re.compile(r'[ \t]*\n\s*')


def join_lines(el):
    """The translation is wrapped at arbitrary points; a line break between
    two Chinese characters would show as a space. Code blocks keep theirs."""
    def join(m):
        text, a, b = m.string, m.start(), m.end()
        cjk = a > 0 and b < len(text) and CJK.match(text[a - 1]) and CJK.match(text[b])
        return '' if cjk else ' '
    for s in el.find_all(string=True):
        if '\n' in s and s.find_parent('pre') is None:
            s.replace_with(LINE_BREAK.sub(join, str(s)))


def clean(el, images, card=False):
    """Copy of el with only safe markup left. Links into the book become
    data-ref anchors the UI resolves; images point at the bundled files."""
    el = copy.copy(el)
    join_lines(el)
    for t in el.find_all(['script', 'style', 'link', 'meta']):
        t.decompose()
    if card:
        for t in el.find_all('sup', class_='footnote'):
            t.decompose()
    for t in [el, *el.find_all(True)]:
        for a in list(t.attrs):
            if a not in KEEP_ATTRS:
                del t.attrs[a]
        if card and t is not el and 'id' in t.attrs:
            del t.attrs['id']
        if t.name == 'a' and t.get('href'):
            href = t['href']
            if href.startswith('#'):
                t['data-ref'] = href[1:]
            else:
                t['target'] = '_blank'
                t['rel'] = 'noopener noreferrer'
        if t.name == 'img':
            name = os.path.basename(t.get('src', '').split('?')[0])
            t['src'] = 'bbimg:' + images.get(name, name)
            t['loading'] = 'lazy'
    # The font-awesome admonition icons render as nothing without the font.
    for t in el.find_all('i', class_='fa'):
        t.decompose()
    return el


def heading_of(sec):
    for c in sec.children:
        if isinstance(c, Tag) and re.match(r'^h[1-6]$', c.name):
            return c
    return None


def section_id(sec):
    h = heading_of(sec)
    return (h.get('id') if h is not None else None) or sec.get('id')


def own_blocks(sec):
    """The blocks a section opens with, before its first subsection."""
    out = []
    for c in sec.children:
        if not isinstance(c, Tag):
            continue
        if re.match(r'^h[1-6]$', c.name) or is_section(c):
            continue
        if 'sectionbody' in c.get('class', []):
            out.extend(own_blocks(c))
            continue
        out.append(c)
    return out


def book(soup, images):
    content = soup.find(id='content')
    for t in content.find_all(id='toc'):
        t.decompose()
    footnotes = {}
    fn = soup.find(id='footnotes')
    if fn:
        for d in fn.find_all('div', class_='footnote'):
            footnotes[d.get('id')] = d

    # Parts (I, II, appendices) only group chapters in the table of contents.
    chapters, anchors, sections = [], {}, {}
    part = None
    for c in content.children:
        if not isinstance(c, Tag):
            continue
        if c.name == 'h1' and 'sect0' in c.get('class', []):
            part = text(c)
            continue
        if 'sect1' in c.get('class', []):
            h = heading_of(c)
            chapters.append({'id': section_id(c), 'title': text(h), 'part': part, 'el': c})
            part = None

    toc = []
    for ch in chapters:
        el = ch['el']
        cid = ch['id']
        subs = []
        anchors[cid] = cid
        for t in el.find_all(True):
            if t.get('id'):
                anchors[t['id']] = cid
        for sec in el.find_all(class_=SECT):
            sid = section_id(sec)
            h = heading_of(sec)
            if not sid or h is None:
                continue
            level = int(h.name[1])
            sections[sid] = {'el': sec, 'chapter': cid, 'title': text(h)}
            if level <= 4:
                subs.append({'id': sid, 'title': text(h), 'level': level})
        entry = {'id': cid, 'title': ch['title'], 'sections': subs}
        if ch['part']:
            entry['part'] = ch['part']
        toc.append(entry)

        html = clean(el, images)
        refs = [a['data-ref'] for a in html.find_all('a', class_='footnote') if a.get('data-ref')]
        used = [footnotes[r] for r in dict.fromkeys(refs) if r in footnotes]
        body = str(html)
        if used:
            body += '<div class="footnotes"><hr>' + ''.join(str(clean(d, images)) for d in used) + '</div>'
        ch['html'] = body
        for d in used:
            anchors[d.get('id')] = cid
    return chapters, toc, anchors, sections


def optimise_images(files, out):
    """Copies the book's images, shrunk: diagrams are quantised PNGs and
    screenshots become JPEG. Returns original name -> bundled name."""
    os.makedirs(out, exist_ok=True)
    names = {}
    for name in sorted(os.listdir(files)):
        src = os.path.join(files, name)
        base, ext = os.path.splitext(name)
        if ext.lower() not in ('.png', '.jpg', '.jpeg'):
            continue
        img = Image.open(src)
        if name.startswith('diag-'):
            dst = base + '.png'
            q = img.convert('RGBA').quantize(colors=32, method=Image.Quantize.FASTOCTREE)
            q.save(os.path.join(out, dst), optimize=True)
            if os.path.getsize(os.path.join(out, dst)) > os.path.getsize(src):
                shutil.copyfile(src, os.path.join(out, dst))
        else:
            dst = base + '.jpg'
            img.convert('RGB').save(os.path.join(out, dst), quality=82, optimize=True, progressive=True)
        names[name] = dst
    return names


def card_html(blocks, images):
    return ''.join(str(clean(b, images, card=True)) for b in blocks)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--zh', required=True)
    ap.add_argument('--en', required=True)
    ap.add_argument('--files', required=True)
    args = ap.parse_args()

    with open(os.path.join(WEB, 'terms.json'), encoding='utf-8') as f:
        terms = json.load(f)

    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    images = optimise_images(args.files, os.path.join(OUT, 'img'))

    parsed = {}
    for lang, path in (('zh', args.zh), ('en', args.en)):
        chapters, toc, anchors, sections = book(load(path), images)
        parsed[lang] = sections
        os.makedirs(os.path.join(OUT, lang))
        for ch in chapters:
            with open(os.path.join(OUT, lang, ch['id'] + '.json'), 'w', encoding='utf-8') as f:
                json.dump({'id': ch['id'], 'title': ch['title'], 'html': ch['html']}, f, ensure_ascii=False, separators=(',', ':'))
        with open(os.path.join(OUT, f'toc.{lang}.json'), 'w', encoding='utf-8') as f:
            json.dump({'chapters': toc, 'anchors': anchors}, f, ensure_ascii=False, separators=(',', ':'))

    # Cards: the same number of opening blocks per section in both languages,
    # chosen by the length of the Chinese text.
    cards = {'zh': {}, 'en': {}}
    problems = []
    for cid, card in terms['cards'].items():
        for lang in cards:
            cards[lang][cid] = []
        for sid in card['sections']:
            zh, en = parsed['zh'].get(sid), parsed['en'].get(sid)
            if not zh or not en:
                problems.append(f'{cid}: no section {sid}')
                continue
            zb, eb = own_blocks(zh['el']), own_blocks(en['el'])
            if len(zb) != len(eb):
                problems.append(f'{cid}: {sid} has {len(zb)} zh blocks, {len(eb)} en blocks')
            n, used = 0, 0
            budget = card.get('budget', CARD_BUDGET)
            for b in zb:
                if n and used + len(text(b)) > budget:
                    break
                used += len(text(b))
                n += 1
            if n == 0:
                problems.append(f'{cid}: {sid} has no opening text')
            for lang, sec, blocks in (('zh', zh, zb), ('en', en, eb)):
                cards[lang][cid].append({
                    'id': sid, 'chapter': sec['chapter'], 'title': sec['title'],
                    'html': card_html(blocks[:n], images),
                    'more': n < len(blocks) or bool(sec['el'].find(class_=SECT)),
                })
    for lang, data in cards.items():
        with open(os.path.join(OUT, f'cards.{lang}.json'), 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
    for p in problems:
        print('warning:', p, file=sys.stderr)
    print(f'wrote {OUT}: {len(terms["cards"])} cards, {len(images)} images')


if __name__ == '__main__':
    main()
