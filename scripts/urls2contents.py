import sys, requests, trafilatura

# 標準入力から1行ずつ読み込み
for line in sys.stdin:
    url = line.strip()
    if not url: continue

    print(f'\n---- {url} ----')

    try:
        r = requests.get(url, timeout=10)
        if r.status_code != 200:
            print(f'Error: Status {r.status_code}')
            continue

        # Content-Typeを確認
        c_type = r.headers.get('Content-Type', '').lower()

        # テキストファイル、またはURL末尾が.txtならそのまま出力
        if 'text/plain' in c_type or url.endswith('.txt'):
            print(r.text)
        else:
            # HTMLならTrafilaturaで抽出
            text = trafilatura.extract(r.text)
            if text:
                print(text)
            else:
                # 抽出失敗時のフォールバック（必要なら生HTMLを出すか、空にするか）
                print('(Content extraction failed or empty)')

    except Exception as e:
        print(f'Error: {e}')
