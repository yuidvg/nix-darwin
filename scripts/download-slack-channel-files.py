import sys
import os
import argparse
import requests
from typing import Generator, Iterator, Optional, NamedTuple
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

# --- 1. Data Structures (Immutable) ---
class FileMeta(NamedTuple):
    """ファイル情報を保持する不変データ構造"""
    name: str
    url: str
    timestamp: str

    @property
    def safe_filename(self) -> str:
        return f"{self.timestamp}_{self.name}".replace("/", "_")

class Config(NamedTuple):
    token: str
    channel_id: str
    output_dir: str

# --- 2. Pure Functions (Transformation) ---
def parse_args(args: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("channel_id")
    parser.add_argument("--dir", default="./downloads")
    return parser.parse_args(args)

def extract_file_meta(message: dict) -> Iterator[FileMeta]:
    """1つのメッセージ辞書からファイル情報のストリームを生成する純粋関数"""
    if "files" not in message:
        return
    
    ts = message.get("ts", "0")
    for f in message["files"]:
        if f.get("mode") == "tombstone":
            continue
        
        url = f.get("url_private_download")
        name = f.get("name", "untitled")
        
        if url:
            yield FileMeta(name=name, url=url, timestamp=ts)

# --- 3. Impure Functions (Source / Generator) ---
def stream_history(client: WebClient, channel_id: str) -> Generator[dict, None, None]:
    """APIページネーションを隠蔽し、メッセージの無限ストリームとして振る舞う"""
    cursor = None
    while True:
        response = client.conversations_history(
            channel=channel_id, 
            cursor=cursor, 
            limit=100
        )
        yield from response.get("messages", [])
        
        if not response.get("has_more"):
            break
        cursor = response["response_metadata"]["next_cursor"]

def get_token_from_stdin() -> Optional[str]:
    if not sys.stdin.isatty():
        return sys.stdin.read().strip()
    return os.environ.get("SLACK_BOT_TOKEN")

# --- 4. Impure Functions (Sink / Action) ---
def download_file(meta: FileMeta, config: Config) -> None:
    """副作用: ネットワークから取得し、ディスクに書き込む"""
    path = os.path.join(config.output_dir, meta.safe_filename)
    
    if os.path.exists(path):
        return # Idempotency (冪等性) の確保

    print(f"Downloading: {meta.safe_filename}")
    headers = {"Authorization": f"Bearer {config.token}"}
    
    # Context Managerでリソースリークを防ぐ
    with requests.get(meta.url, headers=headers, stream=True) as r:
        if r.status_code == 200:
            with open(path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
        else:
            print(f"Failed: {r.status_code}", file=sys.stderr)

# --- 5. Composition root (The Wiring) ---
def main():
    # Configuration (Input)
    args = parse_args(sys.argv[1:])
    token = get_token_from_stdin()
    
    if not token:
        print("Error: Token required via stdin or env var.", file=sys.stderr)
        sys.exit(1)

    config = Config(token, args.channel_id, args.dir)
    client = WebClient(token=config.token)
    os.makedirs(config.output_dir, exist_ok=True)

    try:
        # Pipeline: Source -> Transform -> Sink
        # 1. Source: メッセージのストリーム
        messages = stream_history(client, config.channel_id)
        
        # 2. Transform: ファイルメタデータのストリーム (FlatMap)
        files = (
            meta 
            for msg in messages 
            for meta in extract_file_meta(msg)
        )
        
        # 3. Sink: 実行 (各要素に対してIOを実行)
        for meta in files:
            download_file(meta, config)
            
    except SlackApiError as e:
        print(f"API Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()