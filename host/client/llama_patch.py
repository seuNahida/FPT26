"""Patch HuggingFace Llama attention modules to call a custom backend."""

from __future__ import annotations

import re
from types import MethodType
from typing import Any

import torch

from .attention_backends import BaseAttentionBackend
from .fpga_udp_client import probe_span


def _looks_like_llama_attention(module: torch.nn.Module) -> bool:
    required = ("q_proj", "k_proj", "v_proj", "o_proj")
    if not all(hasattr(module, name) for name in required):
        return False
    return hasattr(module, "head_dim") or hasattr(getattr(module, "config", None), "head_dim")


def _infer_layer_idx(name: str, fallback: int) -> int:
    match = re.search(r"layers\.(\d+)\.self_attn", name)
    if match:
        return int(match.group(1))
    return fallback


def _num_heads(module: torch.nn.Module) -> int:
    if hasattr(module, "num_heads"):
        return int(module.num_heads)
    config = getattr(module, "config", None)
    if config is not None and hasattr(config, "num_attention_heads"):
        return int(config.num_attention_heads)
    raise AttributeError("attention module has no num_heads/config.num_attention_heads")


def _num_kv_heads(module: torch.nn.Module, num_heads: int) -> int:
    if hasattr(module, "num_key_value_heads"):
        return int(module.num_key_value_heads)
    config = getattr(module, "config", None)
    if config is not None and hasattr(config, "num_key_value_heads"):
        return int(config.num_key_value_heads)
    return num_heads


def _head_dim(module: torch.nn.Module, hidden_size: int, num_heads: int) -> int:
    if hasattr(module, "head_dim"):
        return int(module.head_dim)
    return hidden_size // num_heads


def _apply_rope(
    module: torch.nn.Module,
    query_states: torch.Tensor,
    key_states: torch.Tensor,
    value_states: torch.Tensor,
    position_ids: torch.Tensor | None,
    position_embeddings: tuple[torch.Tensor, torch.Tensor] | None,
) -> tuple[torch.Tensor, torch.Tensor]:
    try:
        from transformers.models.llama.modeling_llama import apply_rotary_pos_emb
    except Exception as exc:  # pragma: no cover - depends on transformers install
        raise RuntimeError("transformers Llama RoPE helper is unavailable") from exc

    if position_embeddings is not None:
        cos, sin = position_embeddings
        try:
            return apply_rotary_pos_emb(query_states, key_states, cos, sin, position_ids)
        except TypeError:
            return apply_rotary_pos_emb(query_states, key_states, cos, sin)

    rotary_emb = getattr(module, "rotary_emb", None)
    if rotary_emb is None:
        return query_states, key_states

    try:
        cos, sin = rotary_emb(value_states, position_ids)
        try:
            return apply_rotary_pos_emb(query_states, key_states, cos, sin, position_ids)
        except TypeError:
            return apply_rotary_pos_emb(query_states, key_states, cos, sin)
    except TypeError:
        kv_seq_len = key_states.shape[-2]
        cos, sin = rotary_emb(value_states, seq_len=kv_seq_len)
        return apply_rotary_pos_emb(query_states, key_states, cos, sin, position_ids)


def _resolve_return_tuple_len(return_tuple_len: str) -> int:
    if return_tuple_len == "2":
        return 2
    if return_tuple_len == "3":
        return 3
    try:
        import transformers

        parts = transformers.__version__.split(".")
        major = int(parts[0])
        minor = int(parts[1])
        return 3 if major == 4 and minor < 43 else 2
    except Exception:
        return 2


def _update_kv_cache(
    past_key_value: Any,
    key_states: torch.Tensor,
    value_states: torch.Tensor,
    *,
    layer_idx: int,
    cache_position: torch.Tensor | None,
    use_cache: bool,
) -> tuple[torch.Tensor, torch.Tensor, Any]:
    if past_key_value is None:
        present = (key_states, value_states) if use_cache else None
        return key_states, value_states, present

    if hasattr(past_key_value, "update"):
        cache_kwargs = {"cache_position": cache_position}
        try:
            key_states, value_states = past_key_value.update(
                key_states, value_states, layer_idx, cache_kwargs
            )
        except TypeError:
            key_states, value_states = past_key_value.update(
                key_states, value_states, layer_idx
            )
        return key_states, value_states, past_key_value

    if isinstance(past_key_value, (tuple, list)) and len(past_key_value) == 2:
        key_states = torch.cat((past_key_value[0], key_states), dim=-2)
        value_states = torch.cat((past_key_value[1], value_states), dim=-2)
        return key_states, value_states, (key_states, value_states)

    raise TypeError(f"unsupported KV cache type: {type(past_key_value)!r}")


