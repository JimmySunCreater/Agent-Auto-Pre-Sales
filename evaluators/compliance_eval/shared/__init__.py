"""Shared utilities for the compliance evaluator (LLM judge client only).

注意：不要在这里 import embedding_client —— 它依赖 numpy，
而本评估器的打包依赖里没有 numpy（也不需要 embedding）。
"""
from shared.llm_client import LLMClient, LLMResponse
