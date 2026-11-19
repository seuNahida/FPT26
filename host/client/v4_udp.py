"""Packed BF16 transport and v4.6 DDR backend (explicit CAPS handshake).

Bulk packets retain ATN1 framing, with up to 360 packed uint32 words (720
BF16 elements). A bounded window hides UDP round trips. Memory operations
are idempotent; START retries are deduplicated by the v4 controller.
"""
from __future__ import annotations

import socket
import struct
import math
import time
import numpy as np
from .fpga_udp_client import ATN1UDPClient, FPGAProtocolError, _build_payload, parse_reply

HEADER = struct.Struct("!4sBBBBH2xIII")
ACK = struct.Struct("!BxHI")
REVISION = 0x41353631
CAPS = 0x41543435
Q_BASE, O_BASE, KV_BASE, DDR_END = 0, 0x00800000, 0x01000000, 0x20000000


class TransferCancelled(RuntimeError):
    """Cancellation after every already-issued memory request was acknowledged."""


class V4UDPClient(ATN1UDPClient):
    def __init__(self, *args, window=4, early_retry_s=None, **kwargs):
        super().__init__(*args, **kwargs)
        if not 1 <= window <= 4:
            raise ValueError("window must be 1..4 (eight hardware packet slots, room for retries)")
        if not math.isfinite(self.timeout_s) or self.timeout_s<=0:
            raise ValueError('timeout_s must be finite and positive')
        if early_retry_s is not None and (not math.isfinite(early_retry_s) or early_retry_s<=0):
            raise ValueError('early_retry_s must be None or finite and positive')
        self.early_retry_s = early_retry_s
        self.early_retry_count = 0
        self.window = window
        self.checked = False
        self.cancel_check = None
        self.on_progress = None
        self.revision = 0
        self._configured_bases = [None]*4

    def open(self):
        if self._sock is None:
            super().open()
            self._sock.connect(self.addr)  # accept replies only from this board

    def discover(self):
        if self.request(0x05).rsp_data_u32 != CAPS:
            raise FPGAProtocolError("board is not the v4.6 packed-DDR firmware")
        r = self.request(0x09, expect_status=None, allow_busy_retry=False)
        self.revision = r.rsp_data_u32 if r.rsp_status == 0 else 0
        self.checked = True

    def request(self, opcode, **kwargs):
        r = super().request(opcode, **kwargs)
        if opcode == 6 and r.rsp_status == 0 and kwargs.get('arg0', 0) < 4:
            self._configured_bases[kwargs.get('arg0', 0)] = kwargs.get('arg1', 0)
        return r

    def set_tuning(self, *, burst_lines=1, credit=32, split=True):
        if burst_lines not in (1,2,4,8,16) or not 1 <= credit <= 32:
            raise ValueError('burst_lines must be 1/2/4/8/16 and credit 1..32')
        if not self.checked:self.discover()
        if self.revision != REVISION:
            raise FPGAProtocolError('tuning requires the A561 experiment firmware')
        value=(burst_lines.bit_length()-1) | ((0 if credit==32 else credit)<<3) | (int(not split)<<9)
        self.request(8,arg0=value,allow_busy_retry=False)

    def close(self):
        super().close()
        self.checked = False
        self.revision = 0
        self._configured_bases = [None]*4

    def _bulk(self, addr, count, words=None, *, spans=None):
        if addr & 3 or addr < 0 or count < 0 or addr + 4*count > DDR_END:
            raise ValueError("unaligned or out-of-range DDR transfer")
        if not self.checked:
            self.discover()
        self.open()
        op = 0x43 if words is not None else 0x44
        result = np.empty(count, dtype='<u4') if words is None else None
        # One vectorized endian conversion replaces one NumPy allocation per packet.
        wire = memoryview(np.asarray(words,dtype='>u4')).cast('B') if words is not None and spans is None else None
        span_index=0
        pending, offset, completed = {}, 0, 0
        cancelled = False
        sock = self._sock
        socket_timeout = self.timeout_s
        timeout_quantum = min(0.001,self.timeout_s/8)
        early = (self.early_retry_s if self.early_retry_s is not None and
                 self.early_retry_s<self.timeout_s and self.retries>0 else float('inf'))
        try:
            while offset < count or pending:
                cancelled |= bool(self.cancel_check and self.cancel_check())
                if cancelled and not pending:
                    raise TransferCancelled("传输已取消，已发出的请求均已收尾")
                while not cancelled and offset < count and len(pending) < self.window:
                    n = min(self.bulk_chunk_words, count-offset)
                    packet_addr=addr+4*offset
                    local_offset=offset
                    if spans is not None:
                        while offset>=spans[span_index][2]:span_index+=1
                        base,first,last,wire=spans[span_index]
                        local_offset=offset-first
                        packet_addr=base+4*local_offset
                        n=min(n,last-offset)
                    # The board MAC's frame FIFO can emit a shorter write
                    # immediately after a full frame, removing the wire IFG.
                    # Its parser needs a few cycles between frames. Drain full
                    # writes before the shorter tail; full packets stay pipelined.
                    if self.revision != REVISION and words is not None and n < self.bulk_chunk_words and pending:
                        break
                    txn = self._next_txn()
                    packet = HEADER.pack(b'ATN1',1,op,0,0,txn,packet_addr,n,0)
                    if words is not None:
                        packet += wire[4*local_offset:4*(local_offset+n)]
                    now = time.monotonic()
                    pending[txn] = [packet, offset, n, 0, now+self.timeout_s, now+early]
                    sock.send(packet)
                    self.tx_datagram_count += 1; self.tx_bytes += len(packet); self.request_count += 1
                    offset += n
                deadline = min(min(x[4],x[5]) for x in pending.values())
                # Normal replies arrive well within 1 ms. Quantize the remaining
                # timeout upward by at most 1 ms, avoiding a socket-mode syscall
                # for every packet while still honoring retry deadlines.
                remaining = deadline-time.monotonic()
                wanted = min(self.timeout_s,max(timeout_quantum,
                             math.ceil(remaining/timeout_quantum)*timeout_quantum))
                if wanted != socket_timeout:
                    sock.settimeout(wanted);socket_timeout=wanted
                try:
                    data = sock.recv(65535)
                except socket.timeout:
                    data = None
                if data is not None:
                    self.rx_datagram_count += 1; self.rx_bytes += len(data)
                    if len(data)<32 or data[:4]!=b'ATN1':
                        raise FPGAProtocolError('malformed bulk reply header')
                    opcode, txn, acknowledged = ACK.unpack_from(data,24)
                    status = data[7]
                    item = pending.get(txn)
                    if item is not None:
                        if opcode != op:
                            raise FPGAProtocolError("bulk reply opcode mismatch")
                        if status == 1:
                            # Keep the deadline: retry within the same bounded budget.
                            pass
                        elif status:
                            raise FPGAProtocolError(f"bulk reply status={status}")
                        else:
                            at, n = item[1], item[2]
                            if acknowledged != n:
                                raise FPGAProtocolError("bulk acknowledgement count mismatch")
                            if result is not None:
                                if len(data) != 32+n*4:
                                    raise FPGAProtocolError("bulk reply payload length mismatch")
                                result[at:at+n] = np.frombuffer(data, dtype='>u4', offset=32, count=n)
                            del pending[txn]
                            completed += n
                            if self.on_progress:
                                self.on_progress(completed*4, count*4)
                now = time.monotonic()
                for txn, item in pending.items():
                    if now >= item[4]:
                        if item[3] >= self.retries:
                            raise TimeoutError(f"bulk transaction {txn} exceeded retry budget")
                        sock.send(item[0]); item[3] += 1; item[4] = now+self.timeout_s
                        item[5] = float('inf')
                        self.timeout_count += 1; self.tx_datagram_count += 1; self.tx_bytes += len(item[0])
                    elif now >= item[5]:
                        # One extra idempotent memory probe. Keep the original
                        # late retry times/budget: a slow peer still gets every
                        # original retry. Never applied to START/control RPCs.
                        sock.send(item[0]); item[5] = float('inf')
                        self.early_retry_count += 1; self.timeout_count += 1
                        self.tx_datagram_count += 1; self.tx_bytes += len(item[0])
        finally:
            sock.settimeout(self.timeout_s)
        return result

    def write_bf16(self, addr, bits):
        bits = np.ascontiguousarray(bits, dtype='<u2').reshape(-1)
        if bits.size % 2:
            raise ValueError("packed tensor must contain an even number of BF16 elements")
        self._bulk(addr, bits.size//2, bits.view('<u4'))

    def read_bf16(self, addr, elements):
        if elements % 2:
            raise ValueError("packed tensor must contain an even number of BF16 elements")
        return self._bulk(addr, elements//2).view('<u2')

    def write_bf16_many(self, regions):
        """Share one bounded window across disjoint DDR spans (same wire opcode).

        A561 accepts adjacent short frames; legacy firmware keeps serialized
        short-tail handling. Every span is validated before any write is sent.
        """
        packed=[]
        for addr,bits in regions:
            bits=np.ascontiguousarray(bits,dtype='<u2').reshape(-1)
            if bits.size%2 or addr<0 or addr%4 or addr+bits.nbytes>DDR_END:
                raise ValueError('invalid packed BF16 span')
            if bits.size:packed.append((addr,bits))
        ranges=sorted((addr,addr+bits.nbytes) for addr,bits in packed)
        if any(end>start2 for (_,end),(start2,_) in zip(ranges,ranges[1:])):
            raise ValueError('concurrent write spans must not overlap')
        if not packed:return
        if not self.checked:self.discover()
        if self.revision!=REVISION:
            for addr,bits in packed:self.write_bf16(addr,bits)
            return
        spans=[];offset=0
        for addr,bits in packed:
            words=bits.view('<u4')
            wire=memoryview(np.asarray(words,dtype='>u4')).cast('B')
            spans.append((addr,offset,offset+len(words),wire));offset+=len(words)
        self._bulk(0,offset,words=True,spans=spans)

    def configure(self, q_len, kv_len, q_pos, groups=1, sub=4, bases=(0,0x2000000,0x4000000,0x6000000), kv_stride=0):
        if not (1 <= q_len <= kv_len <= 8192 and 0 <= q_pos <= kv_len-q_len and 1 <= groups <= 8 and 0 <= sub <= 4):
            raise ValueError("unsupported v4 job geometry")
        if not self.checked:
            self.discover()
        if kv_stride and not kv_len <= kv_stride <= 8192:
            raise ValueError("kv_stride must be zero or kv_len..8192")
        stride = kv_stride or kv_len
        sizes = (q_len*groups*1024, stride*groups*256, stride*groups*256, q_len*groups*1024)
        if len(bases) != 4:
            raise ValueError("four Q/K/V/O bases required")
        for i, (base, size) in enumerate(zip(bases, sizes)):
            if base < 0 or base % 64 or base+size > DDR_END:
                raise ValueError("buffer is unaligned or outside DDR address space")
            if any(base < bases[j]+sizes[j] and bases[j] < base+size for j in range(i)):
                raise ValueError("Q/K/V/O buffers must not overlap")
        for i, base in enumerate(bases):
            if self._configured_bases[i] != base:
                self.request(0x06, arg0=i, arg1=base)
        self.request(0x07, arg0=q_len | (q_pos<<16), arg1=kv_len | (groups<<16) | (sub<<24), arg2=kv_stride)

    def read_perf_counters(self):
        names=('core_cycles','qk_busy','pv_busy','softmax_busy','merge_busy','final_busy',
               'qk_idle','pv_wait','system_cycles','outputs','ddr_read_beats','ddr_write_beats',
               'ddr_stall_cycles','ddr_cycles')
        if self.revision == REVISION:
            names += ('mig_cmd_blocked','mig_wdf_blocked','read_tag_full',
                      'q_request_empty','k_request_empty','v_request_empty','o_request_empty',
                      'port_switches','request_bank_switches','request_same_bank_row_switches',
                      'inflight_0','inflight_1_7','inflight_8_15','inflight_16_31',
                      'inflight_32_47','inflight_48_63','inflight_64',
                      'o_credit_wait','q_fifo_empty','k_fifo_empty','v_fifo_empty',
                      'final_credit_wait','final_issue')
        return {name:self.read_perf_counter(i) for i,name in enumerate(names)}

    def wait_done(self, *, timeout_s=60, poll_interval_s=0.001):
        deadline = time.monotonic()+timeout_s
        polls=0
        delay=0.0
        while time.monotonic() < deadline:
            r = self.status()
            if r.error or r.core_error:
                raise FPGAProtocolError("v4 DMA/core error")
            if r.done and not r.busy:
                return r
            # Short DDR jobs often finish within one more UDP round trip.
            # Poll twice without a millisecond sleep, then back off to the
            # caller's interval for long Prefill jobs or an unavailable device.
            polls+=1
            if polls>=2 and poll_interval_s>0:
                delay=min(poll_interval_s,max(0.00001,delay*2))
                time.sleep(delay)
        raise TimeoutError("v4 job did not finish; reset/reconnect before reusing its buffers")


