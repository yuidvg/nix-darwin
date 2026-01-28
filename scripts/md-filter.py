#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python313 python313Packages.markitdown

# ==============================================================================
# MarkItDown Filter (Pure Nix Version)
# Usage: tar -cf - ./docs | md-filter | tar -x -C ./output
# ==============================================================================

import sys
import os
import tarfile
import tempfile
import io
import shutil

# nix-shellにより確実にインポート可能
try:
    from markitdown import MarkItDown
except ImportError:
    sys.stderr.write("Error: 'markitdown' not found. Ensure you are running with nix-shell.\n")
    sys.exit(1)

def main():
    # 入力がパイプライン(ストリーム)かどうかの簡易チェック
    if sys.stdin.isatty():
        print("Usage: This is a pipe filter. Use it like:")
        print("  tar -cf - src_dir | md-filter | tar -x -C out_dir")
        sys.exit(1)

    md = MarkItDown()

    try:
        # 入力ストリーム (標準入力)
        input_tar = tarfile.open(fileobj=sys.stdin.buffer, mode='r|*')
        # 出力ストリーム (標準出力)
        output_tar = tarfile.open(fileobj=sys.stdout.buffer, mode='w|')
    except Exception as e:
        sys.stderr.write(f"Error opening tar streams: {e}\n")
        sys.exit(1)

    # 展開・変換用の一時領域 (プロセス終了と共に消滅)
    with tempfile.TemporaryDirectory() as temp_dir:
        for member in input_tar:
            if not member.isfile():
                continue

            # セキュリティ: パストラバーサル対策
            clean_name = os.path.normpath(member.name)
            if clean_name.startswith("..") or os.path.isabs(clean_name):
                continue

            # 一時ファイルとして書き出し
            # (MarkItDownはファイル拡張子を見てパーサを選ぶため、ファイル化が必須)
            temp_path = os.path.join(temp_dir, clean_name)
            os.makedirs(os.path.dirname(temp_path), exist_ok=True)

            extracted = input_tar.extractfile(member)
            if not extracted:
                continue

            with open(temp_path, 'wb') as f:
                shutil.copyfileobj(extracted, f)

            # 変換実行
            try:
                result = md.convert(temp_path)

                if result.text_content:
                    md_bytes = result.text_content.encode('utf-8')

                    # 出力ファイル名 (.md に変更)
                    base, _ = os.path.splitext(member.name)
                    new_name = base + ".md"

                    # 出力TARエントリ作成
                    info = tarfile.TarInfo(name=new_name)
                    info.size = len(md_bytes)
                    info.mtime = member.mtime  # タイムスタンプ維持

                    output_tar.addfile(info, io.BytesIO(md_bytes))

            except Exception as e:
                # 変換失敗はstderrに流して処理を止めない
                sys.stderr.write(f"[Skip] {member.name}: {e}\n")

    input_tar.close()
    output_tar.close()

if __name__ == "__main__":
    main()
