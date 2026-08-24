"""安装包 Ed25519 签名（防投毒）。

私钥持久化在 /data/release_signing.key（首次启动自动生成），公钥导出到
/data/release_signing.pub 并附带 base64 原始公钥，供客户端打包脚本直接注入
`KMXZS_UPDATE_PUBKEY`。签名与 SHA-256 通过 /config 下发给客户端，客户端下载
安装包后先验签再安装，防止静默更新被中间人投毒。
"""
from __future__ import annotations

import base64
import hashlib
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from ..core import config

# 进程内缓存：安装包在磁盘上不变时，不必每次 /config 都重算 80MB 的哈希/签名
_CACHE: dict[tuple[str, int, int], tuple[str, str]] = {}


def ensure_signing_key() -> Ed25519PrivateKey:
    """加载私钥；不存在则生成并落盘（私钥仅服务器保存）。"""
    if config.SIGNING_KEY_FILE.exists():
        with config.SIGNING_KEY_FILE.open("rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
            if isinstance(key, Ed25519PrivateKey):
                return key
    key = Ed25519PrivateKey.generate()
    config.SIGNING_KEY_FILE.parent.mkdir(parents=True, exist_ok=True)
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    config.SIGNING_KEY_FILE.write_bytes(pem)
    export_public_key(key)
    return key


def export_public_key(key: Optional[Ed25519PrivateKey] = None) -> str:
    """把公钥写入 .pub 文件（PEM + base64 原始公钥），返回 base64 原始公钥。"""
    k = key or ensure_signing_key()
    raw = k.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    b64 = base64.b64encode(raw).decode("ascii")
    config.SIGNING_PUB_FILE.parent.mkdir(parents=True, exist_ok=True)
    pub_pem = k.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    note = "\n# base64（客户端打包注入 KMXZS_UPDATE_PUBKEY）:\n".encode("utf-8")
    config.SIGNING_PUB_FILE.write_bytes(pub_pem + note + b64.encode("ascii") + b"\n")
    return b64


def public_key_b64() -> str:
    return export_public_key()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sign_bytes(data: bytes) -> str:
    key = ensure_signing_key()
    return base64.b64encode(key.sign(data)).decode("ascii")


def sign_file(path: Path) -> tuple[str, str]:
    """返回 (sha256_hex, base64_ed25519_signature)。"""
    data = path.read_bytes()
    return sha256_bytes(data), sign_bytes(data)


def cached_signature(path: Path) -> tuple[str, str]:
    """按 (路径, 大小, mtime) 缓存签名，文件不变时不重算。"""
    st = path.stat()
    key = (str(path), st.st_size, st.st_mtime_ns)
    hit = _CACHE.get(key)
    if hit is not None:
        return hit
    result = sign_file(path)
    _CACHE[key] = result
    return result


def verify_bytes(pubkey_b64: str, data: bytes, sig_b64: str) -> bool:
    """测试/运维用：用 base64 公钥校验 base64 签名。"""
    try:
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(pubkey_b64))
        pub.verify(base64.b64decode(sig_b64), data)
        return True
    except Exception:
        return False
