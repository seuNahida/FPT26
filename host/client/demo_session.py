"""Persistent model session for the small Prefill/Decode demonstration GUI.

Torch and Transformers are imported only inside the background model loader.
Cancellation is checked between completed attention jobs, never halfway
through an FPGA transfer or a running board job.
"""
from dataclasses import dataclass
import gc
import logging
import os
from pathlib import Path
import time


@dataclass(frozen=True)
class DemoConfig:
    model_path: str
    host: str = '192.168.1.10'
    port: int = 50000
    context: int = 2048
    backend: str = 'fpga_v4_udp'
    threads: int = 8

    def __post_init__(self):
        if not self.model_path.strip() or not Path(self.model_path).is_dir():
            raise ValueError('请选择存在的本地模型目录')
        if not self.host.strip() or not 1 <= self.port <= 65535:
            raise ValueError('请检查 FPGA IP 和端口')
        if not 1 < self.context <= 8192 or not 1 <= self.threads <= 64:
            raise ValueError('KV 容量须为 2–8192，CPU 线程数须为 1–64')
        if self.backend != 'fpga_v4_udp':
            raise ValueError('此演示包只使用 v4.6 FPGA Attention 后端')


class DemoCancelled(RuntimeError):
    pass


class LayerBridge:
    """The model hooks keep this object while each new Prefill gets a fresh backend."""
    profiler = None

    def __init__(self, session):
        self.session = session
        self.target = None

    def compute_attention(self, **kwargs):
        session = self.session
        session.check_cancel()
        metadata = dict(kwargs.get('metadata') or {})
        metadata.update(kv_session=session.cache_identity,
                        append_only=session.phase == 'DECODE', sequential_layers=True)
        kwargs['metadata'] = metadata
        result = self.target.compute_attention(**kwargs)
        # The backend has waited for done and downloaded the complete result.
        layer = int(kwargs['layer_idx']) + 1
        if layer % 8 == 0 or layer == session.layers:
            session.log.info('%s step=%d layer=%d/%d Q=%d KV=%d attention_done',
                             session.phase, session.step, layer, session.layers,
                             kwargs['q'].shape[-2], kwargs['k'].shape[-2])
            session.emit({'kind': 'layer', 'layer': layer, 'layers': session.layers})
        session.check_cancel()
        return result


