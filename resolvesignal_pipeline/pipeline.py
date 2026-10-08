"""Two-boundary pipeline: pre-payment admission, then paid decision compilation."""

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Literal, Protocol

from pydantic import ValidationError

from .compiler import (
    CompiledContract,
    ContractError,
    compile_contract,
    review_packet,
    validate_decision,
)
from .contracts import DecisionIR, SemanticVerdict
from .intake import normalize_request
from .render import render_result


@dataclass(frozen=True)
class AdmissionDecision:
    accepted: bool
    model: str
    reason: str


class AdmissionProvider(Protocol):
    async def admit(self, contract: CompiledContract) -> AdmissionDecision: ...


class DecisionProvider(Protocol):
    async def plan(self, contract: CompiledContract) -> tuple[DecisionIR, str]: ...
    async def review(self, contract: CompiledContract, draft: DecisionIR) -> tuple[SemanticVerdict, str]: ...


class DecisionFailure(Exception):
    def __init__(
        self,
        code: str,
        *,
        stage: str,
        disposition: Literal["do_not_charge", "refund"],
        details: dict | None = None,
    ):
        self.code = code
        self.stage = stage
        self.disposition = disposition
        self.details = details or {}
        super().__init__(code)


@dataclass(frozen=True)
class PreparedDecision:
    contract: CompiledContract
    admission_model: str


class DecisionPipeline:
    def __init__(
        self,
        *,
        jev: AdmissionProvider,
        gpt: DecisionProvider,
        max_state_age_seconds: float = 900,
        clock=None,
    ):
        if max_state_age_seconds <= 0:
            raise ValueError("max_state_age_seconds must be positive")
        self.jev = jev
        self.gpt = gpt
        self.max_state_age_seconds = max_state_age_seconds
        self.clock = clock or (lambda: datetime.now(timezone.utc).timestamp())

    async def prepare(self, payload: dict) -> PreparedDecision:
        try:
            normalized = normalize_request(payload)
            age = self.clock() - normalized.request.observed_at.timestamp()
            if age < -30:
                raise DecisionFailure(
                    "state_from_future",
                    stage="intake",
                    disposition="do_not_charge",
                )
            if age > self.max_state_age_seconds:
                raise DecisionFailure(
                    "state_too_old",
                    stage="intake",
                    disposition="do_not_charge",
                    details={"max_state_age_seconds": self.max_state_age_seconds},
                )
            contract = compile_contract(normalized)
        except DecisionFailure:
            raise
        except ValidationError as exc:
            raise DecisionFailure("input_schema_invalid", stage="intake", disposition="do_not_charge") from exc
        except ContractError as exc:
            raise DecisionFailure(exc.code, stage="deterministic_admission", disposition="do_not_charge", details=exc.details) from exc
        try:
            admission = await self.jev.admit(contract)
        except Exception as exc:
            raise DecisionFailure("jev_unavailable", stage="admission", disposition="do_not_charge") from exc
        if not admission.accepted:
            raise DecisionFailure(
                "admission_rejected",
                stage="admission",
                disposition="do_not_charge",
                details={"reason": admission.reason, "model": admission.model},
            )
        return PreparedDecision(contract=contract, admission_model=admission.model)

    async def decide(self, prepared: PreparedDecision, *, call_id: str):
        try:
            draft, planner_model = await self.gpt.plan(prepared.contract)
        except DecisionFailure:
            raise
        except Exception as exc:
            raise DecisionFailure("planner_unavailable", stage="planning", disposition="refund") from exc
        try:
            review_packet(prepared.contract, draft)
        except ContractError as exc:
            raise DecisionFailure(exc.code, stage="deterministic_validation", disposition="refund", details=exc.details) from exc
        try:
            verdict, checker_model = await self.gpt.review(prepared.contract, draft)
        except Exception as exc:
            raise DecisionFailure("checker_unavailable", stage="semantic_review", disposition="refund") from exc
        try:
            decision = validate_decision(prepared.contract, draft, verdict)
            return render_result(
                decision,
                call_id=call_id,
                profile={
                    "admission_provider": "typesafe",
                    "admission_model": prepared.admission_model,
                    "generation_provider": "openai",
                    "planner_model": planner_model,
                    "checker_model": checker_model,
                },
            )
        except ContractError as exc:
            raise DecisionFailure(exc.code, stage="semantic_review", disposition="refund", details=exc.details) from exc
