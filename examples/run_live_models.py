"""Run only the decision core. A paid seller must use ResolveSignalWorkflow."""

import asyncio
import json
import os
from datetime import datetime, timezone
from pathlib import Path

from resolvesignal_pipeline import DecisionPipeline, JevAdmissionClient, OpenAIDecisionClient


async def main():
    request = json.loads(Path("examples/complete-request.json").read_text(encoding="utf-8"))
    # The public fixture is static; a live request must carry a fresh observation time.
    request["observed_at"] = datetime.now(timezone.utc).isoformat()
    jev = JevAdmissionClient(
        api_key=os.environ["TYPESAFE_API_KEY"],
        model=os.getenv("JEV_ADMISSION_MODEL", "jev-1.13.0"),
    )
    gpt = OpenAIDecisionClient(
        api_key=os.environ["OPENAI_API_KEY"],
        model=os.getenv("OPENAI_DECISION_MODEL", "gpt-5.4"),
    )
    pipeline = DecisionPipeline(jev=jev, gpt=gpt)
    try:
        prepared = await pipeline.prepare(request)
        result = await pipeline.decide(prepared, call_id="local_example")
        print(json.dumps(result, ensure_ascii=False, indent=2))
    finally:
        await jev.close()
        await gpt.close()


if __name__ == "__main__":
    asyncio.run(main())
