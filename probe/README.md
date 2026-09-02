# Phase 0 探针

开工前先花几毛钱,把四个未知数问清楚。**这一步不是搭管道,是决定要不要搭。**

| # | 问题 | 为什么阻塞 |
|---|---|---|
| 1 | 每小时单价 | 唯一能推翻「走云端」这个决定的数字 |
| 2 | 有没有说话人分离 | 没有就得考虑 pyannote,架构变混合 |
| 3 | 中英混说准确率 | 难点 #2,只能人眼看 |
| 4 | `emotion` 字段填什么 | 有区分度的话直接接上难点 #4 的「情绪词密集处」 |

## 准备

```bash
export DASHSCOPE_API_KEY='sk-...'        # 百炼控制台
export OSS_ACCESS_KEY_ID='LTAI...'
export OSS_ACCESS_KEY_SECRET='...'
export OSS_BUCKET='dayscribe'
export OSS_ENDPOINT='oss-cn-beijing.aliyuncs.com'
```

零第三方依赖,Python 3.9+ 和 ffmpeg 就够(`brew install ffmpeg`)。

> OSS 是硬性前提:DashScope 收的是 URL 不是文件,它自己去拉。
> 这也是「纯本地跑 + 云端 ASR」不兼容的根本原因。
>
> 嫌配 OSS 麻烦的话,手动传到控制台拿个公开 URL,然后用 `--url` 跳过这步。

## 跑

```bash
# 从整天录音里切 30 分钟(挑信息最密的一段,别用整天)
./probe/asr_probe.py \
  --audio ~/Downloads/2026-09-02.m4a \
  --start 14:00:00 --duration 00:30:00 \
  --price-per-hour 0.36

# 已经有公网 URL
./probe/asr_probe.py --url 'https://...' --price-per-hour 0.36

# 单独探测说话人分离(参数可能不被支持,报错信息本身就是答案)
./probe/asr_probe.py --url '...' --try-diarization
```

产出在 `probe/out/`:

| 文件 | 用途 |
|---|---|
| `transcript.md` | **主要产出** —— 带时间戳的转录,直接粘给 Claude 调提问 prompt |
| `raw.json` | 完整响应,用来翻有没有文档没写的字段 |
| `poll.json` | 含 `usage.seconds`,对账用 |

## 选素材

- **挑信息最密的一段**,不是随机一段。目的是看提问质量的上限
- **最好有多人对话**,能顺带验说话人分离
- **中英混说**的段落优先,那是难点 #2
- 30 分钟足够。整天既慢又贵,而且这一步不需要

## 然后呢

拿到 `transcript.md` 就可以**完全脱离代码**调提问 prompt 了 —— 粘进 Claude,手写 prompt,迭代。

判据(IDEAS.md 第 5 节):

> 一个问题如果能原样贴到任何一天的日记后面,它就是废问题。

建议让模型输出结构化对象,把这条判据变成可执行的检查:

```json
{
  "timestamp": "14:32",
  "evidence": "那我先这样吧……行,那就先这样",
  "question": "你说完这句就沉默了快一分钟,当时在犹豫什么?"
}
```

`evidence` 为空、或不是转录里的原文 → 直接丢弃重生成。引用不出证据的问题,定义上就是能贴到任何一天的问题。

**如果调到最后问题还是废的,后面全部不用做了。** 这正是 Phase 0 想早点知道的事。

## 自测

```bash
python3 probe/test_probe.py    # 不联网、不花钱
```

覆盖 OSS 签名(与 lyre 生产实现对齐)和报告判读的各种边界。

> 开发时的一个教训:我拿「记忆中的阿里云官方测试向量」去验签名,对不上,
> 差点去改一段正确的代码。后来用 lyre 跑在生产上的 TypeScript 实现交叉验证,
> 两边逐字节一致,证明是**基准记错了**。
> 所以测试里的基准是 lyre 实测输出,不是记忆里的文档值。
