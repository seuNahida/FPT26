"""ATN1 framing, bounded requests and board status used by v4 transport."""


from __future__ import annotations
from contextlib import nullcontext


from dataclasses import dataclass
import socket
import time


def probe_span(profiler, name):
    # This file is also loaded standalone by the lightweight GUI.
    return profiler.span(name) if profiler is not None else nullcontext()


MAGIC = b"ATN1"


VERSION = 1


CMD_STATUS = 0x01


CMD_CLEAR = 0x02


CMD_READ_PERF = 0x21


CMD_DDR_STATUS = 0x40


ATN1_REQUEST_HEADER_BYTES = 24


ATN1_REPLY_HEADER_BYTES = 32


STANDARD_ETHERNET_MTU_BYTES = 1500


UDP_IPV4_PAYLOAD_LIMIT_BYTES = STANDARD_ETHERNET_MTU_BYTES - 20 - 8


FPGA_DDR_BULK_MAX_WORDS = (
    UDP_IPV4_PAYLOAD_LIMIT_BYTES - ATN1_REPLY_HEADER_BYTES
) // 4


MAX_BULK_WORDS = FPGA_DDR_BULK_MAX_WORDS


DEFAULT_BULK_READ_CHUNK_WORDS = FPGA_DDR_BULK_MAX_WORDS


RSP_OK = 0x00


RSP_BUSY = 0x01


RSP_BAD_ARG = 0x02


RSP_UNSUPPORTED = 0x03


RSP_ERROR = 0x04


STATUS_NAME = {
    RSP_OK: "OK",
    RSP_BUSY: "BUSY",
    RSP_BAD_ARG: "BAD_ARG",
    RSP_UNSUPPORTED: "UNSUPPORTED",
    RSP_ERROR: "ERROR",
}


class FPGAProtocolError(RuntimeError):
    """Raised when the FPGA UDP reply is malformed or reports an error."""


@dataclass(frozen=True)
class ATN1Reply:
    done: int
    busy: int
    error: int
    core_error: int
    pods_done: int
    cfg: int
    rsp_status: int
    cycles: int
    outputs: int
    rsp_opcode: int
    rsp_txn: int
    rsp_data_u32: int
    rsp_data_i32: int
    bulk_payload: bytes

    @property
    def status_name(self) -> str:
        return STATUS_NAME.get(self.rsp_status, f"UNKNOWN_0x{self.rsp_status:02x}")


def _build_payload(
    opcode: int,
    txn: int,
    *,
    flags: int = 0,
    arg0: int = 0,
    arg1: int = 0,
    arg2: int = 0,
) -> bytes:
    return b"".join(
        [
            MAGIC,
            bytes([VERSION, opcode & 0xFF, flags & 0xFF, 0]),
            (txn & 0xFFFF).to_bytes(2, "big"),
            b"\x00\x00",
            (arg0 & 0xFFFF_FFFF).to_bytes(4, "big"),
            (arg1 & 0xFFFF_FFFF).to_bytes(4, "big"),
            (arg2 & 0xFFFF_FFFF).to_bytes(4, "big"),
        ]
    )


def parse_reply(data: bytes) -> ATN1Reply:
    if len(data) < 32 or data[:4] != MAGIC:
        raise FPGAProtocolError(f"bad ATN1 reply: {data.hex(' ')}")

    flags = data[4]
    return ATN1Reply(
        done=flags & 0x1,
        busy=(flags >> 1) & 0x1,
        error=(flags >> 2) & 0x1,
        core_error=(flags >> 3) & 0x1,
        pods_done=data[5] & 0xF,
        cfg=data[6] & 0xF,
        rsp_status=data[7],
        cycles=int.from_bytes(data[8:16], "big"),
        outputs=int.from_bytes(data[16:24], "big"),
        rsp_opcode=data[24],
        rsp_txn=int.from_bytes(data[26:28], "big"),
        rsp_data_u32=int.from_bytes(data[28:32], "big", signed=False),
        rsp_data_i32=int.from_bytes(data[28:32], "big", signed=True),
        bulk_payload=data[32:],
    )


