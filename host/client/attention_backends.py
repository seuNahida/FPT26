"""Model attention statistics and the v4 FPGA backend factory."""


from __future__ import annotations
from dataclasses import dataclass, field


from typing import Any
import torch


@dataclass
class AttentionCallRecord:
    layer_idx: int
    q_shape: tuple[int, ...]
    k_shape: tuple[int, ...]
    v_shape: tuple[int, ...]
    dtype: str
    elapsed_s: float


@dataclass
class AttentionStats:
    calls: int = 0
    total_s: float = 0.0
    records: list[AttentionCallRecord] = field(default_factory=list)

    def add(
        self,
        *,
        layer_idx: int,
        q: torch.Tensor,
        k: torch.Tensor,
        v: torch.Tensor,
        elapsed_s: float,
    ) -> None:
        self.calls += 1
        self.total_s += elapsed_s
        if len(self.records) < 16:
            self.records.append(
                AttentionCallRecord(
                    layer_idx=layer_idx,
                    q_shape=tuple(q.shape),
                    k_shape=tuple(k.shape),
                    v_shape=tuple(v.shape),
                    dtype=str(q.dtype).replace("torch.", ""),
                    elapsed_s=elapsed_s,
                )
            )


class BaseAttentionBackend:
    name = "base"

    def __init__(self) -> None:
        self.stats = AttentionStats()
        self.profiler = None

    def compute_attention(
        self,
        *,
        q: torch.Tensor,
        k: torch.Tensor,
        v: torch.Tensor,
        attention_mask: torch.Tensor | None,
        causal: bool,
        scale: float,
        layer_idx: int,
        metadata: dict[str, Any] | None = None,
    ) -> torch.Tensor:
        raise NotImplementedError


def make_attention_backend(name, *, udp_host='192.168.1.10', udp_port=50000,
                           udp_timeout_s=1, fpga_max_seq_len=2048,
                           fpga_udp_window=4, fpga_ddr_chunk_words=360):
    if name != 'fpga_v4_udp':
        raise ValueError('此演示包只使用 v4.6 FPGA Attention 后端')
    from .v4_backend import V4AttentionBackend
    return V4AttentionBackend(host=udp_host, port=udp_port, timeout_s=udp_timeout_s,
                              max_seq_len=fpga_max_seq_len, retries=1,
                              window=fpga_udp_window, bulk_chunk_words=fpga_ddr_chunk_words)
