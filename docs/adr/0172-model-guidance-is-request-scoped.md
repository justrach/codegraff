# 0172 — Model guidance is request-scoped

Behavioral guidance is composed when building a request, using the currently
selected model. It is not persisted into conversation history or appended to a
mutable system prompt. Repeated requests therefore contain one stable block,
and changing models cannot leave the previous model's instructions behind.

The current family guidance covers interpreting intent, proportionate
clarification and verification, concise communication, and bounded delegation.
Delegation guidance is added only for a root agent with that capability. Tool
gates and system/developer instructions remain authoritative. Prompt text must
not claim API capabilities that the wire layer does not implement.

Regression tests inspect emitted request bodies across repeated requests and
model switches, including unchanged reasoning defaults. Live task evaluations
measure quality and efficiency separately; shorter instructions alone do not
establish lower total task cost or latency.
