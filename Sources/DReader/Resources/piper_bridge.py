#!/usr/bin/env python3
"""DReader ↔ piper1-gpl 桥接：stdin 每行一段文本，stdout 输出 wav 二进制。

协议：每次合成先写 8 字节小端长度头，再写 wav 数据，保证 Swift 侧可靠分帧。
env: PIPER_MODEL 指向 onnx 模型路径；PIPER_LENGTH_SCALE 可选（默认 1.0）。
用法：venv/bin/python3 piper_bridge.py
"""
import io
import json
import os
import struct
import sys
import wave


def main() -> int:
    model_path = os.environ.get("PIPER_MODEL", "")
    if not model_path or not os.path.isfile(model_path):
        print("model not found: " + model_path, file=sys.stderr)
        return 2

    try:
        from piper import PiperVoice, SynthesisConfig
    except ImportError as e:
        print("piper package missing: %s" % e, file=sys.stderr)
        return 3

    try:
        voice = PiperVoice.load(model_path)
    except Exception as e:
        print("voice load failed: %s" % e, file=sys.stderr)
        return 4

    default_length_scale = os.environ.get("PIPER_LENGTH_SCALE", "1.0")

    # 就绪信号：一行 JSON（长度头 0x00 保留），Swift 读到即认为桥可用
    ready = json.dumps({"ok": True, "sample_rate": voice.config.sample_rate if hasattr(voice, "config") and voice.config else 22050})
    sys.stdout.buffer.write(struct.pack("<Q", len(ready)))
    sys.stdout.buffer.write(ready.encode("utf-8"))
    sys.stdout.buffer.flush()

    # 逐行读取文本 → 合成 → 帧输出
    for line in sys.stdin:
        text = line.strip()
        if not text:
            continue
        try:
            config = SynthesisConfig(length_scale=float(default_length_scale))
            buf = io.BytesIO()
            with wave.open(buf, "wb") as wav_file:
                voice.synthesize_wav(text, wav_file, syn_config=config)
            data = buf.getvalue()
            sys.stdout.buffer.write(struct.pack("<Q", len(data)))
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
        except Exception as e:
            # 出错帧：长度 0 + 消息
            msg = ("error: %s" % e).encode("utf-8")
            sys.stdout.buffer.write(struct.pack("<Q", 0))
            sys.stdout.buffer.write(struct.pack("<Q", len(msg)))
            sys.stdout.buffer.write(msg)
            sys.stdout.buffer.flush()

    return 0


if __name__ == "__main__":
    sys.exit(main())
