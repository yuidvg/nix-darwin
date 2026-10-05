"""Status/ON/OFF for a launchd job, not a launcher or model downloader."""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import urllib.request

CONFIG = json.loads(Path(CONFIG_PATH).read_text())
TARGET = f"gui/{os.getuid()}/{CONFIG['label']}"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def job():
    result = subprocess.run(["/bin/launchctl", "print", TARGET], capture_output=True, text=True)
    if result.returncode:
        return {"registered": False, "pid": None, "exit": None}
    pid = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.M)
    last = re.search(r"^\s*last exit code = (\d+)\s*$", result.stdout, re.M)
    return {"registered": True, "pid": int(pid[1]) if pid else None,
            "exit": int(last[1]) if last else None}


def status():
    current = job()
    selected = Path(CONFIG["modelPath"]).is_file()
    if not current["registered"]:
        state = "未適用"
    elif not current["pid"]:
        state = "モデル未選択" if not selected else "エラー" if current["exit"] else "OFF"
    else:
        state = "読込中"
        try:
            # /props neither wakes a sleeping model nor resets the idle timer.
            # Query only while OUR launchd job runs; ignore an unrelated server.
            with OPENER.open(f"http://{CONFIG['host']}:{CONFIG['port']}/props", timeout=1) as response:
                props = json.load(response)
            if props.get("model_path") == CONFIG["modelPath"]:
                state = "待機中" if props.get("is_sleeping", False) else "ON"
            else:
                state = "接続先の不一致"
        except (OSError, ValueError):
            pass
    return {**current, "state": state, "model": CONFIG["modelPath"], "selected": selected}


def on():
    current = job()
    if not current["registered"]:
        raise ValueError("launchd設定は未適用です。確認後のdarwin-rebuild switchが必要です。")
    if current["pid"]:
        return
    model = Path(CONFIG["modelPath"]).resolve()
    if not model.is_file() or model.suffix.lower() != ".gguf" or model.is_relative_to("/nix/store"):
        raise ValueError("Nix store外のGGUFをactive.ggufとして選択してください。")
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((CONFIG["host"], CONFIG["port"]))
        except OSError as error:
            raise ValueError(f"{CONFIG['port']}番ポートは使用中です。既存プロセスは停止しません。") from error
    subprocess.run(["/bin/launchctl", "kickstart", TARGET], check=True, capture_output=True)
    for _ in range(30):
        current = job()
        if current["pid"]:
            return
        time.sleep(0.1)
    if current["exit"]:
        raise ValueError(f"サーバーの起動に失敗しました（終了コード {current['exit']}）。")
    raise ValueError("サーバーの起動を確認できませんでした。")


def off():
    if job()["pid"]:
        subprocess.run(["/bin/launchctl", "kill", "SIGTERM", TARGET], check=True, capture_output=True)
        for _ in range(150):
            if not job()["pid"]:
                return
            time.sleep(0.1)
        raise ValueError("サーバーの停止をまだ確認できません。")


def menu(current):
    state = current["state"]
    symbol = {"ON": "circle.fill", "待機中": "moon.zzz.fill", "OFF": "circle",
              "読込中": "hourglass"}.get(state, "exclamationmark.circle")
    print(f"LLM {state} | sfimage={symbol}")
    print("---")
    print(f"ローカル推論: {state}")
    print(f"local-qwen · {CONFIG['context'] // 1024}K · {CONFIG['idleSeconds'] // 60}分でメモリ解放")
    if current["exit"] and not current["pid"]:
        print(f"終了コード: {current['exit']}")
    print("---")
    executable = str(Path(sys.argv[0]).resolve())
    if current["registered"] and current["selected"] and not current["pid"]:
        print(f"ON | bash={executable} param1=on terminal=false refresh=true")
    if current["pid"]:
        print(f"OFF（サーバー停止・メモリ解放） | bash={executable} param1=off terminal=false refresh=true")
    print("状態を更新 | refresh=true")
    print(f"モデルの保存場所 | bash=/usr/bin/open param1={Path(CONFIG['modelPath']).parent} terminal=false")
    if current["pid"]:
        print(f"Web UIを開く | href=http://{CONFIG['host']}:{CONFIG['port']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", default="menu" if os.getenv("SWIFTBAR") == "1" else "status", choices=["status", "on", "off", "menu"])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        if args.action == "on":
            on()
        elif args.action == "off":
            off()
        current = status()
        if args.action == "menu":
            menu(current)
        elif args.json:
            print(json.dumps(current, ensure_ascii=False))
        else:
            print(f"LLM {current['state']} · {CONFIG['host']}:{CONFIG['port']}")
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
