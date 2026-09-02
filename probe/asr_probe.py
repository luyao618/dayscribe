#!/usr/bin/env python3
"""dayscribe ASR 探针 —— 一次调用回答四个阻塞问题。

Phase 0 用。目的不是搭管道，是花最少的钱把这四件事问清楚：

  1. 每小时多少钱          （唯一能推翻"走云端"这个决定的数字）
  2. 有没有说话人分离       （没有就得考虑 pyannote，架构变混合）
  3. 中英混说的实际准确率    （难点 #2，只能人眼看）
  4. emotion 字段填什么     （可用的话直接接上难点 #4 的"情绪词密集处"）

零第三方依赖：OSS 签名用 stdlib 手搓（阿里云签名 v1 就是一个
HMAC-SHA1），省掉 `pip install oss2`。

用法见 probe/README.md。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path
from urllib.parse import quote

DASHSCOPE_BASE = "https://dashscope.aliyuncs.com/api/v1"
DEFAULT_MODEL = "qwen3-asr-flash-filetrans"


# ── HTTP ──────────────────────────────────────────────────────────────


def _http(url: str, method: str = "GET", headers: dict | None = None,
          body: bytes | None = None, timeout: int = 120) -> tuple[int, bytes]:
    """发一个请求。HTTP 错误也当正常返回 —— 错误响应体本身就是情报，
    尤其在探测 API 支不支持某个参数的时候。"""
    req = urllib.request.Request(url, method=method, data=body,
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


# ── 阿里云 OSS 预签名（签名 v1）──────────────────────────────────────


def _presign(method: str, key: str, cfg: dict, expires_in: int = 3600,
             content_type: str = "") -> str:
    """生成预签名 URL。

    DashScope 收的是 URL 不是文件 —— 它自己去拉。所以音频必须先有个
    公网可达的地址，这也是"纯本地跑 + 云端 ASR"不兼容的根本原因。
    """
    expires = int(time.time()) + expires_in
    to_sign = f"{method}\n\n{content_type}\n{expires}\n/{cfg['bucket']}/{key}"
    sig = base64.b64encode(
        hmac.new(cfg["secret"].encode(), to_sign.encode(), hashlib.sha1).digest()
    ).decode()
    return (f"https://{cfg['bucket']}.{cfg['endpoint']}/{quote(key)}"
            f"?OSSAccessKeyId={quote(cfg['key_id'])}"
            f"&Expires={expires}&Signature={quote(sig)}")


def upload_to_oss(path: Path, cfg: dict) -> str:
    """传上去，返回一个能给 DashScope 拉的预签名 GET URL。"""
    key = f"probe/{int(time.time())}-{path.name}"
    ctype = "audio/mp4" if path.suffix in (".m4a", ".mp4") else "audio/mpeg"

    put_url = _presign("PUT", key, cfg, 900, ctype)
    status, body = _http(put_url, "PUT", {"Content-Type": ctype},
                         path.read_bytes(), timeout=600)
    if not 200 <= status < 300:
        sys.exit(f"OSS 上传失败 ({status}): {body[:500].decode(errors='replace')}")

    print(f"  已上传 → oss://{cfg['bucket']}/{key}")
    return _presign("GET", key, cfg, 7200)


# ── 音频切片 ──────────────────────────────────────────────────────────


def slice_audio(src: Path, start: str, duration: str, out: Path) -> Path:
    """切一段出来。探针不需要整天 —— 挑信息最密的一段就够。

    转成 16k 单声道：语音识别用不着更高，上传也快。
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
           "-ss", start, "-t", duration,
           "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "64k", str(out)]
    subprocess.run(cmd, check=True)
    print(f"  已切片 → {out} ({out.stat().st_size / 1024 / 1024:.1f} MB)")
    return out


# ── DashScope ─────────────────────────────────────────────────────────


def submit(audio_url: str, api_key: str, model: str,
           extra_params: dict | None = None) -> str:
    params = {"language_hints": ["zh", "en"], "enable_words": False}
    params.update(extra_params or {})

    payload = {"model": model, "input": {"file_url": audio_url},
               "parameters": params}
    status, body = _http(
        f"{DASHSCOPE_BASE}/services/audio/asr/transcription", "POST",
        {"Authorization": f"Bearer {api_key}",
         "Content-Type": "application/json",
         "X-DashScope-Async": "enable"},
        json.dumps(payload).encode())

    if not 200 <= status < 300:
        print(f"\n提交失败 ({status})：{body.decode(errors='replace')[:800]}")
        if extra_params:
            print("\n→ 这次带了额外参数 " + json.dumps(extra_params, ensure_ascii=False)
                  + "\n  报错可能就是因为它不被支持。去掉 --try-diarization 再跑一次对照。")
        sys.exit(1)

    task_id = json.loads(body)["output"]["task_id"]
    print(f"  task_id = {task_id}")
    return task_id


