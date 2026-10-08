"""Reference orchestration for admission, x402 payment, delivery and refund."""

import asyncio
import hashlib
import uuid
from dataclasses import dataclass, field
from typing import Any, Literal, Protocol

from .intake import canonical
from .pipeline import DecisionFailure, DecisionPipeline, PreparedDecision


@dataclass(frozen=True)
class PaymentQuote:
    call_id: str
    payer: str
    amount_atomic: int
    network: str
    asset: str
    pay_to: str
    expires_at: int


class PaymentAdapter(Protocol):
    async def quote(self, *, call_id: str, payer: str, input_sha256: str) -> PaymentQuote: ...
    async def verify(self, quote: PaymentQuote, proof: Any) -> dict: ...
    async def complete(self, quote: PaymentQuote, result_sha256: str) -> dict: ...
    async def refund(self, quote: PaymentQuote, reason: str) -> dict: ...


class WorkflowError(Exception):
    def __init__(self, code: str, **details):
        self.code = code
        self.details = details
        super().__init__(code)


@dataclass(frozen=True)
class OrderView:
    call_id: str
    status: str
    quote: PaymentQuote


@dataclass(frozen=True)
class TerminalReceipt:
    call_id: str
    status: Literal["completed", "refunded"]
    payer: str
    quote: PaymentQuote
    payment_receipt: dict | None
    settlement_receipt: dict | None
    failure_code: str | None
    result: None = None


@dataclass
class _Order:
    call_id: str
    request_key: str
    payer: str
    prepared: PreparedDecision
    quote: PaymentQuote
    status: str = "quoted"
    payment_receipt: dict | None = None
    result: dict | None = None
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class Delivery:
    """A checked result awaiting confirmation that the HTTP body was delivered."""

    def __init__(self, workflow, order: _Order):
        self._workflow = workflow
        self.call_id = order.call_id
        self.status = "result_ready"
        self.quote = order.quote
        self.result = order.result

    async def acknowledge(self) -> TerminalReceipt:
        return await self._workflow.acknowledge_delivery(self.call_id)

    async def fail(self, reason: str = "response_not_delivered") -> TerminalReceipt:
        return await self._workflow.fail_delivery(self.call_id, reason)


