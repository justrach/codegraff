# 0332. A tool batch queues every image, and the prompt reads the attachment trailer

Status: accepted 2026-11-10

## Context

Two image paths lost pixels the model was told it would get.

1. The registry held one optional image for the next model request. Two
   `read_file` image calls in one tool batch raced for it. The first to finish
   was attached. The other returned a successful result that said "not
   attached", so a before/after comparison reached the model as one picture
   and the model had to notice and read again (#1866).
2. An ACP client that cannot inline an upload as an `image` block leaves its
   path in an `Attached images (local files ...)` trailer on the prompt text.
   Uploads live outside the session's working directory, so the model's first
   `read_file` on that path was refused by the confinement gate and it copied
   the file in with the shell (#1865). graff staged `@[path]` markers from
   prompt text as vision blocks, but did not read this trailer.

## Decision

- **The registry slot is a bounded queue** (`image_inbox.Inbox`): up to 16
  images, the agent-side queue's own ceiling, and 24 MB of base64 per batch,
  under the 32 MB the strictest provider accepts for a whole request. Native
  image reads and MCP image blocks both stage into it.
- **Admitted means delivered, in call order.** The batch checkpoint drains the
  queue into one user message. Parallel reads finish in any order, so each
  image carries its call's position in the batch (`ToolCtx.call_seq`) and the
  drain sorts by it, stably. Blocks carry no names, so a message with several
  images also lists their labels in block order.
- **Refused means an error.** An image past either limit returns a tool error
  that names the limit and says to read it again in a later call. It is never
  a successful result with a note.
- **The prompt path reads the trailer** the way it reads `@[path]`: a ref whose
  first bytes are an image is staged as a vision block, and its line leaves
  the text the model reads. A ref that could not be staged (text-only model,
  missing file, not an image) keeps its line.
- **A trailer is an attachment for steering too.** A prompt that arrives
  while a turn is running is steered in as raw text, except one that carries
  images. One that carries the trailer now counts: it is handed back to the
  client (`promptRequired`) or queued, and arrives as an ordinary prompt.
- **The file tools stay confined.** No attachment grants `read_file` a path
  outside the working directory. The trailer is read only where the user's
  prompt names the file, and only image bytes are read.

The transition tables are `Graff.ImageDelivery` in `lean-proofs`: every staged
image is delivered once or refused, the queue never exceeds its limits, a
batch that fits arrives in one request, every request is in call order
whichever read finished first, and every trailer ref ends as an image block or
as its line.

## Consequences

A comparison read in one batch costs one round trip instead of two. An upload
the client could not inline costs no tool call at all. A batch of more than 16
images, or more than 24 MB of them, takes a second batch, and the model is
told so. An image staged outside a tool batch has no call position and is
delivered after the batch's own. Revisit the byte budget if a provider's request
ceiling drops below it, and the trailer parser if the client's trailer format
changes.
