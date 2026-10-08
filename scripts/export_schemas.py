"""Export stable JSON schemas without contacting either model provider."""

import json
from pathlib import Path

from resolvesignal_pipeline import DecisionIR, Request, SemanticVerdict, form_document


def main():
    target = Path("schemas")
    target.mkdir(exist_ok=True)
    documents = {
        "request.schema.json": Request.model_json_schema(),
        "decision-ir.schema.json": DecisionIR.model_json_schema(),
        "semantic-verdict.schema.json": SemanticVerdict.model_json_schema(),
        "form.json": form_document(),
    }
    for name, document in documents.items():
        (target / name).write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