def poll(task_id: str, api_key: str, interval: int = 5,
         timeout: int = 1800) -> dict:
    headers = {"Authorization": f"Bearer {api_key}"}
    deadline = time.time() + timeout
    last = None

    while time.time() < deadline:
        status, body = _http(f"{DASHSCOPE_BASE}/tasks/{task_id}", headers=headers)
        if not 200 <= status < 300:
            sys.exit(f"轮询失败 ({status}): {body[:500].decode(errors='replace')}")

        out = json.loads(body)["output"]
        state = out["task_status"]
        if state != last:
            print(f"  {state}")
            last = state
        if state in ("SUCCEEDED", "FAILED"):
            return json.loads(body)
        time.sleep(interval)

    sys.exit(f"超时：{timeout}s 内没有终态")


# ── 分析 ──────────────────────────────────────────────────────────────


def find_keys(obj, needles: tuple[str, ...], path: str = "") -> list[str]:
    """递归找可疑字段名。

    不去猜 API 的字段叫什么 —— 直接扫整棵 JSON 树。文档没写、
    但响应里存在的字段，这样才能发现。
    """
    hits = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            here = f"{path}.{k}" if path else k
            if any(n in k.lower() for n in needles):
                preview = json.dumps(v, ensure_ascii=False)[:80]
                hits.append(f"{here} = {preview}")
            hits += find_keys(v, needles, here)
    elif isinstance(obj, list) and obj:
        hits += find_keys(obj[0], needles, f"{path}[0]")  # 同构，看第一个就够
    return hits


def report(raw: dict, poll_result: dict, price_per_hour: float | None) -> None:
    print("\n" + "=" * 66)
    print("体检报告")
    print("=" * 66)

    # Q1 价格
    secs = poll_result.get("usage", {}).get("seconds")
    print("\n【Q1】计费")
    if secs:
        print(f"  本次用量：{secs} 秒（{secs / 60:.1f} 分钟）")
        if price_per_hour:
            cost = secs / 3600 * price_per_hour
            print(f"  本次费用：约 ¥{cost:.4f}")
            print(f"  推算：每天 2h 有效语音 → 一年 730h → "
                  f"约 ¥{730 * price_per_hour:.0f}/年")
        else:
            print("  （传 --price-per-hour 可换算成年成本）")
    else:
        print("  响应里没有 usage.seconds —— 去控制台账单页确认计费口径")

    # Q2 说话人分离
    print("\n【Q2】说话人分离")
    hits = find_keys(raw, ("speaker", "diariz", "role", "spk"))
    if hits:
        print("  ✅ 发现疑似字段：")
        for h in hits[:10]:
            print(f"     {h}")
    else:
        print("  ❌ 整棵响应树里没有任何 speaker/diariz/role/spk 字段")
        print("     → 要么这个模型不做分离，要么要另外的参数开启")
        print("     → 先别急着上 pyannote：是你自己的录音，LLM 常能从")
        print("       上下文推出说话人切换。先试试没有它行不行。")

    ch = find_keys(raw, ("channel",))
    if ch:
        print(f"  （另有 channel 字段：{ch[0]}——那是声道不是说话人）")

    # Q4 emotion
    print("\n【Q4】emotion 字段")
    emotions, sentences = [], []
    for t in raw.get("transcripts", []):
        for s in t.get("sentences", []):
            sentences.append(s)
            if "emotion" in s:
                emotions.append(s["emotion"])
    if not emotions:
        print("  ❌ 句子里没有 emotion 字段")
    else:
        dist = Counter(emotions)
        print(f"  取值分布（{len(emotions)} 句）：")
        for val, n in dist.most_common():
            print(f"     {val:<12} {n:>4}  ({n / len(emotions) * 100:.0f}%)")
        if len(dist) == 1:
            print(f"  ⚠️  全是同一个值 —— 这个字段没有信息量，别指望它")
        else:
            print("  ✅ 有区分度，可以接上难点 #4 的'情绪词密集处'")

    # Q3 只能人眼看
    print("\n【Q3】中英混说准确率 —— 机器判不了，自己读")
    langs = Counter(s.get("language") for s in sentences if s.get("language"))
    if langs:
        print(f"  句子级语言标注：{dict(langs)}")
    print(f"  共 {len(sentences)} 句。抽头 3 句：\n")
    for s in sentences[:3]:
        ts = s.get("begin_time", 0) / 1000
        print(f"  [{int(ts // 60):02d}:{int(ts % 60):02d}] {s.get('text', '')}")

    print("\n" + "=" * 66)


