import asyncio

import pytest

from resolvesignal_pipeline import (
    AdmissionDecision,
    DecisionFailure,
    DecisionIR,
    DecisionPipeline,
    SemanticVerdict,
    SemanticVerdictCheck,
)


def supported_verdict():
    return SemanticVerdict(
        checks=[
            SemanticVerdictCheck(claim_id=name, verdict="supported")
            for name in (
                "action_fit",
                "evidence_relevance",
                "constraint_alignment",
                "goal_alignment",
            )
        ]
    )


def valid_ir():
    return DecisionIR(
        action_id="retry_capture",
        reason_kind="achieve_declared_goal",
        evidence_refs=["invoice_state", "gateway_ready"],
        constraint_refs=["authority", "constraints", "gateway_available"],
        goal_refs=["paid"],
        comparison=None,
    )


class FakeJev:
    def __init__(self, accepted=True):
        self.accepted = accepted
        self.calls = []

    async def admit(self, contract):
        self.calls.append(contract)
        return AdmissionDecision(
            accepted=self.accepted,
            model="jev-test",
            reason="ready" if self.accepted else "insufficient evidence",
        )


class FakeGPT:
    def __init__(self, ir=None, verdict=None):
        self.ir = ir or valid_ir()
        self.verdict = verdict or supported_verdict()
        self.plan_calls = []
        self.review_calls = []

    async def plan(self, contract):
        self.plan_calls.append(contract)
        return self.ir, "gpt-5.4-test"

    async def review(self, contract, draft):
        self.review_calls.append((contract, draft))
        return self.verdict, "gpt-5.4-test"


@pytest.mark.asyncio
async def test_stale_evidence_is_rejected_before_models(request_payload):
    request_payload["observed_at"] = "2020-01-01T00:00:00Z"
    jev, gpt = FakeJev(), FakeGPT()
    pipeline = DecisionPipeline(jev=jev, gpt=gpt, max_state_age_seconds=900)

    with pytest.raises(DecisionFailure) as caught:
        await pipeline.prepare(request_payload)

    assert caught.value.code == "state_too_old"
    assert caught.value.disposition == "do_not_charge"
    assert jev.calls == []


@pytest.mark.asyncio
async def test_jev_rejection_stops_before_payment_boundary(request_payload):
    jev, gpt = FakeJev(False), FakeGPT()
    pipeline = DecisionPipeline(jev=jev, gpt=gpt)

    with pytest.raises(DecisionFailure) as caught:
        await pipeline.prepare(request_payload)

    assert caught.value.stage == "admission"
    assert caught.value.disposition == "do_not_charge"
    assert len(jev.calls) == 1
    assert gpt.plan_calls == []


@pytest.mark.asyncio
async def test_false_guard_is_rejected_before_models(request_payload):
    request_payload["observations"][1]["value"] = False
    jev, gpt = FakeJev(), FakeGPT()
    pipeline = DecisionPipeline(jev=jev, gpt=gpt)

    with pytest.raises(DecisionFailure) as caught:
        await pipeline.prepare(request_payload)

    assert caught.value.code == "no_admissible_action"
    assert caught.value.disposition == "do_not_charge"
    assert jev.calls == []


@pytest.mark.asyncio
async def test_invalid_gpt_ir_is_withheld_and_refundable(request_payload):
    invalid = valid_ir().model_copy(update={"action_id": "invented_action"})
    pipeline = DecisionPipeline(jev=FakeJev(), gpt=FakeGPT(ir=invalid))
    prepared = await pipeline.prepare(request_payload)

    with pytest.raises(DecisionFailure) as caught:
        await pipeline.decide(prepared, call_id="call-invalid")

    assert caught.value.stage == "deterministic_validation"
    assert caught.value.disposition == "refund"


@pytest.mark.asyncio
async def test_unsupported_semantic_claim_is_withheld_and_refundable(request_payload):
    verdict = supported_verdict()
    verdict.checks[3] = SemanticVerdictCheck(
        claim_id="goal_alignment", verdict="uncertain"
    )
    pipeline = DecisionPipeline(jev=FakeJev(), gpt=FakeGPT(verdict=verdict))
    prepared = await pipeline.prepare(request_payload)

    with pytest.raises(DecisionFailure) as caught:
        await pipeline.decide(prepared, call_id="call-uncertain")

    assert caught.value.code == "semantic_check_failed"
    assert caught.value.disposition == "refund"


@pytest.mark.asyncio
async def test_checked_result_is_rendered_from_declared_data(request_payload):
    pipeline = DecisionPipeline(jev=FakeJev(), gpt=FakeGPT())
    prepared = await pipeline.prepare(request_payload)
    result = await pipeline.decide(prepared, call_id="call-1042")

    assert result["call_id"] == "call-1042"
    assert result["decision"]["action_id"] == "retry_capture"
    assert result["decision"]["parameters"] == {
        "invoice_id": "invoice-1042",
        "max_amount": "25.00",
    }
    assert result["decision"]["target_id"] == "invoice-1042"
    assert result["service"]["deliverable"] == "one_conditional_next_action"
    assert result["assurance"]["semantic_certainty"] == "not_guaranteed"


@pytest.mark.asyncio
async def test_concurrent_calls_never_cross_results(request_payload):
    pipeline = DecisionPipeline(jev=FakeJev(), gpt=FakeGPT())

    async def run(call_id):
        prepared = await pipeline.prepare(request_payload)
        return await pipeline.decide(prepared, call_id=call_id)

    results = await asyncio.gather(*(run(f"call-{index}") for index in range(5)))
    assert [result["call_id"] for result in results] == [
        "call-0",
        "call-1",
        "call-2",
        "call-3",
        "call-4",
    ]
    assert all(r["decision"]["target_id"] == "invoice-1042" for r in results)
