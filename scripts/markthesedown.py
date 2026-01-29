#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python313 python313Packages.markitdown

# ==============================================================================
# MarkItDown Filter (Parallel Version)
# Usage: tar -cf - ./docs | markthesedown | tar -x -C ./output
# ==============================================================================

import sys
import os
import tarfile
import tempfile
import io
import shutil
import concurrent.futures

# nix-shellにより確実にインポート可能
try:
    from markitdown import MarkItDown
except ImportError:
    sys.stderr.write("Error: 'markitdown' not found. Ensure you are running with nix-shell.\n")
    sys.exit(1)

def convert_task(args):
    """
    並列実行される個別の変換タスク
    """
    temp_path, original_mtime, rel_path = args
    try:
        # スレッドセーフ性を確保するため、タスクごとにインスタンス化を試みる
        # (コストが高い場合はグローバルでの共有を検討するが、安定性重視)
        md = MarkItDown()
        result = md.convert(temp_path)

        if result.text_content:
            return (rel_path, result.text_content.encode('utf-8'), original_mtime, None)
        else:
            return (rel_path, None, original_mtime, "No text content generated")
    except Exception as e:
        return (rel_path, None, original_mtime, str(e))

def main():
    # 入力がパイプライン(ストリーム)かどうかの簡易チェック
    if sys.stdin.isatty():
        print("Usage: This is a pipe filter. Use it like:")
        print("  tar -cf - src_dir | markthesedown | tar -x -C out_dir")
        sys.exit(1)

    # 並列数: CPUコア数の2倍程度を目安に設定（IO待ちも考慮）
    try:
        max_workers = (os.cpu_count() or 1) * 2
    except:
        max_workers = 4

    sys.stderr.write(f"Running with {max_workers} threads...\n")

    try:
        # 入力ストリーム (標準入力)
        input_tar = tarfile.open(fileobj=sys.stdin.buffer, mode='r|*')
        # 出力ストリーム (標準出力)
        output_tar = tarfile.open(fileobj=sys.stdout.buffer, mode='w|')

        # 展開・変換用の一時領域
        with tempfile.TemporaryDirectory() as temp_dir:
            conversion_tasks = []

            # 1. まず入力をすべて一時ディレクトリに展開する（並列化の準備）
            # ストリーム入力のTARはランダムアクセスできないため、全展開が必要
            for member in input_tar:
                if not member.isfile():
                    continue

                # フィルタリング
                clean_name = os.path.normpath(member.name)
                basename = os.path.basename(clean_name)
                if clean_name.startswith("..") or os.path.isabs(clean_name) or basename.startswith("._") or basename == ".DS_Store":
                    continue

                # 一時ファイルへのパス
                temp_path = os.path.join(temp_dir, clean_name)
                os.makedirs(os.path.dirname(temp_path), exist_ok=True)

                # ファイル書き出し
                extracted = input_tar.extractfile(member)
                if extracted:
                    with open(temp_path, 'wb') as f:
                        shutil.copyfileobj(extracted, f)

                    # タスクリストに追加 (絶対パス, mtime, 元の相対パス)
                    conversion_tasks.append((temp_path, member.mtime, clean_name))

            input_tar.close()

            # 2. ThreadPoolExecutorで並列変換実行
            with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
                # convert_task関数に引数を渡して実行
                future_to_file = {executor.submit(convert_task, task): task for task in conversion_tasks}

                for future in concurrent.futures.as_completed(future_to_file):
                    rel_path, md_bytes, mtime, error = future.result()

                    if error:
                        # エラー時はスキップログを出力し、書き込みはしない
                        sys.stderr.write(f"[Skip] {rel_path}: {error}\n")
                        continue

                    if md_bytes:
                        # 3. 変換成功したらTARに出力
                        base, _ = os.path.splitext(rel_path)
                        new_name = base + ".md"

                        info = tarfile.TarInfo(name=new_name)
                        info.size = len(md_bytes)
                        info.mtime = mtime

                        output_tar.addfile(info, io.BytesIO(md_bytes))
                        sys.stderr.write(f"x {new_name}\n")

        output_tar.close()

    except Exception as e:
        sys.stderr.write(f"Critical Error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