class ResolveSignalWorkflow:
    """Stateless-after-terminal reference implementation.

    `submit` runs all free gates and returns a quote. `pay_and_process` verifies one
    payment and returns one checked result. Settlement occurs only after the caller
    confirms delivery; any paid quality or delivery failure follows the refund path.
    """

    def __init__(
        self,
        *,
        pipeline: DecisionPipeline,
        payment: PaymentAdapter,
        max_concurrency: int = 10,
        processing_timeout_seconds: float = 60,
    ):
        if max_concurrency < 1:
            raise ValueError("max_concurrency must be positive")
        if processing_timeout_seconds <= 0:
            raise ValueError("processing_timeout_seconds must be positive")
        self.pipeline = pipeline
        self.payment = payment
        self.processing_timeout_seconds = processing_timeout_seconds
        self._compute_slots = asyncio.Semaphore(max_concurrency)
        self._index_lock = asyncio.Lock()
        self._submissions: dict[str, tuple[str, asyncio.Task]] = {}
        self._idempotency: dict[str, str] = {}
        self._orders: dict[str, _Order] = {}
        self._receipts: dict[str, TerminalReceipt] = {}

    async def submit(self, payload: dict, *, payer: str, request_key: str) -> OrderView:
        if not payer.strip() or not request_key.strip():
            raise WorkflowError("payer_and_request_key_required")
        async with self._index_lock:
            prior_id = self._idempotency.get(request_key)
            if prior_id:
                prior = self._orders.get(prior_id)
                if prior is None:
                    raise WorkflowError("request_already_terminal", call_id=prior_id)
                if prior.payer != payer:
                    raise WorkflowError("idempotency_payer_mismatch")
                return OrderView(prior.call_id, prior.status, prior.quote)
            pending = self._submissions.get(request_key)
            if pending:
                if pending[0] != payer:
                    raise WorkflowError("idempotency_payer_mismatch")
                task = pending[1]
            else:
                task = asyncio.create_task(self._submit_new(payload, payer=payer, request_key=request_key))
                self._submissions[request_key] = (payer, task)
        try:
            return await asyncio.shield(task)
        finally:
            if task.done():
                async with self._index_lock:
                    current = self._submissions.get(request_key)
                    if current and current[1] is task:
                        self._submissions.pop(request_key, None)

    async def _submit_new(self, payload: dict, *, payer: str, request_key: str) -> OrderView:
        prepared = await self.pipeline.prepare(payload)
        call_id = "call_" + uuid.uuid4().hex
        quote = await self.payment.quote(
            call_id=call_id,
            payer=payer,
            input_sha256=prepared.contract.input_sha256,
        )
        if quote.call_id != call_id or quote.payer != payer:
            raise WorkflowError("quote_binding_mismatch")
        order = _Order(call_id, request_key, payer, prepared, quote)
        async with self._index_lock:
            self._orders[call_id] = order
            self._idempotency[request_key] = call_id
        return OrderView(call_id, order.status, quote)

    async def pay_and_process(self, call_id: str, *, payment_proof: Any) -> Delivery:
        order = self._orders.get(call_id)
        if order is None:
            receipt = self._receipts.get(call_id)
            raise WorkflowError("request_terminal" if receipt else "request_not_found")
        async with order.lock:
            if order.status == "result_ready":
                return Delivery(self, order)
            if order.status != "quoted":
                raise WorkflowError("request_not_payable", status=order.status)
            try:
                order.payment_receipt = await self.payment.verify(order.quote, payment_proof)
            except Exception as exc:
                raise WorkflowError("payment_not_verified") from exc
            order.status = "paid"
            try:
                async with self._compute_slots:
                    order.status = "processing"
                    order.result = await asyncio.wait_for(
                        self.pipeline.decide(order.prepared, call_id=call_id),
                        timeout=self.processing_timeout_seconds,
                    )
                    order.status = "result_ready"
                    return Delivery(self, order)
            except TimeoutError as exc:
                code = "response_deadline_exceeded"
                settlement = await self.payment.refund(order.quote, code)
                self._terminal(order, "refunded", settlement=settlement, failure=code)
                raise WorkflowError("service_failed_refunded", cause=code) from exc
            except DecisionFailure as exc:
                settlement = await self.payment.refund(order.quote, exc.code)
                self._terminal(order, "refunded", settlement=settlement, failure=exc.code)
                raise WorkflowError("service_failed_refunded", cause=exc.code) from exc
            except Exception as exc:
                settlement = await self.payment.refund(order.quote, "analysis_failed")
                self._terminal(order, "refunded", settlement=settlement, failure="analysis_failed")
                raise WorkflowError("service_failed_refunded", cause="analysis_failed") from exc

    async def acknowledge_delivery(self, call_id: str) -> TerminalReceipt:
        order = self._orders.get(call_id)
        if order is None:
            receipt = self._receipts.get(call_id)
            if receipt:
                return receipt
            raise WorkflowError("request_not_found")
        async with order.lock:
            if order.status != "result_ready" or order.result is None:
                raise WorkflowError("result_not_ready")
            commitment = hashlib.sha256(canonical(order.result).encode("utf-8")).hexdigest()
            settlement = await self.payment.complete(order.quote, commitment)
            return self._terminal(order, "completed", settlement=settlement)

    async def fail_delivery(self, call_id: str, reason: str) -> TerminalReceipt:
        order = self._orders.get(call_id)
        if order is None:
            receipt = self._receipts.get(call_id)
            if receipt:
                return receipt
            raise WorkflowError("request_not_found")
        async with order.lock:
            if order.status != "result_ready":
                raise WorkflowError("result_not_ready")
            settlement = await self.payment.refund(order.quote, reason)
            return self._terminal(order, "refunded", settlement=settlement, failure=reason)

    def _terminal(self, order: _Order, status: Literal["completed", "refunded"], *, settlement: dict, failure: str | None = None):
        receipt = TerminalReceipt(
            call_id=order.call_id,
            status=status,
            payer=order.payer,
            quote=order.quote,
            payment_receipt=order.payment_receipt,
            settlement_receipt=settlement,
            failure_code=failure,
        )
        self._receipts[order.call_id] = receipt
        self._orders.pop(order.call_id, None)
        order.prepared = None
        order.result = None
        return receipt

    def receipt(self, call_id: str) -> TerminalReceipt:
        try:
            return self._receipts[call_id]
        except KeyError as exc:
            raise WorkflowError("receipt_not_found") from exc

    def has_sensitive_context(self, call_id: str) -> bool:
        order = self._orders.get(call_id)
        return bool(order and (order.prepared is not None or order.result is not None))
