#!/usr/bin/env python3
"""粗查 Swift 源文件的花括号/圆括号是否配平。

不是编译器，只是「写完一大段代码先自检一下」的工具：会先剥掉字符串字面量、
行注释和块注释，避免把 JSON 里的 { } 当成代码。CI 上真正的把关是 swiftc。

用法：python tools/check-swift-braces.py
"""

import glob
import os
import sys

QUOTE = chr(34)


def strip_swift(source):
    out = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = length if end < 0 else end
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index)
            index = length if end < 0 else end + 2
            continue
        if source.startswith(QUOTE * 3, index):
            end = source.find(QUOTE * 3, index + 3)
            index = length if end < 0 else end + 3
            out.append(" ")
            continue
        if char == QUOTE:
            index += 1
            while index < length:
                if source[index] == chr(92):
                    index += 2
                    continue
                if source[index] == QUOTE:
                    index += 1
                    break
                index += 1
            out.append(" ")
            continue
        out.append(char)
        index += 1
    return "".join(out)


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = sorted(glob.glob(os.path.join(repo, "Keyboard", "*.swift")))
    files += sorted(glob.glob(os.path.join(repo, "App", "*.swift")))
    files += sorted(glob.glob(os.path.join(repo, "Shared", "*.swift")))
    files.append(os.path.join(repo, "tools", "NineKeyCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "ChatLayoutCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "AppGroupProbeCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "SharedChatStoreCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "RecognizedChatContextCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "RecognizedChatAnalysisCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "LiveScreenCaptureCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "LiveChatRecognitionCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "LiveChatReviewCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "LiveChatAutoSyncCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "SharedChatUpdateCheck", "main.swift"))
    files.append(os.path.join(repo, "tools", "ChatScreenDetectionCheck", "main.swift"))
    bad = 0
    for path in files:
        with open(path, encoding="utf-8") as handle:
            stripped = strip_swift(handle.read())
        braces = stripped.count("{") - stripped.count("}")
        parens = stripped.count("(") - stripped.count(")")
        if braces or parens:
            bad += 1
            print("!! %s braces=%d parens=%d" % (os.path.basename(path), braces, parens))
    print("不配平的文件数：%d（共检查 %d 个）" % (bad, len(files)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
