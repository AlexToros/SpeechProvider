#!/bin/zsh
set -euo pipefail

root_dir="$1"
venv_dir="$root_dir/nllb-venv"
model_dir="$root_dir/Models/nllb-200-distilled-600M-ct2"

if [[ ! -x "$venv_dir/bin/python3" ]]; then
  python3 -m venv "$venv_dir"
fi

"$venv_dir/bin/python3" -m pip install --upgrade pip
"$venv_dir/bin/python3" -m pip install \
  'ctranslate2>=4.5,<5' \
  'transformers>=4.45,<5' \
  'sentencepiece>=0.2,<1' \
  'langcodes[data]>=3.4,<4'

if [[ ! -f "$model_dir/model.bin" ]]; then
  mkdir -p "${model_dir:h}"
  "$venv_dir/bin/ct2-transformers-converter" \
    --model facebook/nllb-200-distilled-600M \
    --output_dir "$model_dir" \
    --quantization int8 \
    --copy_files tokenizer.json tokenizer_config.json sentencepiece.bpe.model special_tokens_map.json
fi
