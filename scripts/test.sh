#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
env -u WISPAD_LIVE_TESTS -u WISPAD_FRANGLAIS -u WISPAD_LIVE_OPENAI_KEY -u WISPAD_LIVE_XAI_KEY -u WISPAD_LIVE_DEEPSEEK_KEY -u WISPAD_LIVE_TYPESAFE_KEY swift test "$@"
