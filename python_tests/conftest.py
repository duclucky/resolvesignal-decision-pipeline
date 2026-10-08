from copy import deepcopy
from datetime import datetime, timezone

import pytest


@pytest.fixture
def request_payload():
    return {
        "objective": {
            "target_id": "invoice-1042",
            "statement": "Move invoice-1042 from pending to a confirmed paid state.",
            "success_contract": {
                "requires_final_state": True,
                "criteria": [
                    {
                        "id": "paid",
                        "description": "The matching invoice is confirmed paid.",
                        "allow_authoritative_absence": False,
                    }
                ],
            },
        },
        "current_state": {
            "status": "provided",
            "content": "Invoice invoice-1042 is pending after the first capture attempt.",
        },
        "observations": [
            {
                "id": "invoice_state",
                "target_id": "invoice-1042",
                "status": "provided",
                "value": {"state": "pending"},
                "explanation": "Current state returned by the billing system.",
                "source": "billing-api",
            },
            {
                "id": "gateway_ready",
                "target_id": "invoice-1042",
                "status": "provided",
                "value": True,
                "explanation": "The payment gateway health check succeeded.",
                "source": "gateway-health",
            },
        ],
        "policy": {
            "authority": {
                "status": "provided",
                "content": "The caller may retry this invoice once for at most USD 25.",
            },
            "constraints": {
                "status": "provided",
                "content": "Do not modify any invoice other than invoice-1042.",
            },
            "allowed_action_ids": ["retry_capture"],
            "forbidden_action_ids": [],
            "conditions": [
                {
                    "id": "gateway_available",
                    "observation_id": "gateway_ready",
                    "operator": "eq",
                    "expected": True,
                    "action_ids": ["retry_capture"],
                }
            ],
        },
        "capabilities": [
            {
                "id": "retry_capture",
                "description": "Retry capture for the declared invoice and amount.",
                "effect": "state_change",
                "requires_approval": False,
                "target_id": "invoice-1042",
                "cost_fact_id": None,
                "arguments": [
                    {"name": "invoice_id", "value": "invoice-1042"},
                    {"name": "max_amount", "value": "25.00"},
                ],
                "response_observations": [
                    {
                        "id": "capture_result",
                        "kind": "problem_state",
                        "description": "Authoritative capture result for the matching invoice.",
                        "cases": [
                            {
                                "id": "paid_final",
                                "description": "The matching invoice is confirmed paid.",
                                "evidence": "usable",
                                "target": "matched",
                                "finality": "final",
                                "operation_completed": True,
                                "satisfies": ["paid"],
                            },
                            {
                                "id": "still_pending",
                                "description": "The matching invoice remains pending.",
                                "evidence": "usable",
                                "target": "matched",
                                "finality": "non_final",
                                "operation_completed": False,
                                "satisfies": [],
                            },
                        ],
                    }
                ],
            }
        ],
        "facts": {
            "status": "none",
            "explanation": "No numerical comparison is needed for this request.",
        },
        "previous_attempts": {
            "status": "provided",
            "content": "One capture attempt returned a pending state.",
        },
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "locale": "en",
    }


@pytest.fixture
def copy_payload():
    return deepcopy
