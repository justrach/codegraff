// Instant OpenAI Chat Completions stand-in for bench/shell.
//
// Each POST /v1/chat/completions streams one shell tool call, cycling
// echo hello / pwd / ls / true, then DONE after 30 calls. HTTP/1.1 keep-alive
// is left on so the client can reuse the socket.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
)

const toolLimit = 30

var commands = []string{"echo hello", "pwd", "ls", "true"}

type server struct {
	mu    sync.Mutex
	calls int
}

func (s *server) models(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = io.WriteString(w, `{"object":"list","data":[{"id":"mock","object":"model"}]}`)
}

func (s *server) reset(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	s.calls = 0
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) chat(w http.ResponseWriter, r *http.Request) {
	_, _ = io.Copy(io.Discard, r.Body)
	_ = r.Body.Close()

	s.mu.Lock()
	n := s.calls
	s.calls++
	s.mu.Unlock()

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "stream unsupported", http.StatusInternalServerError)
		return
	}

	chunk := func(payload any) {
		b, err := json.Marshal(payload)
		if err != nil {
			return
		}
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}

	if n >= toolLimit {
		chunk(map[string]any{
			"id": "mock", "object": "chat.completion.chunk", "model": "mock",
			"choices": []any{map[string]any{
				"index": 0, "delta": map[string]any{"role": "assistant", "content": "DONE"},
				"finish_reason": nil,
			}},
		})
		chunk(map[string]any{
			"id": "mock", "object": "chat.completion.chunk", "model": "mock",
			"choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": "stop"}},
			"usage":   map[string]int{"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12},
		})
		_, _ = io.WriteString(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}

	cmd := commands[n%len(commands)]
	args, _ := json.Marshal(map[string]string{"command": cmd})
	id := fmt.Sprintf("call_%d", n+1)
	chunk(map[string]any{
		"id": "mock", "object": "chat.completion.chunk", "model": "mock",
		"choices": []any{map[string]any{
			"index": 0,
			"delta": map[string]any{
				"tool_calls": []any{map[string]any{
					"index": 0, "id": id, "type": "function",
					"function": map[string]any{"name": "shell", "arguments": string(args)},
				}},
			},
			"finish_reason": nil,
		}},
	})
	chunk(map[string]any{
		"id": "mock", "object": "chat.completion.chunk", "model": "mock",
		"choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": "tool_calls"}},
		"usage":   map[string]int{"prompt_tokens": 8, "completion_tokens": 4, "total_tokens": 12},
	})
	_, _ = io.WriteString(w, "data: [DONE]\n\n")
	flusher.Flush()
}

func main() {
	s := &server{}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/models", s.models)
	mux.HandleFunc("/v1/chat/completions", s.chat)
	mux.HandleFunc("/reset", s.reset)
	mux.HandleFunc("/models", s.models)
	mux.HandleFunc("/chat/completions", s.chat)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Fprintf(os.Stdout, "PORT=%d\n", ln.Addr().(*net.TCPAddr).Port)
	_ = os.Stdout.Sync()
	srv := &http.Server{Handler: mux}
	log.Fatal(srv.Serve(ln))
}
