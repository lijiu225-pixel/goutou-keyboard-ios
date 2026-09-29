#!/usr/bin/env python3
"""生成九键拼音词库（Keyboard/pinyin-chars.tsv + Keyboard/pinyin-words.tsv）。

三份 MIT 数据源（见仓库根目录 THIRD-PARTY.md）各管一段：

- fxsjy/jieba（dict.txt）            —— 词 + 词频。**它同时提供"常用度"**，
                                        没有它就无法给候选排序（拿纯词典排序会出现
                                        「泥」排在「你」前面这种荒唐结果）。
- mozillazg/pinyin-data（pinyin.txt） —— 单个汉字 → 拼音（带声调、含多音字）
- mozillazg/phrase-pinyin-data       —— 词语 → 拼音，权威处理多音字（银行 yín háng）

产出：
- pinyin-chars.tsv  `<韵母声母>\t<候选汉字，按词频排序>`
- pinyin-words.tsv  `<整串拼音>\t<候选词，按词频排序>`

用法：python tools/fetch-pinyin-data.py [缓存目录]
"""

import os
import sys
import unicodedata
import urllib.request

CHARS_URL = "https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt"
PHRASES_URL = "https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/master/pinyin.txt"
JIEBA_URL = "https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt"

MAX_CHARS_PER_SYLLABLE = 60
MAX_WORDS_PER_KEY = 6
MIN_WORD_LEN = 2
MAX_WORD_LEN = 3
MIN_WORD_FREQ = 120


def download(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print("下载", url)
    urllib.request.urlretrieve(url, path)
    return path


def strip_tone(syllable):
    decomposed = unicodedata.normalize("NFD", syllable.strip().lower())
    plain = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    plain = plain.replace("ü", "v").replace("u:", "v")
    return "".join(ch for ch in plain if "a" <= ch <= "z")


def freq_bucket(freq):
    """词频 → 0-9 的档位（位数-1，封顶 9）。App 只按档位粗排，够用且省字节。"""
    return min(9, max(0, len(str(int(freq))) - 1))


def parse_chars(path):
    """U+4E00: yī  # 一 → {char: [pinyin, ...]}（只留基本汉字区）"""
    table = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            code_part, _, rest = line.partition(":")
            try:
                char = chr(int(code_part.strip().lstrip("Uu+"), 16))
            except ValueError:
                continue
            if not ("\u4e00" <= char <= "\u9fff"):
                continue
            readings = [strip_tone(item) for item in rest.split("#")[0].split(",")]
            readings = [item for item in readings if item]
            if readings:
                table[char] = readings
    return table


def parse_phrases(path):
    """一丁点儿: yī dīng diǎn er → {word: [pinyin, ...]}"""
    table = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            word, _, reading = line.partition(":")
            word = word.strip()
            syllables = [strip_tone(item) for item in reading.split()]
            if word and syllables and len(syllables) == len(word):
                table[word] = syllables
    return table


def parse_jieba(path):
    """word freq tag → [(word, freq), ...]"""
    entries = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                entries.append((parts[0], int(parts[1])))
            except ValueError:
                continue
    return entries


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    cache = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TEMP", "/tmp"), "pinyin-data")

    chars = parse_chars(download(CHARS_URL, os.path.join(cache, "chars.txt")))
    phrases = parse_phrases(download(PHRASES_URL, os.path.join(cache, "phrases.txt")))
    jieba = parse_jieba(download(JIEBA_URL, os.path.join(cache, "jieba.txt")))
    print("数据源：汉字 %d，多音词条 %d，词典词条 %d" % (len(chars), len(phrases), len(jieba)))

    # 常用度：按词频加权统计每个字出现在多少"权重"的词里
    frequency = {}
    for word, freq in jieba:
        for char in set(word):
            frequency[char] = frequency.get(char, 0) + freq

    chars_by_syllable = {}
    for char, readings in chars.items():
        for index, syllable in enumerate(dict.fromkeys(readings)):
            # 多音字：非首选读音（治 chí、她 tā 之类）沉到后面，
            # 否则打 chi 会看到「她/治」排在「吃」前面。
            chars_by_syllable.setdefault(syllable, []).append((0 if index == 0 else 1, char))
    chars_out = {}
    for syllable, items in chars_by_syllable.items():
        ordered = sorted(items, key=lambda pair: (pair[0], -frequency.get(pair[1], 0), pair[1]))
        chars_out[syllable] = ordered[:MAX_CHARS_PER_SYLLABLE]

    words_by_pinyin = {}
    syllable_weight = {}
    for word, freq in jieba:
        if not (MIN_WORD_LEN <= len(word) <= MAX_WORD_LEN) or freq < MIN_WORD_FREQ:
            continue
        if any(char not in chars for char in word):
            continue
        readings = phrases.get(word)
        if readings is None:
            readings = [chars[char][0] for char in word]
        key = "".join(readings)
        words_by_pinyin.setdefault(key, []).append((freq, word))
        for syllable in readings:
            syllable_weight[syllable] = syllable_weight.get(syllable, 0) + freq
    words_out = {}
    for key, items in words_by_pinyin.items():
        items.sort(key=lambda pair: (-pair[0], pair[1]))
        # 词后面缀一位「频次档位」（0-9），App 用它把不同拼音切分出来的词放在一起排序：
        # 没有它，打 244326 会因为先切出 chi+dao 而把「赤道」排在「吃饭」前面。
        words_out[key] = [word + str(freq_bucket(freq)) for freq, word in items[:MAX_WORDS_PER_KEY]]

    chars_path = os.path.join(repo, "Keyboard", "pinyin-chars.tsv")
    words_path = os.path.join(repo, "Keyboard", "pinyin-words.tsv")
    with open(chars_path, "w", encoding="utf-8", newline="\n") as handle:
        # 音节也按常用度排，App 切分时就更可能先切出常用的读法
        for syllable in sorted(chars_out, key=lambda s: (-syllable_weight.get(s, 0), s)):
            primary = [char for flag, char in chars_out[syllable] if flag == 0]
            secondary = [char for flag, char in chars_out[syllable] if flag == 1]
            # 「首选读音的字 | 多音字里非首选的读法」——App 要分开排序，
            # 否则打 shui 会因为「说」有 shuì 这个读音而把「说」排在「水」前面。
            handle.write("%s\t%s|%s\n" % (syllable, "".join(primary), "".join(secondary)))
        # 最后一行是「全局常用度排序」：App 用它把不同音节的候选字混在一起排序，
        # 否则打 64（mi/ni 都成立）会先出一堆「米密秘」而不是「你」。
        global_order = sorted(chars.keys(), key=lambda ch: (-frequency.get(ch, 0), ch))
        handle.write("#rank\t%s\n" % "".join(global_order))
    with open(words_path, "w", encoding="utf-8", newline="\n") as handle:
        for key in sorted(words_out):
            handle.write("%s\t%s\n" % (key, "|".join(words_out[key])))

    print("写入 %s：%d 个音节，%d KB" % (chars_path, len(chars_out), os.path.getsize(chars_path) // 1024))
    print("写入 %s：%d 个拼音串，%d KB" % (words_path, len(words_out), os.path.getsize(words_path) // 1024))


if __name__ == "__main__":
    main()