class DemoSession:
    def __init__(self, config, emit=None, logger=None):
        self.config = config
        self.emit = emit or (lambda event: None)
        self.log = logger or logging.getLogger('fpt.model_demo')
        self.model = self.tokenizer = self.torch = None
        self.bridge = LayerBridge(self)
        self.cancel_event = None
        self.cache_identity = object()
        self.layers = 0
        self.phase, self.step = 'IDLE', 0
        self.past = self.logits = self.pending_token = None
        self.ids, self.generated = [], []
        self.ended = False
        self.forward_options = {}
        self.model_load_s = 0.

    @property
    def can_decode(self):
        return self.past is not None and not self.ended and len(self.ids) < self.config.context

    def check_cancel(self):
        if self.cancel_event is not None and self.cancel_event.is_set():
            raise DemoCancelled('已停止并收尾当前 Attention 作业，请重新 Prefill')

    def reset_context(self):
        self.cache_identity = object()
        self.past = self.logits = self.pending_token = None
        self.ids, self.generated = [], []
        self.ended = False
        if self.bridge.target is not None:
            close = getattr(self.bridge.target, 'close', None)
            if close is not None:
                close()
            self.bridge.target = None

    def _check_device(self):
        from .v4_udp import V4UDPClient
        with V4UDPClient(self.config.host, self.config.port, timeout_s=1, retries=1) as client:
            client.discover()
            status = client.status()
            ddr = client.ddr_status().rsp_data_u32
            if status.busy:
                raise RuntimeError('FPGA 正忙，请等待其任务结束，并关闭其他控制客户端')
            if status.error or status.core_error or ddr & 0x20000000:
                raise RuntimeError('FPGA 报告核心/DMA 错误，请重新加载位流后再试')
            if not ddr & 0x80000000:
                raise RuntimeError('DDR 尚未校准完成，请稍后重试')
        self.log.info('FPGA ready: AT45 DDR=0x%08X target=%s:%d',
                      ddr, self.config.host, self.config.port)

    def _load_model(self):
        if self.model is not None:
            self.log.info('复用已加载模型；开始新的提示词，重建 KV 会话')
            return
        self.emit({'kind': 'phase', 'text': '正在加载本地模型…'})
        self.log.info('加载本地模型：%s', self.config.model_path)
        os.environ.setdefault('HF_HUB_OFFLINE', '1')
        os.environ.setdefault('TRANSFORMERS_OFFLINE', '1')
        os.environ.setdefault('HF_HUB_DISABLE_PROGRESS_BARS', '1')
        os.environ.setdefault('OMP_NUM_THREADS', str(self.config.threads))
        os.environ.setdefault('MKL_NUM_THREADS', str(self.config.threads))
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        from .llama_patch import install_llama_attention_backend
        import inspect
        torch.set_num_threads(self.config.threads)
        self.torch = torch
        start = time.perf_counter()
        tokenizer = AutoTokenizer.from_pretrained(self.config.model_path, local_files_only=True)
        model = AutoModelForCausalLM.from_pretrained(
            self.config.model_path, local_files_only=True,
            dtype=torch.bfloat16, low_cpu_mem_usage=True).eval()
        layers = install_llama_attention_backend(model, self.bridge, enforce_prefill=False)
        if layers == 0:
            raise RuntimeError('模型没有兼容的 Llama Attention 层')
        self.tokenizer, self.model, self.layers = tokenizer, model, layers
        if 'logits_to_keep' in inspect.signature(model.forward).parameters:
            self.forward_options = {'logits_to_keep': 1}
        eos = model.generation_config.eos_token_id
        self.eos_ids = set(eos if isinstance(eos, (tuple, list)) else [eos])
        self.eos_ids.discard(None)
        if tokenizer.eos_token_id is not None:
            self.eos_ids.add(tokenizer.eos_token_id)
        self.model_load_s = time.perf_counter()-start
        self.log.info('模型加载完成：layers=%d dtype=BF16 CPU_threads=%d load_s=%.3f',
                      layers, self.config.threads, self.model_load_s)

    def _new_backend(self):
        from .attention_backends import make_attention_backend
        self.bridge.target = make_attention_backend(
            self.config.backend, udp_host=self.config.host, udp_port=self.config.port,
            udp_timeout_s=1, fpga_max_seq_len=self.config.context,
            fpga_udp_window=4, fpga_ddr_chunk_words=360)

    def _snapshot(self):
        backend = self.bridge.target
        result = {'attention_calls': backend.stats.calls, 'attention_s': backend.stats.total_s}
        result.update(getattr(backend, 'metrics', {}))
        client = getattr(backend, 'client', None)
        if client is not None:
            result.update({name: getattr(client, name) for name in
                           ('tx_datagram_count', 'rx_datagram_count', 'timeout_count', 'tx_bytes', 'rx_bytes')})
            result['early_retry_count'] = getattr(client, 'early_retry_count', 0)
        return result

    def _log_stats(self, before=None):
        result = self._snapshot()
        if before:
            result = {name: value-before[name] for name, value in result.items()}
        self.log.info('%s stats %s', self.phase,
                      ' '.join(f'{key}={value:.6f}' if isinstance(value,float) else f'{key}={value}'
                               for key,value in result.items()))
        return result

    def prefill(self, prompt, cancel_event):
        if not prompt.strip():
            raise ValueError('请输入提示词')
        self.cancel_event = cancel_event
        self.reset_context()
        self.check_cancel()
        self._check_device()
        self.check_cancel()
        self._load_model()
        self.check_cancel()
        tokens = self.tokenizer(prompt, return_tensors='pt')
        length = int(tokens['input_ids'].shape[1])
        if not 0 < length < self.config.context:
            raise ValueError(f'提示词有 {length} 个 token，需要小于 KV 容量 {self.config.context}')
        self._new_backend()
        self.phase, self.step = 'PREFILL', 0
        self.emit({'kind': 'phase', 'text': f'Prefill · {length} 个输入 token'})
        self.log.info('PREFILL start input_tokens=%d context_capacity=%d', length, self.config.context)
        start = time.perf_counter()
        with self.torch.inference_mode():
            result = self.model(**tokens, use_cache=True, **self.forward_options)
        self.check_cancel()
        if result.past_key_values is None:
            raise RuntimeError('模型未返回 KV cache，无法接续 Decode')
        self.past = result.past_key_values
        self.logits = result.logits[:, -1].detach().clone()
        self.ids = tokens['input_ids'][0].tolist()
        elapsed = time.perf_counter()-start
        next_id = int(self.logits.argmax(dim=-1)[0])
        preview = self.tokenizer.decode([next_id], skip_special_tokens=True)
        stats = self._log_stats()
        self.log.info('PREFILL done model_ms=%.3f input_tokens=%d next_token_id=%d preview=%r',
                      elapsed*1000, length, next_id, preview)
        return {'prefill_ms': elapsed*1000, 'model_load_s': self.model_load_s, 'prompt_tokens': length, 'next_token': preview,
                'generated': 0, 'remaining': self.config.context-length,
                'can_decode': self.can_decode, 'stats': stats}

    def decode(self, count, cancel_event):
        if not self.can_decode:
            raise ValueError('请先完成 Prefill，再运行 Decode')
        if not 1 <= count <= self.config.context-len(self.ids):
            raise ValueError(f'本次最多还能生成 {self.config.context-len(self.ids)} 个 token')
        self.cancel_event = cancel_event
        self.phase, self.step = 'DECODE', 0
        self.check_cancel()
        before = self._snapshot()
        self.log.info('DECODE start requested=%d existing_tokens=%d reuse_KV=true', count, len(self.ids))
        self.emit({'kind': 'phase', 'text': 'Decode · 使用 Prefill / 上次 Decode 的 KV cache'})
        start = time.perf_counter()
        emitted = 0
        token_timings = []
        with self.torch.inference_mode():
            for index in range(count):
                self.check_cancel()
                self.step = index+1
                token_start = time.perf_counter()
                advanced_cache = self.pending_token is not None
                # One predicted token may not yet be in the cache. Consume it
                # exactly once on the next step, including across button clicks.
                if self.pending_token is not None:
                    result = self.model(
                        input_ids=self.torch.tensor([[self.pending_token]], dtype=self.torch.long),
                        attention_mask=self.torch.ones((1,len(self.ids)), dtype=self.torch.long),
                        past_key_values=self.past, use_cache=True, **self.forward_options)
                    self.check_cancel()
                    self.past = result.past_key_values
                    self.logits = result.logits[:, -1].detach().clone()
                    self.pending_token = None
                token = int(self.logits.argmax(dim=-1)[0])
                self.ids.append(token)
                self.generated.append(token)
                self.pending_token = token
                emitted += 1
                token_ms = (time.perf_counter()-token_start)*1000
                token_timings.append({'ms':token_ms,'model_forward':advanced_cache,'token_id':token})
                self.log.info('DECODE timing token_id=%d model_forward=%s latency_ms=%.3f',
                              token, advanced_cache, token_ms)
                text = self.tokenizer.decode(self.generated, skip_special_tokens=True)
                self.emit({'kind': 'token', 'text': text, 'generated': len(self.generated),
                           'step': emitted, 'requested': count})
                self.log.info('DECODE token step=%d/%d token_id=%d piece=%r total_generated=%d',
                              emitted, count, token,
                              self.tokenizer.decode([token], skip_special_tokens=False), len(self.generated))
                if token in self.eos_ids:
                    self.ended = True
                    self.log.info('DECODE reached EOS')
                    break
        elapsed = time.perf_counter()-start
        stats = self._log_stats(before)
        rate = emitted/elapsed if elapsed else 0.
        self.log.info('DECODE done emitted=%d total_generated=%d wall_s=%.3f tokens_per_s=%.3f',
                      emitted, len(self.generated), elapsed, rate)
        return {'decode_s': elapsed, 'tokens_per_s': rate, 'emitted': emitted,
                'token_timings': token_timings,
                'generated': len(self.generated), 'remaining': self.config.context-len(self.ids),
                'can_decode': self.can_decode, 'eos': self.ended, 'stats': stats,
                'text': self.tokenizer.decode(self.generated, skip_special_tokens=True)}

    def close(self):
        self.reset_context()
        self.model = self.tokenizer = None
        gc.collect()