def _parse_optional_args(args: tuple[Any, ...], kwargs: dict[str, Any]) -> dict[str, Any]:
    # transformers >= 4.56 passes the cache as past_key_values; older
    # releases use past_key_value. Dropping it would silently disable the
    # KV cache during decode.
    past_key_values = kwargs.pop("past_key_values", None)
    past_key_value = kwargs.pop("past_key_value", None)
    parsed = {
        "attention_mask": kwargs.pop("attention_mask", None),
        "position_ids": kwargs.pop("position_ids", None),
        "past_key_value": past_key_values if past_key_values is not None else past_key_value,
        "output_attentions": kwargs.pop("output_attentions", False),
        "use_cache": kwargs.pop("use_cache", False),
        "cache_position": kwargs.pop("cache_position", None),
        "position_embeddings": kwargs.pop("position_embeddings", None),
    }

    remaining = list(args)
    if remaining:
        first = remaining.pop(0)
        if isinstance(first, tuple) and len(first) == 2:
            parsed["position_embeddings"] = first
        else:
            parsed["attention_mask"] = first
    if remaining:
        second = remaining.pop(0)
        if parsed["position_embeddings"] is not None:
            parsed["attention_mask"] = second
        else:
            parsed["position_ids"] = second
    if remaining:
        parsed["past_key_value"] = remaining.pop(0)
    if remaining:
        parsed["output_attentions"] = remaining.pop(0)
    if remaining:
        parsed["use_cache"] = remaining.pop(0)
    if remaining:
        parsed["cache_position"] = remaining.pop(0)

    return parsed


def _make_forward(
    *,
    backend: BaseAttentionBackend,
    layer_idx: int,
    return_tuple_len: int,
    enforce_prefill: bool,
):
    def forward(self, hidden_states: torch.Tensor, *args: Any, **kwargs: Any):
        parsed = _parse_optional_args(args, kwargs)
        attention_mask = parsed["attention_mask"]
        position_ids = parsed["position_ids"]
        past_key_value = parsed["past_key_value"]
        use_cache = bool(parsed["use_cache"])
        cache_position = parsed["cache_position"]
        position_embeddings = parsed["position_embeddings"]

        if enforce_prefill and (use_cache or past_key_value is not None):
            raise NotImplementedError(
                "this FPGA attention hook was installed in prefill-only mode"
            )
        if hidden_states.shape[0] != 1:
            raise ValueError("FPGA attention hook currently supports batch=1 only")

        batch_size, seq_len, hidden_size = hidden_states.shape
        num_heads = _num_heads(self)
        num_kv_heads = _num_kv_heads(self, num_heads)
        head_dim = _head_dim(self, hidden_size, num_heads)

        with probe_span(backend.profiler, "host.qkv_projection"):
            q = self.q_proj(hidden_states)
            k = self.k_proj(hidden_states)
            v = self.v_proj(hidden_states)

        with probe_span(backend.profiler, "host.qkv_layout"):
            q = q.view(batch_size, seq_len, num_heads, head_dim).transpose(1, 2)
            k = k.view(batch_size, seq_len, num_kv_heads, head_dim).transpose(1, 2)
            v = v.view(batch_size, seq_len, num_kv_heads, head_dim).transpose(1, 2)

        with probe_span(backend.profiler, "host.rope"):
            q, k = _apply_rope(self, q, k, v, position_ids, position_embeddings)
        with probe_span(backend.profiler, "host.kv_cache"):
            k, v, present_key_value = _update_kv_cache(
                past_key_value,
                k,
                v,
                layer_idx=layer_idx,
                cache_position=cache_position,
                use_cache=use_cache,
            )

        scale = float(getattr(self, "scaling", head_dim ** -0.5))
        with probe_span(backend.profiler, "attention_backend"):
            attn_output = backend.compute_attention(
                q=q,
                k=k,
                v=v,
                attention_mask=attention_mask,
                causal=attention_mask is None,
                scale=scale,
                layer_idx=layer_idx,
                metadata={
                    "q_len": seq_len,
                    "kv_len": int(k.shape[-2]),
                    "head_dim": head_dim,
                    "cache_position": cache_position,
                },
            )

        with probe_span(backend.profiler, "host.output_layout"):
            attn_output = attn_output.transpose(1, 2).contiguous()
            attn_output = attn_output.reshape(batch_size, seq_len, num_heads * head_dim)
        with probe_span(backend.profiler, "host.output_projection"):
            attn_output = self.o_proj(attn_output)

        if return_tuple_len == 3:
            return attn_output, None, present_key_value
        return attn_output, None

    return forward


def install_llama_attention_backend(
    model: torch.nn.Module,
    backend: BaseAttentionBackend,
    *,
    return_tuple_len: str = "auto",
    enforce_prefill: bool = False,
) -> int:
    """Replace Llama self-attention forward methods with a backend call."""

    tuple_len = _resolve_return_tuple_len(return_tuple_len)
    patched = 0
    for name, module in model.named_modules():
        if not _looks_like_llama_attention(module):
            continue
        if hasattr(module, "_fpga_original_forward"):
            continue
        layer_idx = _infer_layer_idx(name, patched)
        module._fpga_original_forward = module.forward
        module.forward = MethodType(
            _make_forward(
                backend=backend,
                layer_idx=layer_idx,
                return_tuple_len=tuple_len,
                enforce_prefill=enforce_prefill,
            ),
            module,
        )
        patched += 1
    return patched