class ATN1UDPClient:
    def __init__(
        self,
        host: str = "192.168.1.10",
        port: int = 50000,
        *,
        timeout_s: float = 2.0,
        retries: int = 1,
        busy_retries: int = 200,
        busy_sleep_s: float = 0.002,
        bulk_chunk_words: int = DEFAULT_BULK_READ_CHUNK_WORDS,
    ) -> None:
        if not 1 <= bulk_chunk_words <= MAX_BULK_WORDS:
            raise ValueError(
                f"bulk_chunk_words must be 1..{MAX_BULK_WORDS}, got {bulk_chunk_words}"
            )
        self.addr = (host, port)
        self.timeout_s = timeout_s
        self.retries = retries
        self.busy_retries = busy_retries
        self.busy_sleep_s = busy_sleep_s
        self.bulk_chunk_words = bulk_chunk_words
        self._sock: socket.socket | None = None
        self._txn = time.monotonic_ns() & 0xFFFF
        self.request_count = 0
        self.tx_datagram_count = 0
        self.rx_datagram_count = 0
        self.timeout_count = 0
        self.busy_reply_count = 0
        self.tx_bytes = 0
        self.rx_bytes = 0
        self.profiler = None

    def __enter__(self) -> "ATN1UDPClient":
        self.open()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def open(self) -> None:
        if self._sock is None:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            # Large board transfers should not be dropped merely because the
            # Python process was briefly descheduled while PyTorch was active.
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
            self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
            self._sock.settimeout(self.timeout_s)

    def close(self) -> None:
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def _next_txn(self) -> int:
        self._txn = (self._txn + 1) & 0xFFFF
        return self._txn

    def request(self, opcode: int, **kwargs) -> ATN1Reply:
        prefix = "probe_udp" if self.profiler is not None and self.profiler.observing else "udp"
        with probe_span(self.profiler, f"{prefix}.request.0x{opcode:02x}"):
            return self._request(opcode, **kwargs)

    def _request(
        self,
        opcode: int,
        *,
        flags: int = 0,
        arg0: int = 0,
        arg1: int = 0,
        arg2: int = 0,
        extra_payload: bytes = b"",
        expect_status: int | None = RSP_OK,
        allow_busy_retry: bool = True,
    ) -> ATN1Reply:
        self.open()
        assert self._sock is not None
        self.request_count += 1
        prefix = "probe_udp" if self.profiler is not None and self.profiler.observing else "udp"

        busy_attempt = 0
        while True:
            txn = self._next_txn()
            payload = _build_payload(
                opcode,
                txn,
                flags=flags,
                arg0=arg0,
                arg1=arg1,
                arg2=arg2,
            ) + extra_payload

            last_exc: Exception | None = None
            for attempt in range(self.retries + 1):
                try:
                    if attempt and self.profiler is not None:
                        self.profiler.count(f"{prefix}.retransmissions.0x{opcode:02x}")
                    with probe_span(self.profiler, f"{prefix}.send.0x{opcode:02x}"):
                        self._sock.sendto(payload, self.addr)
                    if self.profiler is not None:
                        self.profiler.count(f"{prefix}.tx_bytes.0x{opcode:02x}", len(payload))
                        self.profiler.count(f"{prefix}.tx_packets.0x{opcode:02x}")
                    self.tx_datagram_count += 1
                    self.tx_bytes += len(payload)
                    while True:
                        with probe_span(self.profiler, f"{prefix}.recv_wait.0x{opcode:02x}"):
                            data, _ = self._sock.recvfrom(65_535)
                        if self.profiler is not None:
                            self.profiler.count(f"{prefix}.rx_bytes.0x{opcode:02x}", len(data))
                            self.profiler.count(f"{prefix}.rx_packets.0x{opcode:02x}")
                        self.rx_datagram_count += 1
                        self.rx_bytes += len(data)
                        with probe_span(self.profiler, f"{prefix}.parse.0x{opcode:02x}"):
                            reply = parse_reply(data)
                        if reply.rsp_txn == txn:
                            break
                        if self.profiler is not None:
                            self.profiler.count(f"{prefix}.ignored_txn.0x{opcode:02x}")
                    break
                except (TimeoutError, socket.timeout, FPGAProtocolError) as exc:
                    last_exc = exc
                    if isinstance(exc, (TimeoutError, socket.timeout)):
                        self.timeout_count += 1
                        if self.profiler is not None:
                            self.profiler.count(f"{prefix}.timeouts.0x{opcode:02x}")
            else:
                raise FPGAProtocolError(
                    f"no valid reply for opcode=0x{opcode:02x} txn=0x{txn:04x}"
                ) from last_exc

            if (
                allow_busy_retry
                and expect_status == RSP_OK
                and reply.rsp_status == RSP_BUSY
                and busy_attempt < self.busy_retries
            ):
                busy_attempt += 1
                self.busy_reply_count += 1
                if self.profiler is not None:
                    self.profiler.count(f"{prefix}.busy_replies.0x{opcode:02x}")
                with probe_span(self.profiler, f"{prefix}.busy_sleep.0x{opcode:02x}"):
                    time.sleep(self.busy_sleep_s)
                continue

            if reply.rsp_opcode != (opcode & 0xFF):
                raise FPGAProtocolError(
                    f"opcode mismatch: sent 0x{opcode:02x}, got 0x{reply.rsp_opcode:02x}"
                )

            if expect_status is not None and reply.rsp_status != expect_status:
                raise FPGAProtocolError(
                    f"opcode=0x{opcode:02x} failed with {reply.status_name} "
                    f"(0x{reply.rsp_status:02x}), data=0x{reply.rsp_data_u32:08x}"
                )

            return reply

    def status(self) -> ATN1Reply:
        return self.request(CMD_STATUS)

    def clear(self) -> ATN1Reply:
        return self.request(CMD_CLEAR)

    def ddr_status(self) -> ATN1Reply:
        return self.request(CMD_DDR_STATUS)

    def read_perf_counter(self, counter_id: int) -> int:
        # Counters remain live while a job is running.  Bracket the low word
        # with high-word reads so a 32-bit rollover cannot tear the value.
        for _ in range(4):
            hi_before = self.request(
                CMD_READ_PERF, arg0=counter_id, arg1=1
            ).rsp_data_u32
            lo = self.request(
                CMD_READ_PERF, arg0=counter_id, arg1=0
            ).rsp_data_u32
            hi_after = self.request(
                CMD_READ_PERF, arg0=counter_id, arg1=1
            ).rsp_data_u32
            if hi_before == hi_after:
                return (hi_after << 32) | lo
        raise FPGAProtocolError(
            f"performance counter {counter_id} changed too quickly to read"
        )

