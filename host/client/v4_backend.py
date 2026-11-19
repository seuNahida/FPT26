"""Llama AT45 backend: bank-separated KV, bounded Q/O and append-only sessions."""
from __future__ import annotations
from collections import OrderedDict
from dataclasses import dataclass
import time
import numpy as np
from .v4_udp import V4UDPClient, DDR_END, REVISION
from .attention_backends import BaseAttentionBackend


@dataclass
class CacheEntry:
    slot: int
    length: int
    groups: int
    session: object
    k: object = None
    v: object = None


class V4AttentionBackend(BaseAttentionBackend):
    name = 'fpga_v4_udp'

    def __init__(self, *, host, port, timeout_s, max_seq_len=128, retries=1,
                 max_wait_s=180, bulk_chunk_words=360, poll_interval_s=0.001,
                 window=4, query_capacity=128, layout='banks', adaptive_tuning=True,
                 early_retry_s=0.02):
        super().__init__()
        if not 1 <= max_seq_len <= 8192 or not 1 <= query_capacity <= 8192:
            raise ValueError('v4 capacities must be 1..8192')
        if layout not in ('banks','compact'):
            raise ValueError('layout must be banks or compact')
        self.client = V4UDPClient(host,port,timeout_s=timeout_s,retries=retries,
                                  bulk_chunk_words=bulk_chunk_words,window=window,early_retry_s=early_retry_s)
        self.max_seq_len, self.max_wait_s = max_seq_len, max_wait_s
        self.query_capacity = min(max_seq_len,query_capacity)
        self.poll_interval_s = poll_interval_s
        self.layout = layout
        self.adaptive_tuning = adaptive_tuning
        self._last_burst = None
        self.head_stride = max_seq_len*256
        tensor = 8*self.head_stride
        reserve = 8*self.query_capacity*1024
        self.q_base = 0
        if layout == 'banks':
            bank = DDR_END//4
            self.o_base = 3*bank
            # K in banks 0/1, V in 2/3. Use all remaining capacity rather than
            # reserving four entire banks for four individual tensors.
            k_roots = [b+o for b,start in ((0,reserve),(bank,0))
                       for o in range(start,bank-tensor+1,tensor)]
            v_roots = [b+o for b,start in ((2*bank,0),(3*bank,reserve))
                       for o in range(start,bank-tensor+1,tensor)]
            self.regions = list(zip(k_roots,v_roots))
        else:
            self.o_base = reserve
            self.regions = [(2*reserve+i*2*tensor,2*reserve+(2*i+1)*tensor)
                            for i in range((DDR_END-2*reserve)//(2*tensor))]
        self.slots = len(self.regions)
        if not self.slots:raise ValueError('no KV slot fits the requested capacities')
        self.cache = OrderedDict()
        self.free = list(range(self.slots))
        self.poisoned = False
        self.metrics = {n:0 for n in ('cache_hits','cache_misses','cache_evictions','cache_mru_evictions',
                        'kv_upload_bytes','q_upload_bytes','o_download_bytes','fast_appends',
                        'host_copy_bytes','cache_copy_s','jobs','prefix_check_s','pack_s','upload_s',
                        'configure_s','execute_s','download_s','tuning_changes')}

    def close(self):
        self.client.close()
        self.cache.clear()
        self.free = list(range(self.slots))
        self._last_burst = None

    def compute_attention(self, *, q,k,v,attention_mask,causal,scale,layer_idx,metadata=None):
        import torch
        if self.poisoned:
            raise RuntimeError('previous v4 job failed; reset the board and create a new backend')
        begin=time.perf_counter()
        if q.ndim!=4 or k.ndim!=4 or v.shape!=k.shape or q.shape[0]!=1 or k.shape[0]!=1:
            raise ValueError('v4 requires batch=1 Q/K/V tensors')
        groups,qlen,kvlen=k.shape[1],q.shape[2],k.shape[2]
        if not (q.shape[1]==4*groups and 1<=groups<=8 and q.shape[3]==k.shape[3]==128
                and 1<=qlen<=kvlen<=self.max_seq_len and abs(scale-128**-.5)<1e-10):
            raise ValueError('unsupported v4 tensor geometry/scale')
        pos=kvlen-qlen
        if attention_mask is not None:
            expected=torch.arange(kvlen,device=q.device)[None,:] <= (pos+torch.arange(qlen,device=q.device))[:,None]
            mask=attention_mask[..., -qlen:,:kvlen]
            good=torch.all(mask==expected) if mask.dtype==torch.bool else torch.all(
                torch.where(expected,mask==0,(mask < -1e4)|torch.isneginf(mask)))
            if not good:raise ValueError('v4 does not support padding or custom attention masks')
        elif not causal and qlen!=1:
            raise ValueError('v4 supports causal attention only')
        metadata=metadata or {}
        session=metadata.get('kv_session')
        old=self.cache.pop(layer_idx,None)
        if old is None:
            if self.free:slot=self.free.pop()
            else:
                # A trusted sequential layer scan otherwise thrashes LRU when
                # its working set is one slot too large. The most recently
                # used layer is furthest away in the next cyclic scan.
                mru=session is not None and metadata.get('sequential_layers') is True
                _,evicted=self.cache.popitem(last=mru);slot=evicted.slot
                self.metrics['cache_evictions']+=1
                self.metrics['cache_mru_evictions']+=int(mru)
        else:slot=old.slot
        def bits(x):
            return x.detach().to(device='cpu',dtype=torch.bfloat16).contiguous().view(torch.int16).numpy().view(np.uint16)
        t=time.perf_counter()
        prefix=0
        positions=metadata.get('cache_position')
        # Only a controller that owns an append-only session may opt in.
        # Generic callers retain bitwise prefix validation. Missing/replaced
        # session, rewind, branch, geometry change or eviction triggers upload.
        fast=(old is not None and session is not None and old.session is session
              and metadata.get('append_only') is True and old.groups==groups
              and qlen==1 and old.length==pos and positions is not None
              and len(positions)==1 and int(positions[0])==pos)
        if fast:
            prefix=old.length
            self.metrics['fast_appends']+=1
            kb,vb=bits(k[:,:,prefix:])[0],bits(v[:,:,prefix:])[0]
        else:
            kb,vb=bits(k)[0],bits(v)[0]
            if old is not None and old.k is not None and old.groups==groups and old.length<=kvlen:
                n=old.length
                if np.array_equal(old.k,kb[:,:n]) and np.array_equal(old.v,vb[:,:n]):prefix=n
            kb_upload,vb_upload=kb[:,prefix:],vb[:,prefix:]
        self.metrics['prefix_check_s']+=time.perf_counter()-t
        self.metrics['cache_hits' if prefix else 'cache_misses']+=1
        if fast:kb_upload,vb_upload=kb,vb
        ka,va=self.regions[slot]
        out=np.empty((4*groups,qlen,128),dtype=np.uint16)
        try:
            t=time.perf_counter()
            uploads=[]
            for g in range(groups):
                if prefix<kvlen:
                    uploads.extend([(ka+g*self.head_stride+prefix*256,kb_upload[g]),
                                    (va+g*self.head_stride+prefix*256,vb_upload[g])])
            if hasattr(self.client,'write_bf16_many'):
                self.client.write_bf16_many(uploads)
            else:
                for addr,data in uploads:self.client.write_bf16(addr,data)
            self.metrics['upload_s']+=time.perf_counter()-t
            self.metrics['kv_upload_bytes']+=2*groups*(kvlen-prefix)*256
            for start in range(0,qlen,self.query_capacity):
                n=min(self.query_capacity,qlen-start)
                t=time.perf_counter()
                qb=bits(q[:,:,start:start+n])[0]
                qr=qb.reshape(groups,4,n,128).transpose(0,2,1,3)
                self.metrics['pack_s']+=time.perf_counter()-t
                t=time.perf_counter();self.client.write_bf16(self.q_base,qr)
                self.metrics['upload_s']+=time.perf_counter()-t
                self.metrics['q_upload_bytes']+=qb.nbytes
                t=time.perf_counter()
                # A561 board ablation: long quanta help Prefill and compact
                # layouts; bank-separated long Decode prefers single lines.
                # One command per mode transition, included in configure_s.
                if self.adaptive_tuning and getattr(self.client,'revision',0)==REVISION:
                    burst=16 if n>1 or self.layout=='compact' else 1
                    if burst!=self._last_burst:
                        self.client.set_tuning(burst_lines=burst,credit=32,split=True)
                        self._last_burst=burst
                        self.metrics['tuning_changes']+=1
                self.client.configure(n,kvlen,pos+start,groups=groups,kv_stride=self.max_seq_len,
                    bases=(self.q_base,ka,va,self.o_base))
                self.metrics['configure_s']+=time.perf_counter()-t
                t=time.perf_counter();self.client.request(0x10)
                self.client.wait_done(timeout_s=self.max_wait_s,poll_interval_s=self.poll_interval_s)
                self.metrics['execute_s']+=time.perf_counter()-t
                t=time.perf_counter()
                chunk=self.client.read_bf16(self.o_base,n*groups*4*128)
                out[:,start:start+n]=chunk.reshape(groups,n,4,128).transpose(0,2,1,3).reshape(4*groups,n,128)
                self.metrics['download_s']+=time.perf_counter()-t
                self.metrics['o_download_bytes']+=chunk.nbytes
                self.metrics['jobs']+=1
        except Exception:
            self.poisoned=True
            raise
        # Trusted sessions use lengths/positions, avoiding full-prefix CPU
        # copies. Returning to the generic API forces a conservative rewrite.
        if session is None:
            t=time.perf_counter()
            keepk,keepv=kb.copy(),vb.copy()
            self.metrics['cache_copy_s']+=time.perf_counter()-t
            self.metrics['host_copy_bytes']+=keepk.nbytes+keepv.nbytes
        else:keepk=keepv=None
        self.cache[layer_idx]=CacheEntry(slot,kvlen,groups,session,keepk,keepv)
        result=torch.from_numpy(out.view(np.int16)).view(torch.bfloat16)[None].to(device=q.device,dtype=q.dtype)
        self.stats.add(layer_idx=layer_idx,q=q,k=k,v=v,elapsed_s=time.perf_counter()-begin)
        return result