# ── main ──────────────────────────────────────────────────────────────


def main() -> None:
    p = argparse.ArgumentParser(
        description="dayscribe ASR 探针",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
例子:
  # 从整天录音切 30 分钟，自动上传后跑
  ./asr_probe.py --audio ~/day.m4a --start 14:00:00 --duration 00:30:00 \\
                 --price-per-hour 0.36

  # 已经有公网 URL 了（比如手动传到 OSS 控制台）
  ./asr_probe.py --url 'https://...' --price-per-hour 0.36

  # 探测支不支持说话人分离（可能报错，报错信息本身就是答案）
  ./asr_probe.py --url '...' --try-diarization
        """)
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--audio", type=Path, help="本地音频（需配 OSS 环境变量）")
    src.add_argument("--url", help="已有的公网可达音频 URL")
    p.add_argument("--start", default="00:00:00", help="切片起点 (默认 00:00:00)")
    p.add_argument("--duration", default="00:30:00", help="切片时长 (默认 30 分钟)")
    p.add_argument("--no-slice", action="store_true", help="不切，整个文件传")
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--price-per-hour", type=float,
                   help="每小时单价（元），用于换算年成本")
    p.add_argument("--try-diarization", action="store_true",
                   help="试探性带上分离参数 —— 报错也是情报")
    p.add_argument("--outdir", type=Path, default=Path("probe/out"))
    args = p.parse_args()

    api_key = os.environ.get("DASHSCOPE_API_KEY")
    if not api_key:
        sys.exit("缺 DASHSCOPE_API_KEY。见 probe/README.md")

    args.outdir.mkdir(parents=True, exist_ok=True)

    # 1. 拿到一个公网 URL
    if args.url:
        audio_url = args.url
        print("【1/4】音频：用传入的 URL")
    else:
        print("【1/4】准备音频")
        cfg = {
            "key_id": os.environ.get("OSS_ACCESS_KEY_ID"),
            "secret": os.environ.get("OSS_ACCESS_KEY_SECRET"),
            "bucket": os.environ.get("OSS_BUCKET"),
            "endpoint": os.environ.get("OSS_ENDPOINT"),
        }
        if not all(cfg.values()):
            sys.exit("缺 OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET / "
                     "OSS_BUCKET / OSS_ENDPOINT。见 probe/README.md")

        path = args.audio
        if not args.no_slice:
            path = slice_audio(path, args.start, args.duration,
                               args.outdir / "slice.m4a")
        audio_url = upload_to_oss(path, cfg)

    # 2. 提交
    print("\n【2/4】提交转写任务")
    extra = {"diarization_enabled": True, "speaker_count": 2} \
        if args.try_diarization else None
    if extra:
        print(f"  试探参数：{json.dumps(extra, ensure_ascii=False)}")
    task_id = submit(audio_url, api_key, args.model, extra)

    # 3. 轮询
    print("\n【3/4】等结果")
    t0 = time.time()
    result = poll(task_id, api_key)
    print(f"  耗时 {time.time() - t0:.0f}s")

    if result["output"]["task_status"] == "FAILED":
        sys.exit(f"\n转写失败：{result['output'].get('message')}")

    # 4. 取回原始结果
    print("\n【4/4】取回结果")
    status, body = _http(result["output"]["result"]["transcription_url"])
    if not 200 <= status < 300:
        sys.exit(f"下载结果失败 ({status})")
    raw = json.loads(body)

    raw_path = args.outdir / "raw.json"
    raw_path.write_text(json.dumps(raw, ensure_ascii=False, indent=2))
    (args.outdir / "poll.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2))

    # 转录正文单独存一份，方便直接粘给 Claude 调提问 prompt
    lines = []
    for t in raw.get("transcripts", []):
        for s in t.get("sentences", []):
            ts = s.get("begin_time", 0) / 1000
            lines.append(f"[{int(ts // 3600):02d}:{int(ts % 3600 // 60):02d}:"
                         f"{int(ts % 60):02d}] {s.get('text', '')}")
    transcript_path = args.outdir / "transcript.md"
    transcript_path.write_text("\n".join(lines))

    print(f"  原始 JSON → {raw_path}")
    print(f"  转录正文 → {transcript_path}  ({len(lines)} 句)")

    report(raw, result, args.price_per_hour)

    print(f"\n下一步：把 {transcript_path} 粘给 Claude，开始调提问 prompt。")
    print("判据：一个问题如果能原样贴到任何一天的日记后面，它就是废问题。\n")


if __name__ == "__main__":
    main()
