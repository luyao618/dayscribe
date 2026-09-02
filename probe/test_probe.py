#!/usr/bin/env python3
"""探针的自测。不联网、不花钱，`python3 probe/test_probe.py` 直接跑。

覆盖两件事：
  1. OSS 签名算法 —— 与 nocoo/lyre 的生产实现逐字节对齐
  2. report() 的判读逻辑 —— 四类响应形态各测一遍

关于 1 的来历：开发时我拿"记忆中的阿里云官方测试向量"去对，对不上，
差点去改一段正确的代码。后来用 lyre 的 TypeScript 实现（跑在生产上）
交叉验证，两边输出一致，证明是基准记错了。
所以这里的基准是 **lyre 实测输出**，不是我记忆里的文档值。
"""

import base64
import hashlib
import hmac
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from asr_probe import _presign, find_keys, report  # noqa: E402

FAILED = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(f"  {'✓' if cond else '✗'} {name}")
    if not cond:
        FAILED.append(f"{name} {detail}".strip())


# ── 1. 签名 ───────────────────────────────────────────────────────────

print("\n[1] OSS 签名 v1")

# 基准：用 lyre 的 signV1（packages/api/src/services/oss.ts:67）跑同一份
# 输入得到的结果。node 实测值，非文档抄录。
SECRET = "OtxrzxIsfpFjA7SwPzILwy8Bw21TLhquhboDYROV"
STRING_TO_SIGN = "GET\n\n\n1141889120\n/oss-example/oss-api.pdf"
LYRE_OUTPUT = "EwaNTn1erJGkimiJ9WmXgwnANLc="

mine = base64.b64encode(
    hmac.new(SECRET.encode(), STRING_TO_SIGN.encode(), hashlib.sha1).digest()
).decode()
check("与 lyre 生产实现一致", mine == LYRE_OUTPUT, f"got={mine}")

# stringToSign 的字段顺序错了签名就废，且错误只会在真实请求时暴露
cfg = {"key_id": "AK", "secret": SECRET, "bucket": "b", "endpoint": "oss-cn-x.aliyuncs.com"}
url = _presign("GET", "probe/a.m4a", cfg, 3600)
check("URL 含三个必需参数",
      all(p in url for p in ("OSSAccessKeyId=", "Expires=", "Signature=")))
check("bucket 在域名里（不是路径）", url.startswith("https://b.oss-cn-x.aliyuncs.com/"))

# key 里的斜杠不能被编码掉，否则 OSS 找不到对象
check("key 的 / 不被转义", "probe/a.m4a" in url)

# PUT 签名要带 content-type，和 GET 不同 —— 混了会 403
put = _presign("PUT", "k", cfg, 900, "audio/mp4")
check("PUT 与 GET 签名不同", put.split("Signature=")[1] != url.split("Signature=")[1])


# ── 2. find_keys ─────────────────────────────────────────────────────

print("\n[2] 字段递归搜索")

check("命中嵌套字段",
      len(find_keys({"a": {"b": [{"speaker_id": "s0"}]}}, ("speaker",))) == 1)
check("无命中返回空",
      find_keys({"a": {"b": 1}}, ("speaker",)) == [])
check("空列表不炸", find_keys({"a": []}, ("speaker",)) == [])
check("None 不炸", find_keys({"a": None}, ("speaker",)) == [])


# ── 3. report ────────────────────────────────────────────────────────

print("\n[3] 报告判读")


def run_report(raw, poll, price=None) -> str:
    buf = io.StringIO()
    with redirect_stdout(buf):
        report(raw, poll, price)
    return buf.getvalue()


def sentences(**over):
    base = {"begin_time": 0, "language": "zh", "emotion": "neutral", "text": "测试"}
    return {"transcripts": [{"channel_id": 0, "sentences": [{**base, **over}]}]}


# 3a 无 speaker / 单一 emotion —— 最可能的真实情况
out = run_report(sentences(), {"usage": {"seconds": 3600}}, 0.36)
check("无 speaker 时给出否定结论", "❌" in out and "pyannote" in out)
check("单一 emotion 被标为无信息量", "没有信息量" in out)
check("年成本换算正确", "¥263" in out, f"got: {[l for l in out.splitlines() if '¥' in l]}")

# 3b 有 speaker / 多 emotion
raw = {"transcripts": [{"sentences": [
    {"begin_time": 0, "emotion": "happy", "text": "a", "speaker_id": "s0"},
    {"begin_time": 1000, "emotion": "sad", "text": "b", "speaker_id": "s1"}]}]}
out = run_report(raw, {"usage": {"seconds": 60}})
check("发现 speaker 字段", "✅" in out and "speaker_id" in out)
check("多值 emotion 被认可", "有区分度" in out)
check("无价格时不换算", "¥" not in out)

# 3c 缺 usage —— API 可能不返回
out = run_report(sentences(), {})
check("缺 usage 时给出替代建议", "账单页" in out)

# 3d 空转录 —— 全静音片段会这样
out = run_report({"transcripts": []}, {"usage": {"seconds": 10}})
check("空转录不崩溃", "共 0 句" in out)

# 3e 缺字段
out = run_report({"transcripts": [{"sentences": [{"text": "x"}]}]}, {})
check("句子缺 emotion/begin_time 不崩溃", "共 1 句" in out)


# ── 汇总 ──────────────────────────────────────────────────────────────

print()
if FAILED:
    print(f"✗ {len(FAILED)} 个失败：")
    for f in FAILED:
        print(f"    {f}")
    sys.exit(1)
print("✓ 全部通过")
