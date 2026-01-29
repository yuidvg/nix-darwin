#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python313 python313Packages.markitdown

# ==============================================================================
# MarkItDown Filter (Functional/Unix-compliant Refactoring)
# ==============================================================================

import sys
import os
import tarfile
import tempfile
import io
import shutil
import logging
import signal
from concurrent.futures import ThreadPoolExecutor

# Suppress library noise
logging.getLogger("pdfminer").setLevel(logging.ERROR)
logging.getLogger("openpyxl").setLevel(logging.ERROR)

def is_junk_file(path: str) -> bool:
    """
    Predicate: Returns True if the file matches junk patterns (metadata, etc).
    """
    basename = os.path.basename(path)
    return basename.startswith("._") or basename == ".DS_Store"

def extract_member(tar: tarfile.TarFile, member: tarfile.TarInfo, dest_dir: str):
    """
    Action: Extracts a single member to a temporary file.
    Returns the task tuple (temp_path, original_mtime, original_name) or None on failure.
    """
    try:
        clean_name = os.path.normpath(member.name)
        if clean_name.startswith("..") or os.path.isabs(clean_name):
            return None

        temp_path = os.path.join(dest_dir, clean_name)
        os.makedirs(os.path.dirname(temp_path), exist_ok=True)

        source = tar.extractfile(member)
        if not source:
            return None

        with open(temp_path, 'wb') as dest:
            shutil.copyfileobj(source, dest)

        return (temp_path, member.mtime, member.name)
    except Exception as e:
        sys.stderr.write(f"[Extract Failed] {member.name}: {e}\n")
        return None

def source_stream(tar: tarfile.TarFile, dest_dir: str):
    """
    Generator: Yields extraction tasks from the tar stream.
    Acts as the 'Source' of the pipeline.
    """
    for member in tar:
        if not member.isfile():
            continue
        if is_junk_file(member.name):
            continue

        task = extract_member(tar, member, dest_dir)
        if task:
            yield task

def transform_content(args) -> tuple:
    """
    Map Function: Pure transformation of file content (Disk -> Memory).
    Input: (path, mtime, name)
    Output: Result(path, content_bytes, mtime) | Error
    """
    temp_path, mtime, name = args
    try:
        # Import inside worker to ensure clean state or lazy load
        from markitdown import MarkItDown

        # Helper: Get credential from Env or Netrc (The Unix Way)
        def get_auth(env_key, host):
            # 1. Environment Variable (Process-local context)
            if os.environ.get(env_key):
                return os.environ.get(env_key)
            # 2. Netrc (User-global configuration, chmod 600)
            try:
                import netrc
                secrets = netrc.netrc()
                auth = secrets.authenticators(host)
                if auth:
                    return auth[2] # password field
            except (ImportError, FileNotFoundError, netrc.NetrcParseError):
                pass
            return None

        # Initialize LLM client
        llm_client = None
        llm_model = None

        openrouter_key = get_auth("OPENROUTER_API_KEY", "openrouter.ai")
        openai_key = get_auth("OPENAI_API_KEY", "api.openai.com")

        if openrouter_key:
            try:
                from openai import OpenAI
                llm_client = OpenAI(
                    base_url="https://openrouter.ai/api/v1",
                    api_key=openrouter_key,
                )
                llm_model = os.environ.get("OPENROUTER_MODEL", "google/gemini-2.0-flash-001")
            except ImportError:
                pass
        elif openai_key:
            try:
                from openai import OpenAI
                llm_client = OpenAI(api_key=openai_key)
                llm_model = "gpt-4o"
            except ImportError:
                pass

        md = MarkItDown(llm_client=llm_client, llm_model=llm_model)

        result = md.convert(temp_path)

        if result.text_content:
            return (name, result.text_content.encode('utf-8'), mtime)
        return (name, None, mtime) # No text content

    except Exception as e:
        # Return error as value (Result pattern)
        return (name, e, mtime)

def sink_stream(output_tar: tarfile.TarFile, results):
    """
    Sink: Consumes results and writes to output tar stream.
    """
    for name, content_or_error, mtime in results:
        if isinstance(content_or_error, Exception):
            sys.stderr.write(f"[Convert Failed] {name}: {content_or_error}\n")
            continue

        if content_or_error is None:
            sys.stderr.write(f"[Skip] {name}: No convertable text content.\n")
            continue

        md_bytes = content_or_error
        base, _ = os.path.splitext(name)
        new_name = base + ".md"

        info = tarfile.TarInfo(name=new_name)
        info.size = len(md_bytes)
        info.mtime = mtime

        output_tar.addfile(info, io.BytesIO(md_bytes))
        sys.stderr.write(f"x {new_name}\n")

def main():
    # Unix Principle: Handle SIGPIPE gracefully for pipeline usage
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    # Configuration: Parallelism
    max_workers = (os.cpu_count() or 1) * 2

    try:
        # IO Monad-ish Wrapper
        input_tar = tarfile.open(fileobj=sys.stdin.buffer, mode='r|*')
        output_tar = tarfile.open(fileobj=sys.stdout.buffer, mode='w|')

        with tempfile.TemporaryDirectory() as temp_dir:
            # Build the Pipeline
            # 1. Source: Generator of extracted files
            tasks = source_stream(input_tar, temp_dir)

            # 2. Map: Parallel transformation
            # ThreadPoolExecutor.map is lazy-ish but preserves order.
            # It consumes the 'tasks' generator (which triggers extraction)
            # and yields results as they complete (in order).
            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                results = executor.map(transform_content, tasks)

                # 3. Sink: Write results
                sink_stream(output_tar, results)

        input_tar.close()
        output_tar.close()

    except BrokenPipeError:
        # Standard Unix behavior: exit silently
        sys.stderr.close()
        sys.exit(0)
    except Exception as e:
        sys.stderr.write(f"Critical Error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
