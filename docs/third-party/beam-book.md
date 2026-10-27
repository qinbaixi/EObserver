# The BEAM Book

EObserver bundles *The BEAM Book: Understanding the Erlang Runtime System*
for its knowledge cards and built-in reader (`web/src/beambook/data/`).

- Author: Erik Stenman and contributors — <https://github.com/happi/theBeamBook>,
  online at <https://blog.stenmans.org/theBeamBook/>
- Licence: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
- Chinese translation: Bycc, released under the same licence
- Changes: split into chapters, markup reduced to plain HTML, images
  recompressed (diagrams quantised, screenshots converted to JPEG); the text
  is unchanged.

## 中文说明

EObserver 内置了《The BEAM Book：理解 Erlang 运行时系统》，用于术语知识卡片和应用内阅读器。

- 原作者：Erik Stenman 及贡献者
- 许可协议：CC BY 4.0
- 中文翻译：Bycc，以相同协议发布
- 改动：按章节拆分、只保留基本 HTML 标记、重新压缩图片；正文未改动。

## Regenerating

```sh
python3 scripts/beambook/extract.py \
  --zh "The BEAM Book_ Understanding the Erlang Runtime System.zh-CN.html" \
  --en "The BEAM Book_ Understanding the Erlang Runtime System.html" \
  --files "The BEAM Book_ Understanding the Erlang Runtime System_files"
```

The inputs are the book's Asciidoctor HTML pages (English and Chinese) saved
with their images. Which sections each card quotes, the card a glossary term
opens and the cards each page offers are set in `web/src/beambook/terms.json`.
