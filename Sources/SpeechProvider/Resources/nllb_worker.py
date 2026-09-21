#!/usr/bin/env python3
"""Persistent NLLB worker. Loads model once and exchanges NDJSON over stdio."""

import argparse
import json
import sys

import ctranslate2
import langcodes
from transformers import AutoTokenizer


SCRIPT_BY_LANGUAGE = {
    "ara": "Arab",
    "aze": "Latn",
    "ben": "Beng",
    "bul": "Cyrl",
    "chi": "Hans",
    "cmn": "Hans",
    "ell": "Grek",
    "heb": "Hebr",
    "hin": "Deva",
    "jpn": "Jpan",
    "kaz": "Cyrl",
    "kor": "Hang",
    "mkd": "Cyrl",
    "pan": "Guru",
    "pes": "Arab",
    "rus": "Cyrl",
    "srp": "Cyrl",
    "tam": "Taml",
    "tel": "Telu",
    "tha": "Thai",
    "ukr": "Cyrl",
    "urd": "Arab",
    "yid": "Hebr",
    "zho": "Hans",
}


def language_code(tag: str, available: set[str]) -> str:
    normalized = tag.strip().replace("_", "-")
    if "_" in tag and tag in available:
        return tag

    language = langcodes.Language.get(normalized)
    alpha3 = language.to_alpha3()
    candidates = sorted(code for code in available if code.startswith(alpha3 + "_"))
    if not candidates:
        raise ValueError(f"NLLB does not support language: {tag}")
    if len(candidates) == 1:
        return candidates[0]

    requested_script = language.script or SCRIPT_BY_LANGUAGE.get(alpha3)
    if requested_script:
        scripted = f"{alpha3}_{requested_script}"
        if scripted in available:
            return scripted
    return candidates[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    translator = ctranslate2.Translator(
        args.model,
        device="cpu",
        compute_type="int8",
        inter_threads=1,
        intra_threads=6,
    )
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    available = {
        token
        for token in tokenizer.additional_special_tokens
        if "_" in token and len(token) >= 7
    }

    for raw_line in sys.stdin:
        try:
            request = json.loads(raw_line)
            source = language_code(request["source"], available)
            target = language_code(request["target"], available)
            tokenizer.src_lang = source
            source_tokens = tokenizer.convert_ids_to_tokens(
                tokenizer.encode(request["text"])
            )
            result = translator.translate_batch(
                [source_tokens],
                target_prefix=[[target]],
                beam_size=max(1, int(request.get("beamSize", 1))),
                max_decoding_length=256,
            )[0]
            target_tokens = result.hypotheses[0][1:]
            translation = tokenizer.decode(
                tokenizer.convert_tokens_to_ids(target_tokens),
                skip_special_tokens=True,
            )
            response = {"id": request["id"], "translation": translation}
        except Exception as error:  # Worker must survive malformed individual requests.
            request_id = request.get("id", "unknown") if "request" in locals() else "unknown"
            response = {"id": request_id, "error": str(error)}

        print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
