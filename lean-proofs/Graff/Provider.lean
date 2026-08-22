/-
  Provider table kernel.

  Twenty baked rows. Each row is data: an id plus the axes `Kind`,
  `Auth`, login, catalog, and two bools. The program does not branch per
  brand. Adding a vendor is one constructor here and one line in
  `provider.zig`; the Zig fixture test is the ratchet.

  Not modelled: the live `/models` overlay, the workspace router, or
  Kimi's runtime flip from native OpenAI-wire to Anthropic-wire.
-/

import Graff.Transport
import Graff.Util

namespace Graff.Provider
open Graff.Transport
open Graff.Util

inductive Login where
  | apiKey
  | codegraffDevice
  | codexDevice
  | kimiDevice
  | xaiDevice
deriving DecidableEq, Repr, BEq

inductive Catalog where
  | baked
  | codex
  | kimi
  | openai
  | anthropic
deriving DecidableEq, Repr, BEq

structure Row where
  id          : String
  kind        : Kind
  auth        : Auth
  login       : Login := .apiKey
  catalog     : Catalog := .baked
  subLogin    : Bool := false
  takesEffort : Bool := false
deriving Repr, BEq

def specs : List Row :=
  [ { id := "anthropic",  kind := .anthropic, auth := .xApiKey, catalog := .anthropic }
  , { id := "codegraff",  kind := .openai,    auth := .bearer,  login := .codegraffDevice, catalog := .openai, takesEffort := true }
  , { id := "deepseek",   kind := .openai,    auth := .bearer,  takesEffort := true }
  , { id := "openai",     kind := .responses, auth := .bearer }
  , { id := "minimax",    kind := .anthropic, auth := .bearer }
  , { id := "xiaomi",     kind := .openai,    auth := .bearer }
  , { id := "kilo",       kind := .openai,    auth := .bearer }
  , { id := "groq",       kind := .openai,    auth := .bearer }
  , { id := "cerebras",   kind := .openai,    auth := .bearer,  catalog := .openai, takesEffort := true }
  , { id := "mistral",    kind := .openai,    auth := .bearer }
  , { id := "kimi",       kind := .openai,    auth := .bearer,  login := .kimiDevice, catalog := .kimi, subLogin := true }
  , { id := "moonshot",   kind := .openai,    auth := .bearer }
  , { id := "xai",        kind := .openai,    auth := .bearer,  login := .xaiDevice, catalog := .openai, subLogin := true }
  , { id := "zai",        kind := .openai,    auth := .bearer,  catalog := .openai, takesEffort := true }
  , { id := "vercel",     kind := .openai,    auth := .bearer,  catalog := .openai, takesEffort := true }
  , { id := "openrouter", kind := .openai,    auth := .bearer,  catalog := .openai, takesEffort := true }
  , { id := "fugu",       kind := .openai,    auth := .bearer }
  , { id := "fireworks",  kind := .openai,    auth := .bearer,  catalog := .openai }
  , { id := "mlx",        kind := .openai,    auth := .bearer }
  , { id := "lmstudio",   kind := .openai,    auth := .bearer }
  , { id := "codex",      kind := .responses, auth := .bearer,  login := .codexDevice, catalog := .codex, subLogin := true }
  ]

def ids : List String := specs.map (·.id)

def find (id : String) : Option Row := specs.find? (fun r => r.id == id)

/-- Production gates WS on provider id as well as wire kind (#514): only
codex and xai actually serve a WebSocket endpoint — platform OpenAI's
Responses wire has none. On the baked table that keeps codex the only
WS row (xai's baked kind is openai; its Responses flip is runtime). -/
def wsCapable (r : Row) : Bool := (r.id == "codex" || r.id == "xai") && r.kind == .responses

def responsesCount : Nat := countWhere (fun r => r.kind == .responses) specs

def xApiKeyCount : Nat := countWhere (fun r => r.auth == .xApiKey) specs

def providerRows : Nat := specs.length

theorem provider_cube : providerRows = 21 := by native_decide
theorem responses_vendors : responsesCount = 2 := by native_decide
theorem one_x_api_key : xApiKeyCount = 1 := by native_decide

theorem unique_ids : unique ids = true := by native_decide
theorem only_codex_ws_capable :
    (specs.filter wsCapable).map (·.id) = ["codex"] := by native_decide
theorem anthropic_not_ws : (find "anthropic").map wsCapable = some false := by native_decide
theorem minimax_is_anthropic_bearer :
    (find "minimax").map (fun r => r.kind == .anthropic && r.auth == .bearer) = some true := by native_decide
theorem xai_no_effort : (find "xai").map (fun r => r.takesEffort) = some false := by native_decide

end Graff.Provider
