#!/usr/bin/env python3
"""从固定版本 ECDICT 生成应用随附的只读 SQLite 词库。"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import sqlite3
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
COMMIT = "bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b"
SHA256 = "1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf"
BASE_URL = f"https://raw.githubusercontent.com/skywind3000/ECDICT/{COMMIT}"


def prepare_dictionary(force=False):
    """校验源文件摘要，构建带词条和词形索引的数据库并原子替换。"""
    output = ROOT / "Sources/HyperTranslateCore/Resources/Dictionary.sqlite"
    if output.exists() and not force:
        print(f"使用已有词库：{output}")
        return
    cache = ROOT / ".cache/word-data"
    cache.mkdir(parents=True, exist_ok=True)
    source = cache / "ecdict.csv"
    if not source.exists():
        print("下载固定版本 ECDICT…", flush=True)
        urllib.request.urlretrieve(BASE_URL + "/ecdict.csv", source)
    if hashlib.sha256(source.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("词库源文件摘要不符，请删除 .cache/word-data/ecdict.csv 后重新下载。")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".building")
    temporary.unlink(missing_ok=True)
    connection = sqlite3.connect(temporary)
    connection.executescript("""
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE entries (
            word TEXT PRIMARY KEY COLLATE NOCASE, phonetic TEXT NOT NULL,
            definition TEXT NOT NULL, translation TEXT NOT NULL, pos TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE forms (
            form TEXT COLLATE NOCASE, lemma TEXT COLLATE NOCASE, priority INTEGER NOT NULL,
            PRIMARY KEY(form, lemma)
        ) WITHOUT ROWID;
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    with source.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            word = row["word"].strip()
            if not word:
                continue
            values = [word] + [row.get(key, "").replace("\\n", "\n")
                               for key in ["phonetic", "definition", "translation", "pos"]]
            connection.execute("INSERT OR IGNORE INTO entries VALUES (?, ?, ?, ?, ?)", values)
            for change in row.get("exchange", "").split("/"):
                if ":" not in change:
                    continue
                kind, value = change.split(":", 1)
                if not value or kind == "1":
                    continue
                form, lemma, priority = (word, value, 0) if kind == "0" else (value, word, 1)
                if form.lower() != lemma.lower():
                    connection.execute("""INSERT INTO forms VALUES (?, ?, ?)
                        ON CONFLICT(form, lemma) DO UPDATE SET priority=min(priority, excluded.priority)""",
                                       (form.lower(), lemma.lower(), priority))
    metadata = {"source": "ECDICT", "commit": COMMIT, "source_sha256": SHA256,
                "entries": connection.execute("SELECT count(*) FROM entries").fetchone()[0],
                "forms": connection.execute("SELECT count(*) FROM forms").fetchone()[0]}
    connection.executemany("INSERT INTO metadata VALUES (?, ?)", [(k, str(v)) for k, v in metadata.items()])
    connection.commit()
    connection.execute("VACUUM")
    assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    connection.close()
    temporary.replace(output)
    (ROOT / "ThirdParty/ECDICT-metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    license_path = ROOT / "ThirdParty/ECDICT-LICENSE.txt"
    if not license_path.exists():
        urllib.request.urlretrieve(BASE_URL + "/LICENSE", license_path)
    print(json.dumps(metadata, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="用固定源文件重新构建词库")
    prepare_dictionary(parser.parse_args().force)
