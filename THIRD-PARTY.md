# 第三方数据与代码

## 九键拼音词库

`Keyboard/pinyin-chars.tsv` 与 `Keyboard/pinyin-words.tsv` 由 [`tools/fetch-pinyin-data.py`](tools/fetch-pinyin-data.py)
从下面三份 **MIT 许可** 的数据生成（生成结果入库，构建时不需要联网）：

| 来源 | 用它的哪部分 | 许可 |
|---|---|---|
| [fxsjy/jieba](https://github.com/fxsjy/jieba)（`jieba/dict.txt`） | 词语 + 词频 —— 候选的**常用度排序**全靠它 | MIT |
| [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data)（`pinyin.txt`） | 单个汉字 → 拼音（含多音字） | MIT |
| [mozillazg/phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data)（`pinyin.txt`） | 词语 → 拼音，修正多音字（银行 yín háng） | MIT |

生成脚本做了三件事：去声调统一成 ASCII 拼音；用词频给候选排序；把结果压成两份 TSV
（`#rank` 行是全局常用度排序，用来把不同音节的候选字混排）。

## 军师人格

`Keyboard/GoutouSkill.md` 是 Android 仓库里 `function-kits/goutoujunshi/skills/goutoujunshi/SKILL.md`
的原样拷贝（sha256 一致），两边共用同一份人格口径。
